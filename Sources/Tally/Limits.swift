import CommonCrypto
import Foundation
import SQLite3

/// Live plan limits, read with the logins the CLIs already keep on this Mac.
/// Each credential is only sent to its own provider and is never refreshed or written back,
/// so the CLIs' sessions are left untouched.
enum LimitsFetcher {
    // MARK: Claude — Keychain item "Claude Code-credentials" → api.anthropic.com/api/oauth/usage

    static func claude() async -> ServiceLimits {
        var result = ServiceLimits(service: .claude, windows: [])
        // The Keychain read can fail for a moment (locked after sleep, or while Claude Code rewrites the item
        // when it renews its token), so try twice before saying there's no login.
        var read = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        if read.out == nil, read.status != 44 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            read = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        }
        guard let raw = read.out,
              let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            // 44 = errSecItemNotFound: there really is no Claude Code login on this Mac.
            result.error = read.status == 44 ? "Sign in with Claude Code to see limits"
                                             : "Couldn't read Claude Code's login from the Keychain"
            return result
        }
        let expires = number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        if let sub = oauth["subscriptionType"] as? String { result.plan = "Claude \(sub.capitalized)" }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            result.error = "Couldn't reach Anthropic"
            return result
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 401 {
                // Claude Code renews its own token when you use it; Tally never touches it.
                result.error = expires.map { $0 < Date() ? "Claude Code's sign-in expired \(Fmt.ago($0)). It renews the next time you use Claude Code." : nil }
                    ?? "Claude Code's sign-in expired. It renews the next time you use Claude Code."
            } else {
                result.error = "Anthropic usage unavailable (\(status))"
            }
            return result
        }
        let windows: [(String, String, Double)] = [
            ("five_hour", "Session", 5 * 3600),
            ("seven_day", "Weekly", 7 * 86_400),
            ("seven_day_opus", "Weekly · Opus", 7 * 86_400),
            ("seven_day_sonnet", "Weekly · Sonnet", 7 * 86_400),
        ]
        for (key, title, secs) in windows {
            guard let w = json[key] as? [String: Any], let util = number(w["utilization"]) else { continue }
            result.windows.append(LimitWindow(title: title, usedPercent: util,
                                              resetsAt: parseDate(w["resets_at"]), windowSeconds: secs))
        }
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let used = number(extra["used_credits"]), let limit = number(extra["monthly_limit"]) {
            result.notes.append(("Extra usage", "\(Fmt.money(used / 100)) / \(Fmt.money(limit / 100))"))
        }
        result.source = "live"
        result.checkedAt = Date()
        return result
    }

    // MARK: Codex — ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage

    static func codex(fallback: UsageScanner.CodexLogLimits?) async -> ServiceLimits {
        var result = ServiceLimits(service: .codex, windows: [])
        func useFallback(_ why: String) -> ServiceLimits {
            if let fallback {
                result.windows = fallback.windows
                result.plan = fallback.plan.map { "ChatGPT \($0.capitalized)" }
                result.source = "logs"
                result.checkedAt = fallback.at
                result.staleReason = why
            } else {
                result.error = why
            }
            return result
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else {
            return useFallback("Sign in with Codex to see limits")
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let acct = tokens["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (body, resp) = try? await URLSession.shared.data(for: req) else {
            return useFallback("Couldn't reach ChatGPT.")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return useFallback(status == 401 ? "Codex login expired. Run `codex login`." : "ChatGPT usage unavailable (\(status)).")
        }
        if let plan = json["plan_type"] as? String { result.plan = "ChatGPT \(plan.capitalized)" }
        if let rl = json["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let secs = number(w["limit_window_seconds"]) ?? 0
                var reset: Date?
                if let ts = number(w["reset_at"]) { reset = Date(timeIntervalSince1970: ts) }
                else if let s = number(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(s) }
                result.windows.append(LimitWindow(title: windowTitle(seconds: secs), usedPercent: number(w["used_percent"]) ?? 0,
                                                  resetsAt: reset, windowSeconds: secs))
            }
        }
        result.windows.sort { ($0.windowSeconds ?? 0) < ($1.windowSeconds ?? 0) }
        if let c = json["credits"] as? [String: Any], c["has_credits"] as? Bool == true || c["unlimited"] as? Bool == true {
            result.notes.append(("Remaining credits", c["unlimited"] as? Bool == true ? "Unlimited" : (c["balance"] as? String ?? "—")))
        }
        if let rc = json["rate_limit_reset_credits"] as? [String: Any], let n = number(rc["available_count"]), n > 0 {
            result.notes.append(("Reset credits", "\(Int(n))"))
        }
        result.source = "live"
        result.checkedAt = Date()
        return result
    }

    // MARK: OpenCode Go — API key from Pi / OpenCode auth → opencode.ai/zen/go/v1/usage

    static func opencodeGo() async -> ServiceLimits {
        var result = ServiceLimits(service: .opencodeGo, plan: "Go", windows: [])
        let home = FileManager.default.homeDirectoryForCurrentUser
        var keys: [String] = []
        if let k = ProcessInfo.processInfo.environment["OPENCODE_GO_API_KEY"] { keys.append(k) }
        for path in [".pi/agent/auth.json", ".local/share/opencode/auth.json"] {
            if let data = try? Data(contentsOf: home.appendingPathComponent(path)),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let go = obj["opencode-go"] as? [String: Any], let key = go["key"] as? String, !keys.contains(key) {
                keys.append(key)
            }
        }
        guard !keys.isEmpty else {
            result.error = "Add an OpenCode Go API key in Pi or OpenCode"
            return result
        }
        var lastStatus = 0
        for key in keys {
            var req = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("tally", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { continue }
            lastStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard lastStatus == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = json["usage"] as? [String: Any] else { continue }
            for (k, title, secs) in [("rolling", "Session", 5.0 * 3600), ("weekly", "Weekly", 7.0 * 86_400), ("monthly", "Monthly", 30.0 * 86_400)] {
                guard let w = usage[k] as? [String: Any] else { continue }
                result.windows.append(LimitWindow(title: title, usedPercent: number(w["percent"]) ?? 0,
                                                  resetsAt: parseDate(w["resetsAt"]), windowSeconds: secs))
            }
            result.source = "live"; result.checkedAt = Date()
            return result
        }
        result.error = lastStatus == 401 ? "OpenCode Go key expired. Make a new one in OpenCode Console." : "Couldn't read OpenCode Go usage"
        return result
    }

    // MARK: Cursor — Cursor.app's sign-in (state.vscdb) → cursor.com/api/usage-summary

    /// nil when Cursor isn't installed or signed in on this Mac (no card then: Cursor keeps no local usage logs).
    static func cursor() async -> ServiceLimits? {
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard let stored = sqliteValue(db.path, key: "cursorAuth/accessToken"), !stored.isEmpty else { return nil }
        var result = ServiceLimits(service: .cursor, windows: [])
        guard let token = cursorToken(stored) else {
            result.error = "Couldn't read Cursor's sign-in"
            return result
        }
        guard let claims = jwtClaims(token), let sub = claims["sub"] as? String,
              let user = sub.split(separator: "|").last else {
            result.error = "Couldn't read Cursor's sign-in"
            return result
        }
        if let exp = number(claims["exp"]), Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(60) {
            // Cursor renews its own token while it runs; Tally never touches it.
            result.error = "Cursor's sign-in expired. It renews the next time you open Cursor."
            return result
        }
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        req.setValue("WorkosCursorSessionToken=\(user)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            result.error = "Couldn't reach Cursor"
            return result
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.error = status == 401 || status == 403 ? "Cursor's sign-in expired. It renews the next time you open Cursor."
                                                          : "Cursor usage unavailable (\(status))"
            return result
        }
        parseCursor(json, into: &result)
        if result.error != nil { return result }
        result.source = "live"
        result.checkedAt = Date()
        return result
    }

    /// Fills plan, windows and notes from a cursor.com/api/usage-summary response.
    static func parseCursor(_ json: [String: Any], into result: inout ServiceLimits) {
        if let m = json["membershipType"] as? String { result.plan = cursorPlan(m) }
        let start = parseDate(json["billingCycleStart"]), end = parseDate(json["billingCycleEnd"])
        let secs = start.flatMap { s in end.map { $0.timeIntervalSince(s) } } ?? 30 * 86_400
        let individual = json["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        // Percent fields are already percentages (0.36 means 0.36%). used/limit are cents.
        var pct = number(plan?["totalPercentUsed"])
        if pct == nil, let used = number(plan?["used"]), let limit = number(plan?["limit"]), limit > 0 { pct = used / limit * 100 }
        if pct == nil, let o = individual?["overall"] as? [String: Any], let used = number(o["used"]), let limit = number(o["limit"]), limit > 0 {
            pct = used / limit * 100
        }
        if let pct {
            result.windows.append(LimitWindow(title: windowTitle(seconds: secs), usedPercent: min(100, max(0, pct)),
                                              resetsAt: end, windowSeconds: secs))
        }
        if let a = number(plan?["autoPercentUsed"]), let b = number(plan?["apiPercentUsed"]) {
            result.notes.append(("Auto · API", "\(Int(a.rounded()))% · \(Int(b.rounded()))%"))
        }
        if let od = individual?["onDemand"] as? [String: Any], od["enabled"] as? Bool == true, let used = number(od["used"]) {
            let limit = number(od["limit"]).map { " / \(Fmt.money($0 / 100))" } ?? ""
            result.notes.append(("On-demand", "\(Fmt.money(used / 100))\(limit)"))
        }
        if result.windows.isEmpty, json["isUnlimited"] as? Bool != true {
            result.error = "Cursor didn't report plan usage"
            return
        }
    }

    private static func cursorPlan(_ m: String) -> String {
        switch m.lowercased() {
        case "free", "": return "Cursor Hobby"
        case "free_trial": return "Cursor Pro trial"
        case "pro_plus": return "Cursor Pro+"
        case "ultra": return "Cursor Ultra"
        case "enterprise", "team", "business": return "Cursor \(m.capitalized)"
        default: return "Cursor \(m.replacingOccurrences(of: "_", with: " ").capitalized)"
        }
    }

    /// Asked for at most once per launch: if you deny the Keychain prompt, Tally won't ask again until it restarts.
    private static var cursorKeyDenied = false
    private static var cursorKey: Data?

    /// Plain JWT, or Cursor 3.27+'s "cursor-safe-storage:v1:" token, which is Chromium Safe Storage
    /// (AES-128-CBC, key = PBKDF2-SHA1(password from the "Cursor Safe Storage" Keychain item, "saltysalt", 1003)).
    private static func cursorToken(_ stored: String) -> String? {
        let prefix = "cursor-safe-storage:v1:"
        guard stored.hasPrefix(prefix) else { return stored }
        guard let blob = Data(base64Encoded: String(stored.dropFirst(prefix.count))), blob.starts(with: Data("v10".utf8)) else { return nil }
        if cursorKey == nil, !cursorKeyDenied {
            for account in ["Cursor Key", "Cursor"] {
                let r = run("/usr/bin/security", ["find-generic-password", "-s", "Cursor Safe Storage", "-a", account, "-w"])
                if let pw = r.out { cursorKey = pbkdf2(pw); break }
            }
            if cursorKey == nil { cursorKeyDenied = true }
        }
        guard let key = cursorKey, let plain = aesCBCDecrypt(blob.dropFirst(3), key: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func pbkdf2(_ password: String) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let pw = Array(password.utf8)
        _ = key.withUnsafeMutableBytes { k in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 k.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
        }
        return key
    }

    static func aesCBCDecrypt(_ data: Data, key: Data) -> Data? {
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, iv, d.baseAddress, data.count, o.baseAddress, o.count, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// Reads one ItemTable value from a VS Code-style state database, read-only.
    private static func sqliteValue(_ path: String, key: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        guard n > 0, let p = sqlite3_column_blob(stmt, 0) else { return nil }
        let data = Data(bytes: p, count: n)
        // Values are TEXT, but some versions store UTF-16LE blobs.
        if data.count > 1, data[data.startIndex + 1] == 0, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        guard let d = Data(base64Encoded: b) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    // MARK: Grok — Grok CLI's sign-in (~/.grok/auth.json) → cli-chat-proxy.grok.com/v1/billing

    /// nil when the Grok CLI isn't signed in on this Mac.
    static func grok() async -> ServiceLimits? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // One entry per sign-in; use the newest.
        let entries = obj.values.compactMap { $0 as? [String: Any] }.filter { $0["key"] is String }
        guard let auth = entries.max(by: { (parseDate($0["expires_at"]) ?? .distantPast) < (parseDate($1["expires_at"]) ?? .distantPast) }),
              let token = auth["key"] as? String else { return nil }
        var result = ServiceLimits(service: .grok, windows: [])
        if let exp = parseDate(auth["expires_at"]), exp < Date().addingTimeInterval(60) {
            // The Grok CLI renews its own sign-in when it runs; Tally never touches it.
            result.error = "Grok's sign-in expired \(Fmt.ago(exp)). It renews the next time you use Grok."
            return result
        }
        func request(_ path: String) -> URLRequest {
            var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com\(path)")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 15
            return req
        }
        guard let (body, resp) = try? await URLSession.shared.data(for: request("/v1/billing?format=credits")) else {
            result.error = "Couldn't reach Grok"
            return result
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            result.error = status == 401 ? "Grok's sign-in expired. It renews the next time you use Grok." : "Grok usage unavailable (\(status))"
            return result
        }
        if let (sb, sr) = try? await URLSession.shared.data(for: request("/v1/settings")),
           (sr as? HTTPURLResponse)?.statusCode == 200,
           let st = try? JSONSerialization.jsonObject(with: sb) as? [String: Any],
           let tier = st["subscription_tier_display"] as? String, !tier.isEmpty {
            result.plan = tier
        }
        parseGrok(json, into: &result)
        if result.windows.isEmpty { return result }
        result.source = "live"
        result.checkedAt = Date()
        return result
    }

    /// Fills the usage window from a cli-chat-proxy.grok.com/v1/billing?format=credits response.
    static func parseGrok(_ json: [String: Any], into result: inout ServiceLimits) {
        let cfg = json["config"] as? [String: Any] ?? json
        func val(_ v: Any?) -> Double? { (v as? [String: Any]).flatMap { number($0["val"]) } ?? number(v) }
        var pct = number(cfg["creditUsagePercent"])
        if pct == nil, let used = val(cfg["onDemandUsed"]), let cap = val(cfg["onDemandCap"]), cap > 0 { pct = used / cap * 100 }
        let period = cfg["currentPeriod"] as? [String: Any]
        let end = parseDate(period?["end"]) ?? parseDate(cfg["billingPeriodEnd"])
        let start = parseDate(period?["start"]) ?? parseDate(cfg["billingPeriodStart"])
        let secs = start.flatMap { s in end.map { $0.timeIntervalSince(s) } }.flatMap { $0 > 0 ? $0 : nil }
        // Free accounts and the first hours of a period can omit the percentage; show spend only then.
        guard let pct else { return }
        result.windows.append(LimitWindow(title: secs.map { windowTitle(seconds: $0) } ?? "Credits", usedPercent: min(100, max(0, pct)),
                                          resetsAt: end, windowSeconds: secs))
    }

    // MARK: Gemini / Antigravity — antigravity-oauth-token or ~/.gemini/oauth_creds.json → daily-cloudcode-pa.googleapis.com

    /// nil when neither Antigravity nor Gemini CLI is signed in on this Mac.
    static func gemini() async -> ServiceLimits? {
        guard let cred = loadGeminiToken() else { return nil }
        var result = ServiceLimits(service: .gemini, windows: [])
        if let exp = cred.expiry, exp < Date().addingTimeInterval(60) {
            // Antigravity / Gemini CLI renew their own token when used; Tally never touches it.
            result.error = "Gemini's sign-in expired \(Fmt.ago(exp)). It renews the next time you use Antigravity or Gemini CLI."
            return result
        }
        var lastStatus = 0
        for host in ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"] {
            var req = URLRequest(url: URL(string: "\(host)/v1internal:retrieveUserQuotaSummary")!)
            req.httpMethod = "POST"
            req.httpBody = Data("{}".utf8)
            req.setValue("Bearer \(cred.accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("antigravity/hub/2.24.0", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            guard let (body, resp) = try? await URLSession.shared.data(for: req) else { continue }
            lastStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard lastStatus == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                if lastStatus == 401 || lastStatus == 403 {
                    result.error = "Gemini's sign-in expired. It renews the next time you use Antigravity or Gemini CLI."
                    return result
                }
                continue
            }
            parseGemini(json, into: &result)
            if !result.windows.isEmpty {
                result.source = "live"
                result.checkedAt = Date()
                return result
            }
        }
        result.error = lastStatus == 0 ? "Couldn't reach Google Cloud Code" : "Gemini usage unavailable (\(lastStatus))"
        return result
    }

    private struct GeminiCred {
        let accessToken: String
        let expiry: Date?
        let mtime: Date
    }

    /// Reads the newest OAuth token from Antigravity (desktop, CLI, IDE, T3 Code ACP) or Gemini CLI, read-only.
    private static func loadGeminiToken() -> GeminiCred? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".gemini/antigravity/antigravity-oauth-token"),
            home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
            home.appendingPathComponent(".gemini/antigravity-ide/antigravity-oauth-token"),
            home.appendingPathComponent(".gemini/oauth_creds.json"),
        ]
        let t3Root = home.appendingPathComponent(".t3/userdata/providers/antigravity")
        if let subs = try? FileManager.default.contentsOfDirectory(at: t3Root, includingPropertiesForKeys: nil) {
            for sub in subs {
                candidates.append(sub.appendingPathComponent("antigravity-acp/antigravity-oauth-token"))
            }
        }
        var found: [GeminiCred] = []
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let tok = (obj["token"] as? [String: Any]) ?? obj
            guard let access = tok["access_token"] as? String, !access.isEmpty else { continue }
            let expiry = parseDate(tok["expiry"] ?? tok["expiry_date"] ?? tok["expires_at"])
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            found.append(GeminiCred(accessToken: access, expiry: expiry, mtime: mtime))
        }
        guard !found.isEmpty else { return nil }
        let now = Date().addingTimeInterval(60)
        // Prefer a non-expired token with the furthest expiry; otherwise the most recently updated one.
        if let valid = found.filter({ ($0.expiry ?? .distantFuture) > now })
            .max(by: { ($0.expiry ?? $0.mtime) < ($1.expiry ?? $1.mtime) }) {
            return valid
        }
        return found.max(by: { $0.mtime < $1.mtime })
    }

    /// Fills usage windows from a v1internal:retrieveUserQuotaSummary response.
    static func parseGemini(_ json: [String: Any], into result: inout ServiceLimits) {
        let root = (json["response"] as? [String: Any]) ?? json
        guard let groups = root["groups"] as? [[String: Any]] else { return }

        func windowMeta(_ w: String?) -> (label: String, secs: Double) {
            switch (w ?? "").lowercased() {
            case "5h", "five_hour": return ("Session", 5 * 3600)
            case "daily", "1d", "24h": return ("Daily", 86_400)
            case "weekly", "7d": return ("Weekly", 7 * 86_400)
            case "monthly", "30d": return ("Monthly", 30 * 86_400)
            default: return ("Quota", 5 * 3600)
            }
        }

        func shortGroup(_ name: String) -> String {
            var s = name.replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " Models", with: "")
                .replacingOccurrences(of: " and ", with: " & ")
                .trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Gemini 4 ") { s = String(s.dropFirst("Gemini 4 ".count)) }
            return s
        }

        var primary: [LimitWindow] = []
        var secondary: [LimitWindow] = []

        for g in groups {
            let groupName = (g["displayName"] as? String) ?? ""
            guard let buckets = g["buckets"] as? [[String: Any]] else { continue }
            let isMainGemini = groupName.lowercased() == "gemini models"
                || buckets.contains { let id = ($0["bucketId"] as? String) ?? ""; return id == "gemini-5h" || id == "gemini-weekly" }
            for b in buckets {
                guard let rem = number(b["remainingFraction"]) else { continue }
                let used = min(100, max(0, (1.0 - rem) * 100.0))
                let meta = windowMeta(b["window"] as? String)
                let reset = parseDate(b["resetTime"])
                if isMainGemini {
                    primary.append(LimitWindow(title: meta.label, usedPercent: used, resetsAt: reset, windowSeconds: meta.secs))
                } else if used > 0.5 {
                    let tag = shortGroup(groupName)
                    let title = tag.isEmpty ? meta.label : "\(meta.label) · \(tag)"
                    secondary.append(LimitWindow(title: title, usedPercent: used, resetsAt: reset, windowSeconds: meta.secs))
                }
            }
        }
        primary.sort { ($0.windowSeconds ?? 0) < ($1.windowSeconds ?? 0) }
        secondary.sort { $0.usedPercent > $1.usedPercent }
        result.windows = primary + secondary
    }

    // MARK: helpers

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ v: Any?) -> Date? {
        if let o = v as? [String: Any], let secs = number(o["seconds"]) { return Date(timeIntervalSince1970: secs) }
        if !(v is String), let n = number(v), n > 0 { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        guard let s = v as? String else { return nil }
        if let n = Double(s), n > 1e9 { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Microsecond precision ("…00.248202+00:00") isn't accepted by ISO8601DateFormatter; trim it.
        let trimmed = s.replacingOccurrences(of: #"\.(\d{3})\d+"#, with: ".$1", options: .regularExpression)
        if let d = f.date(from: trimmed) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func run(_ path: String, _ args: [String]) -> (out: String?, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (nil, -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return (nil, p.terminationStatus) }
        return (String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), 0)
    }
}
