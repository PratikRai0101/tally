import Foundation

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

    // MARK: helpers

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
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
