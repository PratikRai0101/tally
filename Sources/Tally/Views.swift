import SwiftUI

let tilePalette: [Color] = [
    Color(hex: 0xE8873A), Color(hex: 0x3FB8B0), Color(hex: 0xE0675A), Color(hex: 0x6DBF4B),
    Color(hex: 0x4E95F5), Color(hex: 0x9B7BEA), Color(hex: 0xD9B44A), Color(hex: 0xDB6FA8),
]

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs = Prefs.shared
    @State private var contentHeight: CGFloat = 600
    var fixedHeight = false   // snapshots render everything without a scroll view
    /// Snapshots for promo material: hide project names (TALLY_PRIVATE=1).
    static var hidePrivate = false

    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 60 }

    var body: some View {
        Group {
            if fixedHeight {
                content
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    content.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                }
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
                .frame(height: min(contentHeight, maxHeight))
            }
        }
        .frame(width: 440)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(20)
            Rectangle().fill(Theme.line).frame(height: 1)
            ForEach(store.visibleServices(prefs)) { s in
                ServiceCard(service: s, store: store, prefs: prefs)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if prefs.showProjects && !store.projects.isEmpty && !Self.hidePrivate {
                projectsSection.padding(20)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            if prefs.modelMap {
                modelsSection.padding(20)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.metric == .cost ? Fmt.money(store.totals.cost) : Fmt.tokens(store.totals.tokens))
                    .font(.system(size: 30, weight: .regular)).monospacedDigit()
                Text(store.metric == .cost ? "spent · \(store.period.label)" : "tokens · \(store.period.label)")
                    .font(.system(size: 13)).foregroundStyle(Theme.dim)
                Spacer()
                Button { ShareWindow.shared.show(store: store) } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain).help("Share a usage card")
                .padding(.trailing, 8)
                Button { store.refresh(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                        .animation(store.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: store.isLoading)
                        .font(.system(size: 13)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain).help("Refresh now")
            }
            stackBar
            if let (s, left) = store.mostHeadroom {
                HStack(spacing: 6) {
                    Text("Most headroom").foregroundStyle(Theme.dim)
                    ServiceMark(service: s, size: 16)
                    Text(s.name)
                    Text("\(Int(left))% left").foregroundStyle(Theme.good)
                    Spacer()
                    if !store.live.isEmpty {
                        LiveDot()
                        Text("\(store.live.count) running").foregroundStyle(Theme.dim)
                    }
                }
                .font(.system(size: 11.5))
            }
            HStack(spacing: 8) {
                Segmented(options: Period.allCases, selection: $store.period) { $0.rawValue }
                Segmented(options: Metric.allCases, selection: $store.metric) { $0.rawValue }
                Spacer()
                Text("\(store.totals.sessions) session\(store.totals.sessions == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
    }

    private var stackBar: some View {
        let order = store.visibleServices(prefs)
        let total = order.reduce(0) { $0 + store.value(store.services[$1]) }
        let segs = order.filter { store.value(store.services[$0]) > 0 }.map {
            DitherStackBar.Segment(id: $0.rawValue, color: $0.color,
                                   fraction: total > 0 ? store.value(store.services[$0]) / total : 0)
        }
        return DitherStackBar(segments: segs, height: 26)
    }

    // MARK: Spend by project

    private var projectsSection: some View {
        let top = Array(store.projects.prefix(6))
        let maxV = max(top.map { store.metric == .cost ? $0.cost : Double($0.tokens) }.max() ?? 1, 1e-9)
        let total = max(store.projects.reduce(0) { $0 + (store.metric == .cost ? $1.cost : Double($1.tokens)) }, 1e-9)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Spend by project", detail: "folders your agents worked in · \(store.period.label)")
            ForEach(top) { p in
                let v = store.metric == .cost ? p.cost : Double(p.tokens)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                        Text(p.name).font(.system(size: 12.5)).lineLimit(1)
                        HStack(spacing: 3) {
                            ForEach(p.services.sorted { $0.value > $1.value }.prefix(3), id: \.key) { s, _ in
                                ServiceMark(service: s, size: 14)
                            }
                        }
                        Spacer()
                        Text("\(Int((v / total * 100).rounded()))%").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint)
                        Text(store.format(v)).font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 62, alignment: .trailing)
                    }
                    ShareBar(fraction: v / maxV, color: p.services.max { $0.value < $1.value }?.key.color ?? Theme.dim)
                }
            }
            if store.projects.count > top.count {
                Text("+ \(store.projects.count - top.count) more projects").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: Spend by model

    private var modelsSection: some View {
        let ranked = store.models.filter { store.value($0) > 0 || $0.tokens > 0 }
            .sorted { store.value($0) > store.value($1) }
        let top = Array(ranked.prefix(6))
        let rest = ranked.dropFirst(6)
        let grand = max(ranked.reduce(0) { $0 + store.value($1) }, 1e-9)
        var items = top.map { TreemapItem(id: $0.id, value: max(store.value($0), 0)) }
        let restValue = rest.reduce(0) { $0 + store.value($1) }
        if !rest.isEmpty { items.append(TreemapItem(id: "__rest", value: restValue)) }
        let total = max(items.reduce(0) { $0 + $1.value }, 1)
        items = items.map { TreemapItem(id: $0.id, value: max($0.value, total * 0.035)) }
        func pct(_ v: Double) -> String { "\(Int((v / grand * 100).rounded()))%" }

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Spend by model",
                          detail: store.metric == .cost ? "box size = share of \(store.period.label) spend" : "box size = share of tokens")
            GeometryReader { geo in
                let rects = Treemap.layout(items, in: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, m in
                        if let r = rects[m.id] {
                            ModelTile(title: m.displayName, logo: m.service.monoLogo, symbol: m.service.symbol,
                                      value: pct(store.value(m)),
                                      color: store.value(m) > 0 ? tilePalette[i % tilePalette.count] : Color(hex: 0x6B6B70),
                                      muted: store.value(m) <= 0)
                                .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
                                .offset(x: r.minX + 2, y: r.minY + 2)
                        }
                    }
                    if let r = rects["__rest"] {
                        ModelTile(title: "\(rest.count) more", symbol: "ellipsis", value: pct(restValue),
                                  color: Color(hex: 0x8D8D93), muted: true)
                            .frame(width: max(0, r.width - 4), height: max(0, r.height - 4))
                            .offset(x: r.minX + 2, y: r.minY + 2)
                    }
                }
            }
            .frame(height: 150)

            // The legend: every tile, named, with its provider and exact numbers.
            VStack(spacing: 6) {
                ForEach(Array(top.enumerated()), id: \.element.id) { i, m in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(store.value(m) > 0 ? tilePalette[i % tilePalette.count] : Color(hex: 0x6B6B70))
                            .frame(width: 8, height: 8)
                        Text(m.displayName).font(.system(size: 12)).lineLimit(1)
                        Text("via \(m.service.name)").font(.system(size: 10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        Spacer()
                        Text(Fmt.tokens(m.tokens) + " tok").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint)
                        Text(Fmt.money(m.cost)).font(.system(size: 12, design: .monospaced))
                            .frame(minWidth: 62, alignment: .trailing)
                    }
                }
                if !rest.isEmpty {
                    HStack {
                        Text("\(rest.count) more models").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        Spacer()
                        Text(Fmt.money(rest.reduce(0) { $0 + $1.cost })).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                    }
                }
            }
            Text("Tokens: in \(Fmt.tokens(store.totals.input)) · cached \(Fmt.tokens(store.totals.cacheRead)) · out \(Fmt.tokens(store.totals.output))")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Text("Updated \(Fmt.ago(store.lastUpdated)) · API-price estimate")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
            Spacer()
            Button("Settings") { SettingsWindow.shared.show() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.dim)
    }
}

// MARK: - Service card

struct ServiceCard: View {
    let service: Service
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Prefs

    var body: some View {
        let summary = store.services[service]
        let lim = store.limits[service]
        // Free services have nothing to chart in dollars, so they chart tokens instead.
        let free = store.metric == .cost && (summary?.cost ?? 0) == 0 && (summary?.tokens ?? 0) > 0
        let metric: Metric = free ? .tokens : store.metric
        let fmt: (Double) -> String = { metric == .cost ? Fmt.money($0) : Fmt.tokens(Int($0)) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ServiceMark(service: service, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.name).font(.system(size: 14, weight: .medium))
                    Text(lim?.plan ?? prefs.planOption(service, detected: nil)?.name ?? service.defaultPlan)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if let lim, let f = Freshness(lim) {
                    Text(f.label).font(.system(size: 10.5)).foregroundStyle(f.stale ? Theme.warn : Theme.faint).help(f.help)
                }
            }

            if let lv = store.live[service] {
                HStack(spacing: 6) {
                    LiveDot()
                    Text("Running now").foregroundStyle(Theme.good)
                    Text(PopoverView.hidePrivate ? "· \(lv.tool.name)" : "· \(lv.tool.name) in \(lv.project)").foregroundStyle(Theme.dim).lineLimit(1)
                    Spacer()
                    Text("\(Fmt.money(lv.cost)) this session").font(.system(size: 11.5, design: .monospaced))
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.good.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.good.opacity(0.25), lineWidth: 1))
            }

            HStack {
                Text("This Mac · \(store.period.label)").foregroundStyle(Theme.dim)
                if let s = summary, s.sessions.count > 0 {
                    Text("· \(s.sessions.count) session\(s.sessions.count == 1 ? "" : "s")").foregroundStyle(Theme.faint)
                }
                Spacer()
                if free {
                    Text("free · \(Fmt.tokens(summary?.tokens ?? 0)) tokens")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.dim)
                } else {
                    Text(store.format(store.value(summary)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(store.value(summary) > 0 ? Theme.text : Theme.faint)
                }
            }
            .font(.system(size: 11.5))

            if prefs.tokenHistory {
                ServiceChart(buckets: store.buckets[service] ?? [], metric: metric, period: store.period,
                             color: service.color, format: fmt)
            }

            if let s = summary, s.byTool.count > 1 {
                HStack(spacing: 12) {
                    ForEach(s.byTool.sorted { $0.value > $1.value }, id: \.key) { tool, cost in
                        HStack(spacing: 4) {
                            LogoView(logo: tool.logo, size: 11, tint: Theme.dim)
                            Text("\(tool.name) \(Fmt.money(cost))")
                        }
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }

            if let lim {
                if let err = lim.error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                        Text(err).foregroundStyle(Theme.dim)
                    }
                    .font(.system(size: 11.5))
                }
                if let reason = lim.staleReason, !lim.windows.isEmpty {
                    let why = reason.hasSuffix(".") ? reason : reason + "."
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Theme.warn)
                        Text(lim.source == "logs" ? "\(why) Showing an estimate from this Mac's logs, so other devices aren't counted."
                                                  : "\(why) Showing the last good reading.")
                            .foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                }
                ForEach(lim.windows) { w in
                    LimitRow(window: w, color: prefs.colorBars ? Theme.severity(w.usedPercent) : service.color,
                             percentColor: prefs.colorBars ? Theme.severity(w.usedPercent) : Theme.dim,
                             forecast: store.forecast(service, w), quotaDisplay: prefs.limitDisplay)
                        .opacity(Freshness(lim)?.stale == true ? 0.55 : 1)
                }
                valueRow(plan: lim.plan)
                ForEach(lim.notes, id: \.0) { label, value in
                    HStack {
                        Text(label).font(.system(size: 12))
                        Spacer()
                        Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(hex: 0x9B7BEA))
                    }
                }
            } else if service.hasLimits {
                Text("Checking limits…").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            } else {
                valueRow(plan: nil)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    /// "Claude Pro · $20/mo → $69 at API prices this week (your plan: $4.67) · 14.8× value"
    @ViewBuilder private func valueRow(plan: String?) -> some View {
        let price = prefs.price(service, plan: plan)
        let used = store.services[service]?.cost ?? 0
        if price > 0 && used > 0 {
            let share = price * store.period.seconds / (30 * 86_400)
            let x = used / share
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle").foregroundStyle(Theme.dim)
                Text("Value").foregroundStyle(Theme.dim)
                Text("\(Fmt.money(used)) at API prices vs \(Fmt.money(share)) of your \(price.rounded() == price ? String(format: "$%.0f", price) : Fmt.money(price))/mo plan")
                    .foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text(String(format: x >= 10 ? "%.0f×" : "%.1f×", x))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(x >= 1 ? Theme.good : Theme.warn)
            }
            .font(.system(size: 11))
            .help("Over \(store.period.label) you used \(Fmt.money(used)) worth of API calls. Your plan costs \(Fmt.money(share)) for that stretch, so it's worth \(String(format: "%.1f", x))× what you pay.")
        }
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let color: Color
    let percentColor: Color
    var forecast: Forecast? = nil
    var quotaDisplay: QuotaDisplay = .used

    var body: some View {
        let percentText = quotaDisplay == .remaining ? quotaDisplay.summary(used: window.usedPercent) : "\(Int(window.usedPercent.rounded()))%"
        let meterUsed = quotaDisplay == .remaining ? quotaDisplay.percent(used: window.usedPercent) / 100 : window.usedPercent / 100
        let meterPace = quotaDisplay == .remaining ? window.pace.map { 1 - $0 } : window.pace
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(window.title).font(.system(size: 12.5))
                // Wait until a tenth of the window has passed: a few minutes in, any use looks "ahead".
                if let pace = window.pace, pace > 0.1, window.usedPercent / 100 > pace + 0.02 {
                    Text("ahead of pace").font(.system(size: 10)).foregroundStyle(Theme.bad.opacity(0.9))
                }
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 9.5))
                    Text(Fmt.countdown(to: window.resetsAt))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
                Text(percentText)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(percentColor)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            DitherMeter(color: color, used: meterUsed, pace: meterPace)
                .frame(height: 9)
            if let f = forecast {
                HStack(spacing: 4) {
                    if window.usedPercent >= 100 {
                        Text("Limit reached. Back in \(Fmt.countdown(to: window.resetsAt)).").foregroundStyle(Theme.bad)
                    } else if let secs = f.runsOutIn, f.beforeReset {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                        Text("At this pace you'll hit the limit \(Forecast.when(secs))\(f.early.map { ", \(Fmt.duration($0)) before reset" } ?? "")")
                            .foregroundStyle(Theme.bad).lineLimit(1).minimumScaleFactor(0.85)
                    } else if f.tooEarly {
                        Text("Too early in this window to forecast").foregroundStyle(Theme.faint)
                    } else if let end = f.atReset {
                        if end >= 90 {
                            let pct = quotaDisplay == .remaining
                                ? "\(max(1, 100 - min(99, Int(end.rounded()))))% left"
                                : "\(min(99, Int(end.rounded())))% used"
                            Text("Cutting it close: about \(pct) by reset").foregroundStyle(Theme.warn)
                        } else {
                            let pct = quotaDisplay == .remaining
                                ? "\(min(99, 100 - max(1, Int(end.rounded()))))% left"
                                : "\(max(1, Int(end.rounded())))% used"
                            Text("On track: about \(pct) by reset").foregroundStyle(Theme.faint)
                        }
                    } else if f.runsOutIn != nil {
                        Text("Lasts until reset at this pace").foregroundStyle(Theme.faint)
                    } else {
                        Text("Not in use right now").foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    if f.ratePerHour > 0 {
                        Text(String(format: f.average ? "avg %.1f%%/h" : "%.1f%%/h", f.ratePerHour))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.faint)
                            .help(f.average ? "Average use per hour since this window opened" : "Use per hour over the last hour")
                    }
                }
                .font(.system(size: 10.5))
                .padding(.top, 3)
            }
        }
        .padding(.top, 4)
        .help("\(window.title): \(Int(window.usedPercent))% used, \(Int(window.leftPercent))% left. White tick = even pace.")
    }
}

/// Dithered area chart with hover readout, per service.
struct ServiceChart: View {
    let buckets: [Bucket]
    let metric: Metric
    let period: Period
    let color: Color
    let format: (Double) -> String
    @State private var hover: Int?

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let values = buckets.map { $0.value(metric) }
                ZStack(alignment: .topLeading) {
                    DitherArea(values: values, color: color)
                    if let h = hover, h < buckets.count {
                        let x = (CGFloat(h) + 0.5) / CGFloat(max(1, buckets.count)) * geo.size.width
                        Rectangle().fill(Theme.ink.opacity(0.35)).frame(width: 1).offset(x: x)
                        tooltip(buckets[h])
                            .fixedSize()
                            .offset(x: min(max(0, x - 70), geo.size.width - 150), y: 2)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hover = min(buckets.count - 1, max(0, Int(p.x / geo.size.width * CGFloat(buckets.count))))
                    case .ended: hover = nil
                    }
                }
            }
            .frame(height: 48)
            axis
        }
    }

    private func tooltip(_ b: Bucket) -> some View {
        let f = DateFormatter()
        f.dateFormat = period == .month ? "EEE d MMM" : "EEEE HH:mm"
        let end = DateFormatter(); end.dateFormat = "HH:mm"
        let title = period == .month ? f.string(from: b.start) : "\(f.string(from: b.start))–\(end.string(from: b.start.addingTimeInterval(b.length)))"
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(b.value(metric) > 0 ? format(b.value(metric)) : "No usage").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card).shadow(color: .black.opacity(0.3), radius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }

    private var axis: some View {
        let labels: [String] = {
            guard !buckets.isEmpty else { return [] }
            let f = DateFormatter()
            switch period {
            case .day:
                f.dateFormat = "HH"
                return stride(from: 0, to: buckets.count, by: 4).map { f.string(from: buckets[$0].start) }
            case .week:
                f.dateFormat = "EEEEE"
                return stride(from: 0, to: buckets.count, by: 4).map { f.string(from: buckets[$0].start) }
            case .month:
                f.dateFormat = "d"
                return stride(from: 0, to: buckets.count, by: 5).map { f.string(from: buckets[$0].start) }
            }
        }()
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
                Text(l).frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 10)).foregroundStyle(Theme.faint)
    }
}

struct ModelTile: View {
    let title: String
    var logo: Logo? = nil
    let symbol: String
    let value: String
    let color: Color
    var muted = false

    var body: some View {
        GeometryReader { geo in
            let small = geo.size.width < 90 || geo.size.height < 56
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7).fill(color.opacity(muted ? 0.06 : 0.12))
                DitherField(color: color.opacity(muted ? 0.35 : 0.95), pitch: 4.5, dot: 2.6) { u, v in
                    muted ? ((u * 30 + v * 30).truncatingRemainder(dividingBy: 2) < 0.6 ? 0.5 : 0.05)
                          : 0.10 + 0.75 * pow(v, 1.3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7))
                if h >= 22 {
                    VStack(alignment: .leading) {
                        if h >= 40 {
                            HStack(spacing: 5) {
                                if let logo {
                                    LogoView(logo: logo, size: 11, tint: muted ? Theme.dim : .white)
                                } else {
                                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                                }
                                if geo.size.width > 70 {
                                    Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                }
                            }
                            .shadow(color: .black.opacity(0.9), radius: 2)
                        }
                        Spacer(minLength: 0)
                        if geo.size.width > 28 {
                            Text(value)
                                .font(.system(size: small ? 10.5 : 15, weight: .heavy, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                                .layoutPriority(1)
                                .shadow(color: .black.opacity(0.9), radius: 2)
                        }
                    }
                    .foregroundStyle(muted ? Theme.dim : .white)
                    .padding(small ? 5 : 9)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(muted ? 0.25 : 0.7), lineWidth: 1))
            .help("\(title) · \(value)")
        }
    }
}

/// The service's logo in a tinted tile: the brand-colour logo when there is one, else the mono logo in the service colour.
struct ServiceMark: View {
    let service: Service
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25).fill(service.color.opacity(0.14))
            if let logo = service.colorLogo {
                LogoView(logo: logo, size: size * 0.62)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
            } else if let logo = service.monoLogo {
                LogoView(logo: logo, size: size * 0.56, tint: service.color)
            } else {
                Image(systemName: service.symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(service.color)
            }
        }
        .frame(width: size, height: size)
    }
}

struct SectionHeader: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
    }
}

/// Thin dithered share bar used in lists.
struct ShareBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.ink.opacity(0.05))
                DitherField(color: color, pitch: 3, dot: 2) { u, _ in 0.45 + 0.5 * u }
                    .frame(width: max(3, g.size.width * min(1, fraction)))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(height: 6)
    }
}

/// A softly pulsing green dot for "running now".
struct LiveDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.good).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// How fresh a plan's numbers are: "live · 2m ago", "last checked 25m ago", "estimate from logs · 47m ago".
struct Freshness {
    let label: String
    let help: String
    /// Older than 10 minutes, or not from a live check: dim the meters so a calm green bar can't mislead.
    let stale: Bool

    init?(_ lim: ServiceLimits) {
        guard let at = lim.checkedAt, !lim.windows.isEmpty else { return nil }
        let age = Date().timeIntervalSince(at)
        let when = Fmt.ago(at)
        if lim.source == "logs" {
            label = "estimate from logs · \(when)"
            help = "The live usage check failed, so these numbers come from the agent's own logs on this Mac, last written \(when). Usage on other devices isn't included."
            stale = true
        } else if lim.staleReason != nil || age > 10 * 60 {
            label = "last checked \(when)"
            help = "The latest live check failed. These are the last numbers that came back, \(when)."
            stale = true
        } else {
            label = "live · \(when)"
            help = "Read from the provider's usage endpoint \(when). Tally checks every 3 minutes."
            stale = false
        }
    }
}
