import Foundation
import SwiftUI

struct ServiceSummary: Identifiable {
    let service: Service
    var cost: Double = 0
    var tokens: Int = 0
    var sessions = Set<String>()
    var byTool: [Tool: Double] = [:]
    var id: Service { service }
}

struct ModelSummary: Identifiable {
    let model: String
    let service: Service
    var cost: Double = 0
    var tokens: Int = 0
    var id: String { "\(service.rawValue)|\(model)" }
    var displayName: String { model.split(separator: "/").last.map(String.init) ?? model }
}

struct Bucket: Identifiable {
    let start: Date
    let length: TimeInterval
    var cost: Double = 0
    var tokens: Int = 0
    var id: Date { start }
    func value(_ m: Metric) -> Double { m == .cost ? cost : Double(tokens) }
}

struct Totals {
    var cost: Double = 0
    var tokens: Int = 0
    var input: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var output: Int = 0
    var sessions: Int = 0
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var period: Period = .week { didSet { recompute() } }
    @Published var metric: Metric = .cost
    @Published private(set) var totals = Totals()
    @Published private(set) var services: [Service: ServiceSummary] = [:]
    @Published private(set) var buckets: [Service: [Bucket]] = [:]
    @Published private(set) var models: [ModelSummary] = []
    @Published private(set) var limits: [Service: ServiceLimits] = [:]
    @Published private(set) var todayCost: Double = 0
    @Published private(set) var weekCost: Double = 0
    @Published private(set) var monthCost: Double = 0
    @Published private(set) var projects: [ProjectSummary] = []
    @Published private(set) var live: [Service: LiveSession] = [:]
    let history = LimitHistory()
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date? { didSet { onChange?() } }

    var onChange: (() -> Void)?

    private let pricing = Pricing()
    private lazy var scanner = UsageScanner(pricing: pricing)
    private var records: [UsageRecord] = []
    private var usedServices = Set<Service>()
    private var lastLimitsFetch: Date = .distantPast
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Local logs every minute; live limit endpoints at most every 3 minutes unless forced.
    func refresh(force: Bool = false) {
        guard !isLoading else { return }
        isLoading = true
        let fetchLimits = force || Date().timeIntervalSince(lastLimitsFetch) > 180
        let pricing = self.pricing
        let scanner = self.scanner
        Task.detached(priority: self.lastUpdated == nil ? .userInitiated : .utility) {
            await pricing.load()
            let result = scanner.scan(since: Date().addingTimeInterval(-Period.month.seconds))
            var fetched: [ServiceLimits]?
            if fetchLimits {
                async let c = LimitsFetcher.claude()
                async let x = LimitsFetcher.codex(fallback: result.codexLogLimits)
                async let g = LimitsFetcher.opencodeGo()
                fetched = await [c, x, g]
            }
            let newLimits = fetched
            await MainActor.run {
                self.records = result.records
                self.usedServices = Set(result.records.map(\.service))
                if let newLimits {
                    self.limits = Dictionary(uniqueKeysWithValues: newLimits.map { ($0.service, $0) })
                    self.lastLimitsFetch = Date()
                    for l in newLimits { for w in l.windows { self.history.record(l.service, w) } }
                    Notifier.shared.evaluate(self.limits, history: self.history, prefs: Prefs.shared)
                }
                self.isLoading = false
                self.recompute()
                self.lastUpdated = Date()
            }
        }
    }

    private func recompute() {
        let now = Date()
        let since = now.addingTimeInterval(-period.seconds)
        let inPeriod = records.filter { $0.date >= since }

        // Chart buckets: hourly for 24h, 6-hourly for 7d, daily for 30d.
        let cal = Calendar.current
        let (count, length): (Int, TimeInterval) = period == .day ? (24, 3600) : (period == .week ? (28, 6 * 3600) : (30, 86_400))
        let lastStart: Date
        switch period {
        case .day: lastStart = cal.dateInterval(of: .hour, for: now)!.start
        case .week:
            let h = cal.component(.hour, from: now)
            lastStart = cal.date(bySettingHour: h - h % 6, minute: 0, second: 0, of: now)!
        case .month: lastStart = cal.startOfDay(for: now)
        }
        let firstStart = lastStart.addingTimeInterval(-Double(count - 1) * length)
        let empty = (0..<count).map { Bucket(start: firstStart.addingTimeInterval(Double($0) * length), length: length) }

        var t = Totals()
        var sv: [Service: ServiceSummary] = [:]
        var bk: [Service: [Bucket]] = Dictionary(uniqueKeysWithValues: Service.allCases.map { ($0, empty) })
        var mods: [String: ModelSummary] = [:]
        var projs: [String: ProjectSummary] = [:]
        var allSessions = Set<String>()
        for r in inPeriod {
            t.cost += r.cost; t.tokens += r.tokens
            t.input += r.input; t.cacheRead += r.cacheRead; t.cacheWrite += r.cacheWrite; t.output += r.output
            let sid = "\(r.tool.rawValue)|\(r.session)"
            allSessions.insert(sid)

            var s = sv[r.service] ?? ServiceSummary(service: r.service)
            s.cost += r.cost; s.tokens += r.tokens
            s.sessions.insert(sid)
            s.byTool[r.tool, default: 0] += r.cost
            sv[r.service] = s

            let key = "\(r.service.rawValue)|\(r.model)"
            var m = mods[key] ?? ModelSummary(model: r.model, service: r.service)
            m.cost += r.cost; m.tokens += r.tokens
            mods[key] = m

            let pname = projectName(cwd: r.cwd)
            var pj = projs[pname] ?? ProjectSummary(name: pname)
            pj.cost += r.cost; pj.tokens += r.tokens
            pj.services[r.service, default: 0] += r.cost
            pj.lastActive = max(pj.lastActive, r.date)
            projs[pname] = pj

            let idx = Int(floor(r.date.timeIntervalSince(firstStart) / length))
            if idx >= 0 && idx < count {
                bk[r.service]![idx].cost += r.cost
                bk[r.service]![idx].tokens += r.tokens
            }
        }
        t.sessions = allSessions.count
        totals = t
        services = sv
        buckets = bk
        models = Array(mods.values)
        projects = projs.values.sorted { $0.cost > $1.cost }

        let dayStart = cal.startOfDay(for: now)
        todayCost = records.filter { $0.date >= dayStart }.reduce(0) { $0 + $1.cost }
        weekCost = records.filter { $0.date >= now.addingTimeInterval(-Period.week.seconds) }.reduce(0) { $0 + $1.cost }
        monthCost = records.reduce(0) { $0 + $1.cost }

        // A service is "live" if it logged usage in the last 3 minutes; sum that whole session.
        var lv: [Service: LiveSession] = [:]
        let recent = records.filter { now.timeIntervalSince($0.date) < 180 }
        for r in recent where (lv[r.service]?.lastActivity ?? .distantPast) < r.date {
            let sess = records.filter { $0.session == r.session && $0.tool == r.tool }
            lv[r.service] = LiveSession(service: r.service, tool: r.tool, project: projectName(cwd: r.cwd),
                                        cost: sess.reduce(0) { $0 + $1.cost }, tokens: sess.reduce(0) { $0 + $1.tokens },
                                        started: sess.map(\.date).min() ?? r.date, lastActivity: r.date)
        }
        live = lv
        onChange?()
    }

    func spend(_ mode: SpendMode) -> Double? {
        switch mode {
        case .off: return nil
        case .today: return todayCost
        case .week: return weekCost
        case .month: return monthCost
        }
    }

    /// The window a menu bar meter should show for this service.
    func meterWindow(_ s: Service, _ source: MeterSource) -> LimitWindow? {
        guard let lim = limits[s] else { return nil }
        switch source {
        case .tightest: return lim.binding
        case .session: return lim.windows.first { $0.title == "Session" } ?? lim.binding
        case .weekly: return lim.windows.first { $0.title.hasPrefix("Weekly") } ?? lim.binding
        }
    }

    func forecast(_ s: Service, _ w: LimitWindow) -> Forecast? { history.forecast(s, w) }

    /// The plan with the most room left (by its tightest limit).
    var mostHeadroom: (Service, Double)? {
        limits.values.compactMap { l -> (Service, Double)? in
            guard let b = l.binding, l.error == nil else { return nil }
            return (l.service, b.leftPercent)
        }.max { $0.1 < $1.1 }
    }

    func value(_ m: ModelSummary) -> Double { metric == .cost ? m.cost : Double(m.tokens) }
    func value(_ s: ServiceSummary?) -> Double { metric == .cost ? (s?.cost ?? 0) : Double(s?.tokens ?? 0) }
    func format(_ v: Double) -> String { metric == .cost ? Fmt.money(v) : Fmt.tokens(Int(v)) }

    /// Services to show, in the user's order: switched on, and with either limits or usage in the last 30 days.
    func visibleServices(_ prefs: Prefs) -> [Service] {
        prefs.order.filter { prefs.isOn($0) && ($0.hasLimits || usedServices.contains($0)) }
    }
}
