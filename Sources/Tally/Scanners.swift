import Foundation
import SQLite3

/// Reads local session logs from each coding agent and turns them into UsageRecords.
/// Files are cached by (mtime, size) so refreshes only re-parse what changed.
final class UsageScanner {
    let pricing: Pricing
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var fileCache: [String: CachedFile] = [:]

    struct Parsed {
        var records: [UsageRecord] = []
        var codexLimits: CodexLogLimits?
        var lockouts: [Lockout] = []
        var near: [NearMiss] = []
    }

    struct CachedFile {
        let mtime: Date
        let size: Int
        let parsed: Parsed
    }

    struct CodexLogLimits {
        let at: Date
        let windows: [LimitWindow]
        let plan: String?
    }

    struct Result {
        var records: [UsageRecord]
        var codexLogLimits: CodexLogLimits?
        var lockouts: [Lockout] = []
        var nearMisses: [NearMiss] = []
    }

    init(pricing: Pricing) { self.pricing = pricing }

    func scan(since: Date) -> Result {
        var all: [UsageRecord] = []
        var codexLimits: CodexLogLimits?
        var lockouts: [Lockout] = []
        var near: [NearMiss] = []
        var seenPaths = Set<String>()

        func run(_ dirs: [String], _ parser: (URL) -> Parsed) {
            for dir in dirs {
                for (url, mtime, size) in jsonlFiles(in: home.appendingPathComponent(dir), modifiedSince: since) {
                    seenPaths.insert(url.path)
                    let cached: CachedFile
                    if let c = fileCache[url.path], c.mtime == mtime, c.size == size {
                        cached = c
                    } else {
                        cached = CachedFile(mtime: mtime, size: size, parsed: parser(url))
                        fileCache[url.path] = cached
                    }
                    all.append(contentsOf: cached.parsed.records)
                    lockouts.append(contentsOf: cached.parsed.lockouts)
                    near.append(contentsOf: cached.parsed.near)
                    if let l = cached.parsed.codexLimits, l.at > (codexLimits?.at ?? .distantPast) { codexLimits = l }
                }
            }
        }

        run([".claude/projects", ".config/claude/projects"]) { self.parseClaude($0) }
        run([".codex/sessions", ".codex/archived_sessions"]) { self.parseCodex($0) }
        run([".pi/agent/sessions"]) { self.parsePi($0) }
        run([".grok/sessions"]) { self.parseGrok($0) }

        all.append(contentsOf: scanOpenCode(since: since))
        all.append(contentsOf: scanAntigravity(since: since, seenPaths: &seenPaths))
        all.append(contentsOf: scanGeminiCLI(since: since, seenPaths: &seenPaths))
        fileCache = fileCache.filter { seenPaths.contains($0.key) }

        // Claude Code writes the same API response into several lines/files; count each once.
        var seen = Set<String>()
        all = all.filter { r in
            guard r.date >= since else { return false }
            guard let k = r.dedupKey else { return true }
            return seen.insert(k).inserted
        }
        return Result(records: all, codexLogLimits: codexLimits,
                      lockouts: Self.cluster(lockouts.filter { $0.date >= since }), nearMisses: near.filter { $0.date >= since })
    }

    /// Many refused requests belong to one lockout: same plan, same reset (or within 2 h when the reset is unknown).
    static func cluster(_ hits: [Lockout]) -> [Lockout] {
        var out: [(Lockout, Date)] = []
        for h in hits.sorted(by: { $0.date < $1.date }) {
            if let i = out.lastIndex(where: { $0.0.service == h.service }) {
                let (prev, last) = out[i]
                let same: Bool
                if let a = h.resetAt, let b = prev.resetAt {
                    same = abs(a.timeIntervalSince(b)) < 15 * 60 && (prev.kind == h.kind || prev.kind == "limit" || h.kind == "limit")
                } else {
                    same = h.date.timeIntervalSince(last) < 2 * 3600
                }
                if same {
                    var p = prev
                    if p.resetAt == nil { p.resetAt = h.resetAt }
                    if p.kind == "limit" { p.kind = h.kind }
                    out[i] = (p, h.date)
                    continue
                }
            }
            out.append((h, h.date))
        }
        // Unknown kind: a reset within ~5 h means the session window, longer means weekly.
        return out.map { l, _ in
            var l = l
            if l.kind == "limit", let r = l.resetAt { l.kind = r.timeIntervalSince(l.date) > 6 * 3600 ? "seven_day" : "five_hour" }
            return l
        }
    }

    private static let resetClock = try! NSRegularExpression(pattern: #"resets\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#, options: .caseInsensitive)
    private static let tryAgain = try! NSRegularExpression(pattern: #"try again in ~?(\d+)\s*min"#, options: .caseInsensitive)
    private static let limitError = try! NSRegularExpression(pattern: #"usage limit|UsageLimitError|hit your .{0,40}limit|limit (?:has been )?reached"#, options: .caseInsensitive)

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    /// "resets 12:40am" → the next time the clock shows 12:40 am after `date`.
    private static func clockReset(_ date: Date, _ text: String) -> Date? {
        guard let g = match(resetClock, text), let h = Int(g[1]) else { return nil }
        let hour = h % 12 + (g[3].lowercased() == "pm" ? 12 : 0), minute = Int(g[2]) ?? 0
        let cal = Calendar.current
        guard var r = cal.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return nil }
        if r <= date { r = cal.date(byAdding: .day, value: 1, to: r) ?? r }
        return r
    }

    private static func windowKind(_ minutes: Double) -> String {
        minutes <= 360 ? "five_hour" : minutes <= 2 * 1440 ? "daily" : minutes <= 8 * 1440 ? "seven_day" : "monthly"
    }

    // MARK: - File walking

    private func jsonlFiles(in root: URL, modifiedSince: Date) -> [(URL, Date, Int)] {
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(URL, Date, Int)] = []
        for case let url as URL in e where url.pathExtension == "jsonl" {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= modifiedSince else { continue }
            out.append((url, m, v.fileSize ?? 0))
        }
        return out
    }

    /// Calls `body` for each line containing one of `needles` (fast byte search, no JSON parse for the rest).
    private func lines(of url: URL, containing needles: [String], _ body: ([String: Any], Int) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let needleBytes = needles.map { Array($0.utf8) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let n = raw.count
            var start = 0
            while start < n {
                let p = memchr(base + start, 0x0A, n - start)
                let end = p.map { base.distance(to: UnsafeRawPointer($0)) } ?? n
                let len = end - start
                if len > 2 {
                    for (i, nb) in needleBytes.enumerated() {
                        let hit = nb.withUnsafeBufferPointer { memmem(base + start, len, $0.baseAddress, nb.count) }
                        if hit != nil {
                            let line = Data(bytes: base + start, count: len)
                            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                                body(obj, i)
                            }
                            break
                        }
                    }
                }
                start = end + 1
            }
        }
    }

    // MARK: - Claude Code (~/.claude/projects/**/*.jsonl)

    private func parseClaude(_ url: URL) -> Parsed {
        var out: [UsageRecord] = []
        var hits: [Lockout] = []
        let fallbackSession = url.deletingPathExtension().lastPathComponent
        lines(of: url, containing: ["\"usage\"", "\"rate_limit\""]) { obj, _ in
            // Claude Code writes this line when a request is refused because a plan limit is used up.
            if obj["isApiErrorMessage"] as? Bool == true, obj["error"] as? String == "rate_limit", let date = parseISO(obj["timestamp"]) {
                let q = (obj["quotaLimits"] as? [String: Any])
                    ?? ((obj["apiErrorParams"] as? [String: Any])?["rate_limit_info"] as? [String: Any]) ?? [:]
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                let text = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
                let kind = q["rateLimitType"] as? String ?? (text.contains("weekly") ? "seven_day" : text.contains("5-hour") ? "five_hour" : "limit")
                let reset = (q["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Self.clockReset(date, text)
                hits.append(Lockout(date: date, service: .claude, kind: kind, resetAt: reset))
                return
            }
            guard let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let model = msg["model"] as? String, model != "<synthetic>",
                  let date = parseISO(obj["timestamp"]) else { return }
            let input = int(usage["input_tokens"])
            let read = int(usage["cache_read_input_tokens"])
            let write = int(usage["cache_creation_input_tokens"])
            let output = int(usage["output_tokens"])
            var write1h = 0
            if let cc = usage["cache_creation"] as? [String: Any] { write1h = int(cc["ephemeral_1h_input_tokens"]) }
            let write5m = max(0, write - write1h)
            var cost = 0.0
            if let r = pricing.rate(for: model) {
                cost = Double(input) * r.input + Double(output) * r.output + Double(read) * r.cacheRead
                    + Double(write5m) * r.cacheWrite + Double(write1h) * r.cacheWrite1h
            }
            var key: String?
            if let id = msg["id"] as? String { key = "c:\(id):\(obj["requestId"] as? String ?? "")" }
            out.append(UsageRecord(date: date, tool: .claudeCode, service: .claude, model: model, input: input, cacheRead: read,
                                   cacheWrite: write, output: output, cost: cost,
                                   session: obj["sessionId"] as? String ?? fallbackSession, dedupKey: key,
                                   cwd: obj["cwd"] as? String ?? ""))
        }
        return Parsed(records: out, lockouts: hits)
    }

    // MARK: - Codex (~/.codex/sessions/**/*.jsonl)

    private func parseCodex(_ url: URL) -> Parsed {
        var out: [UsageRecord] = []
        var hits: [Lockout] = []
        var near: [NearMiss] = []
        var model = "gpt-5-codex"
        var lastTotal = -1
        var cwd = ""
        var limits: CodexLogLimits?
        let session = url.deletingPathExtension().lastPathComponent
        lines(of: url, containing: ["\"token_count\"", "\"turn_context\"", "usage limit"]) { obj, kind in
            guard let payload = obj["payload"] as? [String: Any] else { return }
            if kind == 1 {
                if let m = payload["model"] as? String { model = m }
                if let c = payload["cwd"] as? String { cwd = c }
                return
            }
            if kind == 2 {
                if payload["type"] as? String == "error", let date = parseISO(obj["timestamp"]),
                   (payload["message"] as? String)?.range(of: "usage limit", options: .caseInsensitive) != nil {
                    hits.append(Lockout(date: date, service: .codex, kind: "limit", resetAt: nil))
                }
                return
            }
            guard payload["type"] as? String == "token_count", let date = parseISO(obj["timestamp"]) else { return }

            if let rl = payload["rate_limits"] as? [String: Any] {
                var windows: [LimitWindow] = []
                for key in ["primary", "secondary"] {
                    guard let w = rl[key] as? [String: Any] else { continue }
                    let mins = (w["window_minutes"] as? Double) ?? Double(int(w["window_minutes"]))
                    var reset: Date?
                    if let ts = w["resets_at"] as? Double { reset = Date(timeIntervalSince1970: ts) }
                    else if let s = w["resets_in_seconds"] as? Double { reset = date.addingTimeInterval(s) }
                    var used = (w["used_percent"] as? Double) ?? 0
                    // 100% means this window locked you out; anything lower is a reading for "closest call".
                    if used >= 100 { hits.append(Lockout(date: date, service: .codex, kind: Self.windowKind(mins), resetAt: reset)) }
                    else { near.append(NearMiss(date: date, service: .codex, kind: Self.windowKind(mins), percent: used)) }
                    if let reset, reset < Date() { used = 0 }
                    windows.append(LimitWindow(title: windowTitle(seconds: mins * 60), usedPercent: used,
                                               resetsAt: reset, windowSeconds: mins * 60))
                }
                if !windows.isEmpty { limits = CodexLogLimits(at: date, windows: windows, plan: rl["plan_type"] as? String) }
            }

            guard let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            let total = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
            if total == lastTotal { return } // duplicate event
            lastTotal = total
            let inputAll = int(last["input_tokens"])
            let cached = int(last["cached_input_tokens"])
            let write = int(last["cache_write_input_tokens"])
            let output = int(last["output_tokens"])
            let input = max(0, inputAll - cached - write)
            var cost = 0.0
            if let r = pricing.rate(for: model) {
                cost = Double(input) * r.input + Double(cached) * r.cacheRead + Double(write) * r.cacheWrite + Double(output) * r.output
            }
            out.append(UsageRecord(date: date, tool: .codex, service: .codex, model: model, input: input, cacheRead: cached,
                                   cacheWrite: write, output: output, cost: cost, session: session, cwd: cwd))
        }
        return Parsed(records: out, codexLimits: limits, lockouts: hits, near: near)
    }

    // MARK: - Pi (~/.pi/agent/sessions/**/*.jsonl) — Pi records its own cost per message

    private func parsePi(_ url: URL) -> Parsed {
        var out: [UsageRecord] = []
        var hits: [Lockout] = []
        let session = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        lines(of: url, containing: ["\"usage\"", "\"type\":\"session\"", "\"errorMessage\""]) { obj, kind in
            if obj["type"] as? String == "session" { cwd = obj["cwd"] as? String ?? cwd; return }
            if let msg = obj["message"] as? [String: Any], let err = msg["errorMessage"] as? String, Self.match(Self.limitError, err) != nil,
               let date = parseISO(obj["timestamp"]) ?? (msg["timestamp"] as? Double).map({ Date(timeIntervalSince1970: $0 / 1000) }) {
                let mins = Self.match(Self.tryAgain, err).flatMap { Double($0[1]) }
                hits.append(Lockout(date: date, service: Service.from(provider: msg["provider"] as? String), kind: "limit",
                                    resetAt: mins.map { date.addingTimeInterval($0 * 60) }))
            }
            guard let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { return }
            let date = parseISO(obj["timestamp"])
                ?? (msg["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            guard let date else { return }
            let model = (msg["model"] as? String) ?? "unknown"
            let provider = msg["provider"] as? String
            let input = int(usage["input"]), output = int(usage["output"])
            let read = int(usage["cacheRead"]), write = int(usage["cacheWrite"])
            var cost = ((usage["cost"] as? [String: Any])?["total"] as? Double) ?? 0
            if cost == 0, let r = pricing.rate(for: model) {
                cost = Double(input) * r.input + Double(output) * r.output + Double(read) * r.cacheRead + Double(write) * r.cacheWrite
            }
            out.append(UsageRecord(date: date, tool: .pi, service: Service.from(provider: provider), model: provider.map { "\($0)/\(model)" } ?? model,
                                   input: input, cacheRead: read, cacheWrite: write, output: output,
                                   cost: cost, session: session, cwd: cwd))
        }
        return Parsed(records: out, lockouts: hits)
    }

    // MARK: - Grok CLI (~/.grok/sessions/<cwd>/<session>/updates.jsonl) — Grok records tokens and cost per turn

    private static let grokTicksPerUSD = 1e10

    private func parseGrok(_ url: URL) -> Parsed {
        guard url.lastPathComponent == "updates.jsonl" else { return Parsed() }
        var out: [UsageRecord] = []
        var hits: [Lockout] = []
        let dir = url.deletingLastPathComponent()
        let session = dir.lastPathComponent
        var cwd = (dir.deletingLastPathComponent().lastPathComponent.removingPercentEncoding) ?? ""
        if let data = try? Data(contentsOf: dir.appendingPathComponent("summary.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = obj["info"] as? [String: Any], let c = info["cwd"] as? String { cwd = c }
        lines(of: url, containing: ["\"turn_completed\"", "\"retry_state\""]) { obj, kind in
            guard let params = obj["params"] as? [String: Any], let update = params["update"] as? [String: Any] else { return }
            let meta = params["_meta"] as? [String: Any]
            let date = (meta?["agentTimestampMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? (obj["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            guard let date else { return }
            if kind == 1 {
                // "subscription:free-usage-exhausted: … resets over a rolling 24-hour window". Plain request-rate
                // throttling ("sending requests too quickly") is not a plan limit.
                if update["error_type"] as? String == "rate_limited", let reason = update["reason"] as? String,
                   reason.contains("usage-exhausted") || reason.range(of: "usage limit", options: .caseInsensitive) != nil {
                    let kind = reason.contains("24-hour") ? "daily" : "limit"
                    hits.append(Lockout(date: date, service: .grok, kind: kind, resetAt: nil))
                }
                return
            }
            guard let usage = update["usage"] as? [String: Any] else { return }
            var models = (usage["modelUsage"] as? [String: [String: Any]]) ?? [:]
            if models.isEmpty { models = ["grok": usage] }
            let event = meta?["eventId"] as? String
            for (model, u) in models {
                let read = int(u["cachedReadTokens"]), write = int(u["cacheCreationTokens"])
                let input = max(0, int(u["inputTokens"]) - read), output = int(u["outputTokens"])
                var cost = Double(int(u["costUsdTicks"])) / Self.grokTicksPerUSD
                if cost == 0, let r = pricing.rate(for: model) {
                    cost = Double(input) * r.input + Double(output) * r.output + Double(read) * r.cacheRead + Double(write) * r.cacheWrite
                }
                out.append(UsageRecord(date: date, tool: .grok, service: .grok, model: model,
                                       input: input, cacheRead: read, cacheWrite: write, output: output,
                                       cost: cost, session: session, dedupKey: event.map { "grok:\($0):\(model)" }, cwd: cwd))
            }
        }
        return Parsed(records: out, lockouts: hits)
    }

    // MARK: - OpenCode (~/.local/share/opencode/opencode.db)

    private func scanOpenCode(since: Date) -> [UsageRecord] {
        let path = home.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let sql = """
            SELECT m.session_id, m.time_created, m.data, s.directory FROM session_message m
            LEFT JOIN session_v2 s ON s.id = m.session_id
            WHERE m.type = 'assistant' AND m.time_created >= ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        var out: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let session = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let ms = sqlite3_column_int64(stmt, 1)
            guard let blob = sqlite3_column_text(stmt, 2) else { continue }
            let len = Int(sqlite3_column_bytes(stmt, 2))
            let data = Data(bytes: blob, count: len)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any] else { continue }
            let modelObj = obj["model"] as? [String: Any]
            let model = (modelObj?["id"] as? String) ?? (obj["modelID"] as? String) ?? "unknown"
            let cache = tokens["cache"] as? [String: Any]
            let input = int(tokens["input"])
            let output = int(tokens["output"]) + int(tokens["reasoning"])
            let read = int(cache?["read"]), write = int(cache?["write"])
            let cost = (obj["cost"] as? Double) ?? 0
            if input + output + read + write == 0 { continue }
            out.append(UsageRecord(date: Date(timeIntervalSince1970: Double(ms) / 1000), tool: .opencode,
                                   service: Service.from(provider: modelObj?["providerID"] as? String ?? obj["providerID"] as? String),
                                   model: model, input: input, cacheRead: read, cacheWrite: write,
                                   output: output, cost: cost, session: session,
                                   cwd: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""))
        }
        return out
    }

    // MARK: - Antigravity (~/.gemini/antigravity*/conversations/*.db & T3 Code ACP)

    private func scanAntigravity(since: Date, seenPaths: inout Set<String>) -> [UsageRecord] {
        var roots = [
            home.appendingPathComponent(".gemini/antigravity"),
            home.appendingPathComponent(".gemini/antigravity-cli"),
            home.appendingPathComponent(".gemini/antigravity-ide"),
        ]
        let t3Root = home.appendingPathComponent(".t3/userdata/providers/antigravity")
        if let subs = try? FileManager.default.contentsOfDirectory(at: t3Root, includingPropertiesForKeys: nil) {
            for sub in subs { roots.append(sub.appendingPathComponent("antigravity-acp")) }
        }
        var out: [UsageRecord] = []
        let fm = FileManager.default
        for root in roots {
            let convDir = root.appendingPathComponent("conversations")
            guard let files = try? fm.contentsOfDirectory(at: convDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            var cwds: [String: String]?
            for url in files where url.pathExtension == "db" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      var mtime = v.contentModificationDate else { continue }
                var size = v.fileSize ?? 0
                let wal = URL(fileURLWithPath: url.path + "-wal")
                if let wv = try? wal.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
                    if let wm = wv.contentModificationDate, wm > mtime { mtime = wm }
                    size += wv.fileSize ?? 0
                }
                guard mtime >= since else { continue }
                seenPaths.insert(url.path)
                let cached: CachedFile
                if let c = fileCache[url.path], c.mtime == mtime, c.size == size {
                    cached = c
                } else {
                    if cwds == nil { cwds = antigravityWorkspaces(root.appendingPathComponent("conversation_summaries.db")) }
                    let session = url.deletingPathExtension().lastPathComponent
                    cached = CachedFile(mtime: mtime, size: size,
                                        parsed: parseAntigravityDB(url, session: session, cwd: cwds?[session] ?? "", fallbackDate: mtime))
                    fileCache[url.path] = cached
                }
                out.append(contentsOf: cached.parsed.records)
            }
        }
        return out
    }

    private func openSQLiteReadOnly(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 1000)
            return db
        }
        sqlite3_close(db)
        db = nil
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if sqlite3_open_v2("file:\(encoded)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            return db
        }
        sqlite3_close(db)
        return nil
    }

    private func antigravityWorkspaces(_ url: URL) -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path), let db = openSQLiteReadOnly(url.path) else { return [:] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT conversation_id, workspace_uris FROM conversation_summaries", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var map: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idP = sqlite3_column_text(stmt, 0), let uriP = sqlite3_column_text(stmt, 1) else { continue }
            let id = String(cString: idP), raw = String(cString: uriP)
            if let arr = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String], let first = arr.first {
                map[id] = URL(string: first)?.path ?? first.replacingOccurrences(of: "file://", with: "")
            }
        }
        return map
    }

    private func parseAntigravityDB(_ url: URL, session: String, cwd: String, fallbackDate: Date) -> Parsed {
        guard let db = openSQLiteReadOnly(url.path) else { return Parsed() }
        defer { sqlite3_close(db) }

        // 1. Collect per-response timestamps from steps.metadata (field 9 = usage, field 11 = responseId, field 1 = createdAt).
        var timestamps: [String: Date] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT metadata FROM steps WHERE metadata IS NOT NULL", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let n = Int(sqlite3_column_bytes(stmt, 0))
                guard n > 0, let p = sqlite3_column_blob(stmt, 0) else { continue }
                let fields = PB.fields(Data(bytes: p, count: n))
                var rid: String?
                var ts: UInt64 = 0
                for f in fields where f.wire == 2 {
                    if f.num == 9 {
                        for u in PB.fields(f.bytes) where u.num == 11 && u.wire == 2 {
                            rid = String(data: u.bytes, encoding: .utf8)
                        }
                    } else if (f.num == 1 || f.num == 8) && ts == 0 {
                        for t in PB.fields(f.bytes) where t.num == 1 && t.wire == 0 && t.varint > 1_600_000_000 {
                            ts = t.varint
                        }
                    }
                }
                if let rid, !rid.isEmpty, ts > 0 { timestamps[rid] = Date(timeIntervalSince1970: Double(ts)) }
            }
        }

        // 2. Read each generation from gen_metadata (field 1 → field 4 usage, field 21 model name, field 9→4→1 fallback timestamp).
        var out: [UsageRecord] = []
        var gstmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata WHERE data IS NOT NULL", -1, &gstmt, nil) == SQLITE_OK else { return Parsed() }
        defer { sqlite3_finalize(gstmt) }
        while sqlite3_step(gstmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(gstmt, 0))
            guard n > 0, let p = sqlite3_column_blob(gstmt, 0) else { continue }
            guard let m1 = PB.fields(Data(bytes: p, count: n)).first(where: { $0.num == 1 && $0.wire == 2 }) else { continue }
            var input = 0, output = 0, cacheRead = 0
            var responseId: String?
            var model = "gemini"
            var genTs: UInt64 = 0
            for f in PB.fields(m1.bytes) where f.wire == 2 {
                if f.num == 4 {
                    for u in PB.fields(f.bytes) {
                        if u.wire == 0 {
                            if u.num == 2 { input = Int(u.varint) }
                            else if u.num == 3 { output = Int(u.varint) }
                            else if u.num == 5 { cacheRead = Int(u.varint) }
                        } else if u.wire == 2 && u.num == 11 {
                            responseId = String(data: u.bytes, encoding: .utf8)
                        }
                    }
                } else if f.num == 21, let s = String(data: f.bytes, encoding: .utf8), !s.isEmpty {
                    model = s
                } else if f.num == 9 {
                    for t9 in PB.fields(f.bytes) where t9.num == 4 && t9.wire == 2 {
                        for t4 in PB.fields(t9.bytes) where t4.num == 1 && t4.wire == 0 && t4.varint > 1_600_000_000 {
                            genTs = t4.varint
                        }
                    }
                }
            }
            if input + output + cacheRead == 0 { continue }
            let date = responseId.flatMap { timestamps[$0] } ?? (genTs > 0 ? Date(timeIntervalSince1970: Double(genTs)) : fallbackDate)
            var cost = 0.0
            if let r = pricing.rate(for: model) {
                cost = Double(input) * r.input + Double(output) * r.output + Double(cacheRead) * r.cacheRead
            }
            out.append(UsageRecord(date: date, tool: .antigravity, service: .gemini, model: model,
                                   input: input, cacheRead: cacheRead, cacheWrite: 0, output: output,
                                   cost: cost, session: session, dedupKey: responseId.map { "agy:\($0)" }, cwd: cwd))
        }
        return Parsed(records: out)
    }

    // MARK: - Gemini CLI (~/.gemini/tmp/<project>/chats/session-*.json)

    private func scanGeminiCLI(since: Date, seenPaths: inout Set<String>) -> [UsageRecord] {
        let root = home.appendingPathComponent(".gemini/tmp")
        guard let e = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [UsageRecord] = []
        for case let url as URL in e where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("session-") {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true, let mtime = v.contentModificationDate, mtime >= since else { continue }
            let size = v.fileSize ?? 0
            seenPaths.insert(url.path)
            let cached: CachedFile
            if let c = fileCache[url.path], c.mtime == mtime, c.size == size {
                cached = c
            } else {
                cached = CachedFile(mtime: mtime, size: size, parsed: parseGeminiCLI(url))
                fileCache[url.path] = cached
            }
            out.append(contentsOf: cached.parsed.records)
        }
        return out
    }

    private func parseGeminiCLI(_ url: URL) -> Parsed {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msgs = obj["messages"] as? [[String: Any]] else { return Parsed() }
        let session = (obj["sessionId"] as? String) ?? url.deletingPathExtension().lastPathComponent
        var out: [UsageRecord] = []
        for m in msgs where (m["type"] as? String) == "gemini" {
            guard let t = m["tokens"] as? [String: Any], let date = parseISO(m["timestamp"]) else { continue }
            let cached = int(t["cached"])
            let input = max(0, int(t["input"]) - cached)
            let output = int(t["output"]) + int(t["thoughts"])
            if input + output + cached == 0 { continue }
            let model = (m["model"] as? String) ?? "gemini"
            var cost = 0.0
            if let r = pricing.rate(for: model) {
                cost = Double(input) * r.input + Double(output) * r.output + Double(cached) * r.cacheRead
            }
            out.append(UsageRecord(date: date, tool: .geminiCli, service: .gemini, model: model,
                                   input: input, cacheRead: cached, cacheWrite: 0, output: output,
                                   cost: cost, session: session, dedupKey: (m["id"] as? String).map { "gem:\($0)" }))
        }
        return Parsed(records: out)
    }

    // MARK: - Helpers

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    private func parseISO(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return fastISO(s) ?? isoFrac.date(from: s) ?? iso.date(from: s)
    }

    /// Fast path for UTC timestamps like 2026-11-18T10:24:00.714Z (ISO8601DateFormatter is slow at volume).
    private func fastISO(_ s: String) -> Date? {
        var u = Array(s.utf8)
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var n = 0
            for i in a..<b { let c = Int(u[i]) - 48; guard c >= 0, c <= 9 else { return nil }; n = n * 10 + c }
            return n
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16), let se = num(17, 19) else { return nil }
        var frac = 0.0
        if u[19] == 46 {
            var scale = 0.1
            for i in 20..<(u.count - 1) { let c = Int(u[i]) - 48; guard c >= 0, c <= 9 else { return nil }; frac += Double(c) * scale; scale /= 10 }
        }
        u.removeAll()
        // days from civil (Howard Hinnant)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + mi * 60 + se) + frac)
    }

    private func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return 0
    }
}

func windowTitle(seconds: Double) -> String {
    switch seconds {
    case ..<(3600 * 6): return "Session"
    case ..<(86_400 * 2): return "Daily"
    case ..<(86_400 * 8): return "Weekly"
    default: return "Monthly"
    }
}

/// Minimal zero-dependency protobuf wire-format decoder for Antigravity's local SQLite blobs.
private enum PB {
    struct Field { let num: Int; let wire: UInt8; let varint: UInt64; let bytes: Data }

    static func fields(_ data: Data) -> [Field] {
        var out: [Field] = []
        let n = data.count
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            func varint() -> UInt64? {
                var val: UInt64 = 0, shift: UInt64 = 0
                while i < n && shift < 64 {
                    let b = p[i]; i += 1
                    val |= UInt64(b & 0x7F) << shift
                    if b & 0x80 == 0 { return val }
                    shift += 7
                }
                return nil
            }
            while i < n {
                guard let tag = varint() else { break }
                let num = Int(tag >> 3), wire = UInt8(tag & 7)
                if num == 0 { break }
                switch wire {
                case 0:
                    guard let v = varint() else { return }
                    out.append(Field(num: num, wire: 0, varint: v, bytes: Data()))
                case 1:
                    guard i + 8 <= n else { return }
                    i += 8
                case 2:
                    guard let ln = varint(), ln <= UInt64(n - i) else { return }
                    let len = Int(ln)
                    out.append(Field(num: num, wire: 2, varint: 0, bytes: Data(bytes: p + i, count: len)))
                    i += len
                case 5:
                    guard i + 4 <= n else { return }
                    i += 4
                default:
                    return
                }
            }
        }
        return out
    }
}
