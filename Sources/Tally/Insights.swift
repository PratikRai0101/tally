import AppKit
import Carbon.HIToolbox
import UserNotifications

// MARK: - Projects

/// Turns a working directory into a short project name. Worktrees and scratch folders are folded together.
func projectName(cwd: String) -> String {
    guard !cwd.isEmpty else { return "Unknown" }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var p = cwd
    if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
    let parts = p.split(separator: "/").map(String.init)
    func after(_ marker: [String]) -> String? {
        guard parts.count > marker.count else { return nil }
        for i in 0...(parts.count - marker.count) where Array(parts[i..<(i + marker.count)]) == marker {
            return i + marker.count < parts.count ? parts[i + marker.count] : nil
        }
        return nil
    }
    if let repo = after([".t3", "worktrees"]) ?? after([".claude", "worktrees"]) ?? after([".codex", "worktrees"]) { return repo }
    if after([".t3", "scratch"]) != nil { return "T3 scratch" }
    if after(["Documents", "Codex"]) != nil { return "Codex scratch" }
    if p == "~" { return "~ (home)" }
    // Prefer the folder right under a common code root.
    for root in ["Developer", "Development", "Projects", "code", "src", "GitHub", "Documents"] {
        if let name = after(["~", root]) ?? after([root]) { return name }
    }
    return parts.last ?? cwd
}

struct ProjectSummary: Identifiable {
    let name: String
    var cost: Double = 0
    var tokens: Int = 0
    var services: [Service: Double] = [:]
    var lastActive: Date = .distantPast
    var id: String { name }
}

// MARK: - Live sessions

struct LiveSession {
    let service: Service
    let tool: Tool
    let project: String
    let cost: Double
    let tokens: Int
    let started: Date
    let lastActivity: Date
}

// MARK: - Runway forecast

struct Forecast {
    /// Seconds until the limit would be hit at the current pace (nil = not using it right now).
    let runsOutIn: TimeInterval?
    /// True when that happens before the window resets.
    let beforeReset: Bool
    /// Percent per hour.
    let ratePerHour: Double
    /// Being used, but not enough data yet to project.
    var tooEarly = false
}

/// Keeps a short history of limit readings so the burn rate reflects recent use, not the whole window.
final class LimitHistory {
    private var samples: [String: [(Date, Double)]] = [:]

    func key(_ s: Service, _ w: LimitWindow) -> String { "\(s.rawValue)|\(w.title)" }

    func record(_ s: Service, _ w: LimitWindow, at now: Date = Date()) {
        let k = key(s, w)
        var list = samples[k] ?? []
        // A drop means the window reset: start over.
        if let last = list.last, w.usedPercent < last.1 - 1 { list.removeAll() }
        list.append((now, w.usedPercent))
        list.removeAll { now.timeIntervalSince($0.0) > 3 * 3600 }
        samples[k] = list
    }

    func previous(_ s: Service, _ w: LimitWindow) -> Double? {
        let list = samples[key(s, w)] ?? []
        return list.count >= 2 ? list[list.count - 2].1 : nil
    }

    func forecast(_ s: Service, _ w: LimitWindow, now: Date = Date()) -> Forecast? {
        guard w.usedPercent < 100 else { return Forecast(runsOutIn: 0, beforeReset: true, ratePerHour: 0) }
        var rate: Double? // percent per second
        // Recent rate: last hour of readings, if we have at least 15 minutes of them and usage moved.
        let recent = (samples[key(s, w)] ?? []).filter { now.timeIntervalSince($0.0) <= 3600 }
        if let first = recent.first, let last = recent.last, last.0.timeIntervalSince(first.0) >= 15 * 60 {
            let r = (last.1 - first.1) / last.0.timeIntervalSince(first.0)
            if r > 0 { rate = r }
        }
        // Otherwise the average pace since the window opened.
        if rate == nil, let reset = w.resetsAt, let len = w.windowSeconds {
            let elapsed = len - reset.timeIntervalSince(now)
            // Too early in a window the average swings wildly, so wait for 30 minutes (or 3% of a long window).
            if elapsed > max(30 * 60, len * 0.03), w.usedPercent > 0 { rate = w.usedPercent / elapsed }
        }
        guard let rate, rate > 0 else {
            return Forecast(runsOutIn: nil, beforeReset: false, ratePerHour: 0, tooEarly: w.usedPercent > 0)
        }
        let secs = (100 - w.usedPercent) / rate
        let beforeReset = w.resetsAt.map { secs < $0.timeIntervalSince(now) } ?? true
        return Forecast(runsOutIn: secs, beforeReset: beforeReset, ratePerHour: rate * 3600)
    }
}

// MARK: - Plan value

enum PlanPricing {
    /// A sensible monthly price for a detected plan name. Users can override it in Settings.
    static func defaultPrice(for service: Service, plan: String?) -> Double {
        let p = (plan ?? "").lowercased()
        switch service {
        case .claude:
            if p.contains("max") { return p.contains("20") ? 200 : 100 }
            if p.contains("team") { return 30 }
            return p.contains("pro") || p.isEmpty ? 20 : 0
        case .codex:
            if p.contains("pro") { return 200 }
            if p.contains("plus") || p.isEmpty { return 20 }
            if p.contains("team") || p.contains("business") { return 30 }
            return 0
        case .opencodeGo: return 10
        default: return 0
        }
    }
}

// MARK: - Alerts

@MainActor
final class Notifier {
    static let shared = Notifier()
    private let d = UserDefaults.standard
    private var authorized = false

    func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    /// Fires each alert at most once per window cycle (keyed on the reset time).
    private func once(_ key: String, _ body: () -> Void) {
        var fired = d.stringArray(forKey: "firedAlerts") ?? []
        guard !fired.contains(key) else { return }
        fired.append(key)
        d.set(Array(fired.suffix(300)), forKey: "firedAlerts")
        body()
    }

    func evaluate(_ limits: [Service: ServiceLimits], history: LimitHistory, prefs: Prefs) {
        // The bare binary (--dump, --snapshot) has no bundle, and UserNotifications crashes without one.
        guard prefs.alertsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        for (service, lim) in limits {
            for w in lim.windows {
                let cycle = Int((w.resetsAt?.timeIntervalSince1970 ?? 0) / 600)
                let base = "\(service.rawValue)|\(w.title)|\(cycle)"
                for t in [80.0, 95.0] where prefs.thresholds.contains(Int(t)) && w.usedPercent >= t {
                    once("\(base)|\(Int(t))") {
                        post("\(service.name) \(w.title.lowercased()) at \(Int(w.usedPercent))%",
                             "Resets in \(Fmt.countdown(to: w.resetsAt)).")
                    }
                }
                if prefs.alertOnReset, let prev = history.previous(service, w), prev >= 50, w.usedPercent < prev - 30 {
                    once("\(base)|reset") {
                        post("\(service.name) \(w.title.lowercased()) has reset", "You're back to \(Int(w.leftPercent))% left.")
                    }
                }
                if prefs.alertOnPace, w.usedPercent >= 30, let f = history.forecast(service, w),
                   f.beforeReset, let secs = f.runsOutIn, secs > 0 {
                    once("\(base)|pace") {
                        post("\(service.name) \(w.title.lowercased()) is on pace to run out",
                             "At this rate it runs out in \(Fmt.duration(secs)), before it resets in \(Fmt.countdown(to: w.resetsAt)).")
                    }
                }
            }
        }
    }

    private func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Global hotkey (⌥⌘U by default)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: HotKey?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_U), modifiers: UInt32 = UInt32(optionKey | cmdKey), action: @escaping () -> Void) {
        self.action = action
        HotKey.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x544C4C59), id: 1) // 'TLLY'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil; handler = nil
        if HotKey.current === self { HotKey.current = nil }
    }
}

extension Fmt {
    static func duration(_ s: TimeInterval) -> String {
        var s = Int(s)
        let d = s / 86_400; s %= 86_400
        let h = s / 3600; s %= 3600
        let m = max(1, s / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
