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
        fileCache = fileCache.filter { seenPaths.contains($0.key) }

        all.append(contentsOf: scanOpenCode(since: since))

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
