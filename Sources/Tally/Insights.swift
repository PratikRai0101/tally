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
    /// The rate is the average since the window opened, not the last hour.
    var average = false
    /// Projected percent used when the window resets.
    var atReset: Double?
    /// How long before the reset the limit would be hit.
    var early: TimeInterval?

    /// "4:35 pm" today, "Mon 4 pm" later in the week.
    static func when(_ secs: TimeInterval, now: Date = Date()) -> String {
        var d = now.addingTimeInterval(secs)
        let f = DateFormatter()
        f.amSymbol = "am"; f.pmSymbol = "pm"
        let sameDay = Calendar.current.isDate(d, inSameDayAs: now)
        // Days away, minutes are false precision: round to the hour.
        if !sameDay { d = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 3600).rounded() * 3600) }
        f.dateFormat = sameDay ? "h:mm a" : "EEE h a"
        return f.string(from: d)
    }
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
        var average = false
        // Session-length windows: the last hour of readings, if we have 15 minutes of them and usage moved.
        // Weekly windows skip this: an hour of heavy use says nothing about a whole week, because nobody
        // codes around the clock. They use the average since the window opened instead.
        let long = (w.windowSeconds ?? 0) > 86_400
        let recent = (samples[key(s, w)] ?? []).filter { now.timeIntervalSince($0.0) <= 3600 }
        if !long, let first = recent.first, let last = recent.last, last.0.timeIntervalSince(first.0) >= 15 * 60 {
            let r = (last.1 - first.1) / last.0.timeIntervalSince(first.0)
            if r > 0 { rate = r }
        }
        // Otherwise the average pace since the window opened.
        if rate == nil, let reset = w.resetsAt, let len = w.windowSeconds {
            let elapsed = len - reset.timeIntervalSince(now)
            // Too early in a window the average swings wildly, so wait for 30 minutes (or 3% of a long window).
            if elapsed > max(30 * 60, len * 0.03), w.usedPercent > 0 { rate = w.usedPercent / elapsed; average = true }
        }
        guard let rate, rate > 0 else {
            return Forecast(runsOutIn: nil, beforeReset: false, ratePerHour: 0, tooEarly: w.usedPercent > 0)
        }
        let secs = (100 - w.usedPercent) / rate
        let toReset = w.resetsAt?.timeIntervalSince(now)
        let beforeReset = toReset.map { secs < $0 } ?? true
        var f = Forecast(runsOutIn: secs, beforeReset: beforeReset, ratePerHour: rate * 3600)
        f.average = average
        if let toReset { f.atReset = min(100, w.usedPercent + rate * toReset); f.early = beforeReset ? toReset - secs : nil }
        return f
    }
}

// MARK: - Alerts

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let d = UserDefaults.standard
    private var authorized = false

    func requestPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    /// Without this, macOS hides Tally's banners whenever Tally is the active app, i.e. while the panel is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
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
        guard Bundle.main.bundleIdentifier != nil else { return }
        let hook = Hook.isInstalled
        guard prefs.alertsEnabled || hook else { return }
        for (service, lim) in limits {
            for w in lim.windows {
                let cycle = Int((w.resetsAt?.timeIntervalSince1970 ?? 0) / 600)
                let base = "\(service.rawValue)|\(w.title)|\(cycle)"
                // The hook gets every event; notifications only the ones switched on in Settings.
                func fire(_ kind: String, notify: Bool, threshold: Int? = nil, _ title: String, _ body: String) {
                    guard notify || hook else { return }
                    once("\(base)|\(kind)") {
                        if notify { post(title, body) }
                        if hook {
                            Hook.run(event: threshold == nil ? kind : "threshold", service: service, window: w,
                                     threshold: threshold, title: title, body: body)
                        }
                    }
                }
                for t in [80, 95] where w.usedPercent >= Double(t) {
                    fire("\(t)", notify: prefs.alertsEnabled && prefs.thresholds.contains(t), threshold: t,
                         "\(service.name) \(w.title.lowercased()) at \(Int(w.usedPercent))%",
                         "Resets in \(Fmt.countdown(to: w.resetsAt)).")
                }
                if let prev = history.previous(service, w), prev >= 50, w.usedPercent < prev - 30 {
                    fire("reset", notify: prefs.alertsEnabled && prefs.alertOnReset,
                         "\(service.name) \(w.title.lowercased()) has reset", "You're back to \(Int(w.leftPercent))% left.")
                }
                if w.usedPercent >= 30, let f = history.forecast(service, w), f.beforeReset, let secs = f.runsOutIn, secs > 0 {
                    fire("pace", notify: prefs.alertsEnabled && prefs.alertOnPace,
                         "\(service.name) \(w.title.lowercased()) limit: on pace to hit it",
                         "At this pace you'll hit it around \(Forecast.when(secs)), \(Fmt.duration(f.early ?? 0)) before it resets. Good moment to wrap up.")
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

// MARK: - Before-cutoff hook

/// Runs ~/.config/tally/hook (if you made one) when an alert fires, so a script can save work,
/// stop an agent or ping a chat before a limit cuts you off. Tally never creates or downloads this file.
enum Hook {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tally/hook")
    }

    /// Only an executable file owned by you that nobody else can write to.
    static var isInstalled: Bool {
        let path = url.path
        guard FileManager.default.isExecutableFile(atPath: path),
              let a = try? FileManager.default.attributesOfItem(atPath: path),
              (a[.type] as? FileAttributeType) == .typeRegular,
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let perms = (a[.posixPermissions] as? NSNumber)?.intValue, perms & 0o022 == 0 else { return false }
        return true
    }

    static func run(event: String, service: Service, window: LimitWindow, threshold: Int?, title: String, body: String) {
        var env = ProcessInfo.processInfo.environment
        env["TALLY_EVENT"] = event                          // threshold | pace | reset | test
        env["TALLY_SERVICE"] = service.rawValue             // claude | codex | opencodeGo …
        env["TALLY_SERVICE_NAME"] = service.name
        env["TALLY_WINDOW"] = window.title.lowercased()     // session | weekly | monthly
        env["TALLY_PERCENT"] = String(Int(window.usedPercent.rounded()))
        if let threshold { env["TALLY_THRESHOLD"] = String(threshold) }
        if let r = window.resetsAt {
            env["TALLY_RESETS_AT"] = ISO8601DateFormatter().string(from: r)
            env["TALLY_RESETS_IN"] = String(max(0, Int(r.timeIntervalSinceNow)))
        }
        env["TALLY_TITLE"] = title
        env["TALLY_MESSAGE"] = body
        launch(env)
    }

    /// `Tally --test-hook`: runs the hook once with a sample event so you can check your script.
    static func test() -> Int32 {
        guard isInstalled else {
            print("No usable hook at \(url.path). It must be an executable file you own that only you can write (chmod 755).")
            return 1
        }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in ["TALLY_EVENT": "test", "TALLY_SERVICE": "claude", "TALLY_SERVICE_NAME": "Claude", "TALLY_WINDOW": "session",
                       "TALLY_PERCENT": "80", "TALLY_THRESHOLD": "80", "TALLY_RESETS_IN": "3600",
                       "TALLY_RESETS_AT": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)),
                       "TALLY_TITLE": "Claude session at 80%", "TALLY_MESSAGE": "Resets in 1h. (test)"] { env[k] = v }
        let p = Process()
        p.executableURL = url
        p.environment = env
        do { try p.run() } catch { print("Couldn't run \(url.path): \(error.localizedDescription)"); return 1 }
        p.waitUntilExit()
        print("hook exited with status \(p.terminationStatus)")
        return p.terminationStatus
    }

    private static func launch(_ env: [String: String]) {
        let p = Process()
        p.executableURL = url
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return }
        // A hook gets a minute; a stuck script shouldn't linger forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if p.isRunning { p.terminate() } }
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
