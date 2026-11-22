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

struct Rhythm {
    var hours = [Double](repeating: 0, count: 24)    // by local hour of day
    var weekdays = [Double](repeating: 0, count: 7)  // Sunday first
    var bars: [Double] = []
    var barLabels: [String] = []
    var peakBar: Date?
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
    /// Per-plan cost and tokens for the menu bar labels, independent of the panel's period.
    @Published private(set) var labelTotals: [LabelPeriod: [Service: (cost: Double, tokens: Int)]] = [:]
    @Published private(set) var live: [Service: LiveSession] = [:]
    let history = LimitHistory()
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date? { didSet { onChange?() } }

    var onChange: (() -> Void)?

    private let pricing = Pricing()
    private lazy var scanner = UsageScanner(pricing: pricing)
    private var records: [UsageRecord] = []
    /// Plan lockouts and limit readings from the last 30 days of logs, for the Wrapped deck.
    private(set) var lockouts: [Lockout] = []
    private(set) var nearMisses: [NearMiss] = []
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
                async let cu = LimitsFetcher.cursor()
                async let gr = LimitsFetcher.grok()
                fetched = await [c, x, g, cu, gr].compactMap { $0 }
            }
            let newLimits = fetched
            await MainActor.run {
                self.records = result.records
                self.lockouts = result.lockouts
                self.nearMisses = result.nearMisses
                self.usedServices = Set(result.records.map(\.service))
                if let newLimits {
                    let merged = newLimits.map { self.keepLastGood($0) }
                    self.limits = Dictionary(uniqueKeysWithValues: merged.map { ($0.service, $0) })
                    self.lastLimitsFetch = Date()
                    // Only fresh live readings feed the pace history; repeats of old numbers would flatten it.
                    for l in newLimits where l.source == "live" { for w in l.windows { self.history.record(l.service, w) } }
                    Notifier.shared.evaluate(self.limits, history: self.history, prefs: Prefs.shared)
                }
                self.isLoading = false
                self.recompute()
                self.lastUpdated = Date()
            }
        }
    }

    /// A failed check shouldn't blank a meter that was fine a minute ago (the Keychain is briefly locked,
    /// Claude Code is renewing its token, the network blipped). Keep the last good live reading for up to
    /// 12 hours, marked with its age and why the new check failed. Windows that have reset since are dropped.
    private func keepLastGood(_ new: ServiceLimits) -> ServiceLimits {
        guard new.source != "live", let old = limits[new.service], !old.windows.isEmpty,
              let at = old.checkedAt, Date().timeIntervalSince(at) < 12 * 3600,
              new.windows.isEmpty || (new.checkedAt ?? .distantPast) < at else { return new }
        var keep = old
        keep.error = nil
        keep.staleReason = new.error ?? new.staleReason ?? old.staleReason
        keep.windows = old.windows.filter { ($0.resetsAt ?? .distantFuture) > Date() }
        return keep.windows.isEmpty ? new : keep
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
        var lt: [LabelPeriod: [Service: (cost: Double, tokens: Int)]] = [:]
        for (lp, start) in [(LabelPeriod.today, dayStart), (.week, now.addingTimeInterval(-Period.week.seconds)),
                            (.month, now.addingTimeInterval(-Period.month.seconds))] {
            var m: [Service: (cost: Double, tokens: Int)] = [:]
            for r in records where r.date >= start {
                let cur = m[r.service] ?? (0, 0)
                m[r.service] = (cur.cost + r.cost, cur.tokens + r.tokens)
            }
            lt[lp] = m
        }
        labelTotals = lt

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

    /// The menu bar total: dollars or tokens across every plan, for the chosen range.
    func total(_ mode: SpendMode, _ metric: Metric) -> String? {
        let lp: LabelPeriod
        switch mode {
        case .off: return nil
        case .today: lp = .today
        case .week: lp = .week
        case .month: lp = .month
        }
        let all = labelTotals[lp]?.values ?? [:].values
        return metric == .cost ? Fmt.moneyShort(all.reduce(0) { $0 + $1.cost })
                               : Fmt.tokens(all.reduce(0) { $0 + $1.tokens }) + " tok"
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

    /// When the period's work happened, for the share deck: by hour of day, by weekday and as a bar series.
    func rhythm() -> Rhythm {
        let cal = Calendar.current, now = Date()
        var r = Rhythm()
        let weight: (UsageRecord) -> Double = { $0.cost > 0 ? $0.cost : Double($0.tokens) * 1e-7 }
        let inPeriod = records.filter { $0.date >= now.addingTimeInterval(-period.seconds) }
        for rec in inPeriod {
            r.hours[cal.component(.hour, from: rec.date)] += weight(rec)
            r.weekdays[cal.component(.weekday, from: rec.date) - 1] += weight(rec)
        }
        let unit: Calendar.Component = period == .day ? .hour : .day
        let n = period == .day ? 24 : (period == .week ? 7 : 30)
        let last = cal.dateInterval(of: unit, for: now)!.start
        let starts = (0..<n).map { cal.date(byAdding: unit, value: $0 - (n - 1), to: last)! }
        r.bars = Array(repeating: 0, count: n)
        for rec in inPeriod {
            if let i = starts.lastIndex(where: { $0 <= rec.date }) { r.bars[i] += weight(rec) }
        }
        let df = DateFormatter()
        r.barLabels = starts.enumerated().map { i, d in
            switch period {
            case .day: let h = cal.component(.hour, from: d); return h % 6 == 0 ? String(format: "%02d", h) : ""
            case .week: df.dateFormat = "EEE"; return df.string(from: d)
            case .month: df.dateFormat = "d"; return (n - 1 - i) % 7 == 0 ? df.string(from: d) : ""
            }
        }
        if let i = r.bars.indices.max(by: { r.bars[$0] < r.bars[$1] }), r.bars[i] > 0 { r.peakBar = starts[i] }
        return r
    }

    func value(_ m: ModelSummary) -> Double { metric == .cost ? m.cost : Double(m.tokens) }
    func value(_ s: ServiceSummary?) -> Double { metric == .cost ? (s?.cost ?? 0) : Double(s?.tokens ?? 0) }
    func format(_ v: Double) -> String { metric == .cost ? Fmt.money(v) : Fmt.tokens(Int(v)) }

    /// Services to show, in the user's order: switched on, and with either limits or usage in the last 30 days.
    func visibleServices(_ prefs: Prefs) -> [Service] {
        prefs.order.filter { prefs.isOn($0) && ($0.showsWithoutUsage || usedServices.contains($0) || limits[$0]?.windows.isEmpty == false) }
    }
}
