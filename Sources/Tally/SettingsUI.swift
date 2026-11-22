import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, menuBar, plans, alerts, panel
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu bar"
        case .plans: return "Plans"
        case .alerts: return "Alerts"
        case .panel: return "Panel"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .plans: return "square.stack.3d.up"
        case .alerts: return "bell"
        case .panel: return "rectangle.split.1x2"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How Tally looks and starts."
        case .menuBar: return "What the meters next to the clock show."
        case .plans: return "Your subscriptions, their order, and what you pay for them."
        case .alerts: return "Get a heads-up before a limit cuts you off."
        case .panel: return "Which sections the dropdown panel shows."
        }
    }
}

// MARK: - Window content

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    @ObservedObject var store: UsageStore
    @State var pane: SettingsPane = .plans
    /// Snapshot mode: no scroll view, so the whole pane renders.
    var snapshot = false

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(pane: $pane, store: store)
                .frame(width: 208)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(pane.title).font(.system(size: 24, weight: .semibold)).tracking(-0.4)
                    Text(pane.subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 30).padding(.top, 42).padding(.bottom, 18)
                Rectangle().fill(Theme.line).frame(height: 1)
                if snapshot {
                    content.padding(.horizontal, 30).padding(.vertical, 22)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        content.padding(.horizontal, 30).padding(.vertical, 22)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.bg)
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .frame(width: 780)
        .frame(minHeight: snapshot ? nil : 560)
        .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralPane(prefs: prefs)
        case .menuBar: MenuBarPane(prefs: prefs, store: store)
        case .plans: PlansPane(prefs: prefs, store: store)
        case .alerts: AlertsPane(prefs: prefs)
        case .panel: PanelPane(prefs: prefs)
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var pane: SettingsPane
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIconView(size: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tally").font(.system(size: 15, weight: .semibold))
                    Text("Version \(appVersion)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 8).padding(.top, 52).padding(.bottom, 20)

            ForEach(SettingsPane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(pane == p ? Theme.accent : Theme.dim)
                            .frame(width: 18)
                        Text(p.title).font(.system(size: 13, weight: pane == p ? .semibold : .regular))
                            .foregroundStyle(pane == p ? Theme.text : Theme.text.opacity(0.82))
                        Spacer()
                        badge(p)
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(pane == p ? Theme.ink.opacity(0.075) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                let n = store.limits.values.filter { $0.source == "live" }.count
                HStack(spacing: 6) {
                    Circle().fill(n > 0 ? Theme.good : Theme.faint).frame(width: 6, height: 6)
                    Text(n == 1 ? "1 plan live" : "\(n) plans live").font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
                Button { NSWorkspace.shared.open(URL(string: "https://github.com/PratikRai0101/tally/issues")!) } label: {
                    Text("Report an issue ↗").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            ZStack(alignment: .bottom) {
                Theme.sidebar
                // The dithered fade that runs through the rest of Tally.
                DitherField(color: Theme.accent.opacity(0.22), pitch: 4, dot: 1.8) { _, v in max(0, (v - 0.15) * 0.7) }
                    .frame(height: 150)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            }
        )
    }

    @ViewBuilder private func badge(_ p: SettingsPane) -> some View {
        if p == .alerts, !prefs.alertsEnabled {
            Text("Off").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().stroke(Theme.line, lineWidth: 1))
        }
    }
}

var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

// MARK: - Building blocks

/// A rounded card whose rows are separated by inset hairlines.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedLayout()) { content }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

private struct DividedLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last { Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 16) }
        }
    }
}

/// Title (and an optional explanation) on the left, a control on the right.
private struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.06)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, detail == nil ? 11 : 12)
        .frame(minHeight: 46)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Theme.faint)
            .padding(.leading, 4).padding(.top, 4).padding(.bottom, -2)
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var prefs: Prefs
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Appearance")
            HStack(spacing: 12) {
                ForEach(AppearanceMode.allCases) { m in
                    Button { prefs.appearance = m } label: {
                        VStack(spacing: 8) {
                            AppearanceSwatch(mode: m)
                                .frame(height: 74)
                                .overlay(RoundedRectangle(cornerRadius: 9)
                                    .stroke(prefs.appearance == m ? Theme.accent : Theme.line, lineWidth: prefs.appearance == m ? 2 : 1))
                            Text(m.rawValue).font(.system(size: 12, weight: prefs.appearance == m ? .semibold : .regular))
                                .foregroundStyle(prefs.appearance == m ? Theme.text : Theme.dim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SectionTitle("Behaviour")
            Card {
                SettingRow(title: "Color bars by usage", detail: "Green, then amber past 70%, red past 90%. Off uses each plan's own color.") {
                    Toggle("", isOn: $prefs.colorBars).toggleStyle(PillToggle())
                }
                SettingRow(title: "Open the panel with a shortcut") {
                    HStack(spacing: 10) {
                        KeyCaps(keys: ["⌥", "⌘", "U"])
                        Toggle("", isOn: $prefs.hotkeyEnabled).toggleStyle(PillToggle())
                    }
                }
                SettingRow(title: "Launch at login") {
                    Toggle("", isOn: Binding(get: { loginOn }, set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                        loginOn = SMAppService.mainApp.status == .enabled
                    }))
                    .toggleStyle(PillToggle())
                }
            }
        }
    }
}

private struct KeyCaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                Text(k).font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.ink.opacity(0.1), lineWidth: 1))
            }
        }
    }
}

/// A tiny drawing of the panel in light, dark, or both.
private struct AppearanceSwatch: View {
    let mode: AppearanceMode
    var body: some View {
        GeometryReader { g in
            ZStack {
                switch mode {
                case .light: mini(dark: false)
                case .dark: mini(dark: true)
                case .system:
                    HStack(spacing: 0) {
                        mini(dark: false).frame(width: g.size.width / 2).clipped()
                        mini(dark: true).frame(width: g.size.width / 2).clipped()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func mini(dark: Bool) -> some View {
        let bg = dark ? Color(hex: 0x19191B) : Color(hex: 0xF6F5F2)
        let ink = dark ? Color.white : Color.black
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.75)).frame(width: 46, height: 6)
                ForEach(Array([0.72, 0.4, 0.9].enumerated()), id: \.offset) { i, f in
                    let c = [Color(hex: 0xE2774F), Color(hex: 0x42C08D), Color(hex: 0x2BB5C9)][i]
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.08))
                        DitherField(color: c, pitch: 2.5, dot: 1.6) { u, _ in u < f ? 0.35 + 0.6 * u : 0 }
                    }
                    .frame(height: 7)
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Menu bar

private struct MenuBarPane: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuBarPreview(prefs: prefs, store: store)

            SectionTitle("Meters")
            Card {
                SettingRow(title: "Style") { Segmented(options: MenuBarStyle.allCases, selection: $prefs.menuStyle) { $0.rawValue } }
                SettingRow(title: "Each meter shows", detail: "Tightest is whichever of a plan's limits is closest to running out.") {
                    Segmented(options: MeterSource.allCases, selection: $prefs.meterSource) { $0.rawValue }
                }
                SettingRow(title: "Logos") { Toggle("", isOn: $prefs.showLogos).toggleStyle(PillToggle()) }
            }

            SectionTitle("Labels")
            Card {
                SettingRow(title: "Label shows") { Segmented(options: LabelKind.allCases, selection: $prefs.labelKind) { $0.rawValue } }
                if prefs.labelKind != .percent {
                    SettingRow(title: "Over") { Segmented(options: LabelPeriod.allCases, selection: $prefs.labelPeriod) { $0.rawValue } }
                }
                SettingRow(title: "Show labels", detail: "High usage shows a label only once that limit passes 70%.") {
                    Segmented(options: PercentMode.allCases, selection: $prefs.percentMode) { $0.rawValue }
                }
            }

            SectionTitle("Total")
            Card {
                SettingRow(title: "Total after the meters") { Segmented(options: SpendMode.allCases, selection: $prefs.spendMode) { $0.rawValue } }
                if prefs.spendMode != .off {
                    SettingRow(title: "Count") { Segmented(options: Metric.allCases, selection: $prefs.totalMetric) { $0.rawValue } }
                }
            }
        }
    }
}

/// The real menu bar image, drawn with your current numbers on a strip of fake menu bar.
private struct MenuBarPreview: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: UsageStore

    var body: some View {
        let image = MenuBarRenderer.statusImage(store: store, prefs: prefs)
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .top) {
                // Desktop: a dithered dusk gradient.
                LinearGradient(colors: [Color(hex: 0x2A1F3D), Color(hex: 0x6B3A4B), Color(hex: 0xC26A4A)],
                               startPoint: .top, endPoint: .bottom)
                DitherField(color: Color(hex: 0xF2B58A).opacity(0.5), pitch: 4, dot: 2) { u, v in v * 0.8 - 0.1 + 0.1 * sin(u * 7) }
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo").font(.system(size: 12.5))
                    Text("Finder").font(.system(size: 12.5, weight: .bold))
                    ForEach(["File", "Edit", "View"], id: \.self) { Text($0).font(.system(size: 12.5)) }
                    Spacer()
                    Image(nsImage: image).renderingMode(.original)
                    Image(systemName: "wifi").font(.system(size: 12.5))
                    Text(clock).font(.system(size: 12.5)).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.black.opacity(0.32))
            }
            .frame(height: 112)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))

            HStack(spacing: 6) {
                Circle().fill(Theme.good).frame(width: 6, height: 6)
                Text("Live preview with your current numbers").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
            .padding(.leading, 4)
        }
    }

    private var clock: String {
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        return f.string(from: Date())
    }
}

// MARK: - Plans

private struct PlansPane: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: UsageStore
    @State private var dragging: Service?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle("Your plans")
                Spacer()
                Text("Panel").frame(width: 46)
                Text("Menu bar").frame(width: 58)
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.faint)
            .padding(.trailing, 16)

            Card {
                ForEach(prefs.order) { s in
                    PlanRow(service: s, prefs: prefs, store: store)
                        .opacity(dragging == s ? 0.4 : 1)
                        .onDrag {
                            dragging = s
                            return NSItemProvider(object: s.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: ReorderDrop(target: s, dragging: $dragging, prefs: prefs))
                }
            }
            Footnote("Drag to reorder. The price of each plan powers “value”: what your usage would cost at API prices against what you pay. Cursor and Grok share one X Subscription, so set one of them to “Paid on …” to count it once.")
        }
    }
}

private struct PlanRow: View {
    let service: Service
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: UsageStore

    var body: some View {
        let lim = store.limits[service]
        let visible = store.visibleServices(prefs).contains(service)
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.faint)
            ServiceMark(service: service, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.system(size: 13.5, weight: .medium))
                HStack(spacing: 5) {
                    if lim?.source == "live" { Circle().fill(Theme.good).frame(width: 5, height: 5) }
                    Text(status(lim, visible: visible)).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !PlanCatalog.options(service).isEmpty {
                PlanPicker(service: service, prefs: prefs, detected: lim?.plan)
            } else {
                Text("Pay as you go").font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            }
            Toggle("", isOn: Binding(get: { prefs.isOn(service) }, set: { prefs.toggle(service, $0) }))
                .toggleStyle(PillToggle()).frame(width: 46)
            Group {
                if service.hasLimits {
                    Toggle("", isOn: Binding(get: { prefs.inMenuBar(service) }, set: { prefs.toggleMenu(service, $0) }))
                        .toggleStyle(PillToggle())
                } else {
                    Text("—").foregroundStyle(Theme.faint)
                }
            }
            .frame(width: 58)
        }
        .padding(.horizontal, 16).frame(height: 58)
        .contentShape(Rectangle())
    }

    private func status(_ lim: ServiceLimits?, visible: Bool) -> String {
        if let lim, lim.source == "live" { return "Live limits" }
        if let lim, lim.source == "logs" { return "Estimate from logs" }
        if visible { return store.services[service].map { _ in "Usage from local logs" } ?? "Checking…" }
        switch service {
        case .cursor: return "Not signed in"
        case .grok: return "Not signed in"
        default: return "No usage in 30 days"
        }
    }
}

/// A button showing the chosen plan and price; opens a list of the plans that service sells.
private struct PlanPicker: View {
    let service: Service
    @ObservedObject var prefs: Prefs
    let detected: String?
    @State private var open = false
    @State private var custom: Double = 0

    var body: some View {
        let current = prefs.planOption(service, detected: detected)
        let isCustom = current == nil && (prefs.planChoice[service.rawValue] == "custom" || prefs.planPrices[service.rawValue] != nil)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(current?.name ?? (isCustom ? "Custom" : "Choose plan"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(current == nil && !isCustom ? Theme.dim : Theme.text)
                if let current {
                    Text(current.priceLabel).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim)
                } else if isCustom {
                    Text(String(format: "$%.0f/mo", prefs.planPrices[service.rawValue] ?? 0))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .frame(minWidth: 140, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(open ? Theme.accent.opacity(0.7) : Theme.ink.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PlanList(service: service, prefs: prefs, detected: detected, open: $open)
        }
    }
}

private struct PlanList: View {
    let service: Service
    @ObservedObject var prefs: Prefs
    let detected: String?
    @Binding var open: Bool
    @State private var customText = ""

    var body: some View {
        let options = PlanCatalog.options(service)
        let chosen = prefs.planChoice[service.rawValue]
        let auto = PlanCatalog.detect(service, plan: detected)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ServiceMark(service: service, size: 22)
                Text("\(service.name) plan").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let detected {
                    Text("Detected: \(detected)").font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)

            if auto != nil {
                row(title: "Match my account", detail: auto.map { "\($0.name) · \($0.priceLabel)" }, price: nil,
                    selected: chosen == nil && prefs.planOption(service, detected: detected) != nil) {
                    prefs.choosePlan(service, nil); open = false
                }
                divider
            }
            if service == .cursor || service == .grok { header("X Subscription · Cursor + Grok") }
            ForEach(options.filter { !$0.legacy }) { o in
                row(title: o.name, detail: o.note, price: o.priceLabel, selected: chosen == o.id) { prefs.choosePlan(service, o.id); open = false }
            }
            if options.contains(where: \.legacy) {
                divider
                header("Older plans, still billed")
                ForEach(options.filter(\.legacy)) { o in
                    row(title: o.name, detail: o.note, price: o.priceLabel, selected: chosen == o.id) { prefs.choosePlan(service, o.id); open = false }
                }
            }
            divider
            HStack(spacing: 8) {
                Image(systemName: chosen == "custom" ? "checkmark" : "pencil").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(chosen == "custom" ? Theme.accent : Theme.faint).frame(width: 14)
                Text("Custom price").font(.system(size: 12.5))
                Spacer()
                Text("$").foregroundStyle(Theme.dim)
                TextField("0", text: $customText)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 54).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.07)))
                    .onSubmit(applyCustom)
                Text("/mo").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 8).frame(height: 32)
            Text("Prices are US list prices per month, billed monthly.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.faint).padding(.horizontal, 8).padding(.top, 4)
        }
        .padding(10)
        .frame(width: 320)
        .foregroundStyle(Theme.text)
        .background(Theme.card)
        .onAppear {
            if let p = prefs.planPrices[service.rawValue] { customText = p.rounded() == p ? String(format: "%.0f", p) : String(p) }
        }
    }

    private func applyCustom() {
        guard let v = Double(customText.replacingOccurrences(of: ",", with: ".")), v >= 0 else { return }
        prefs.planChoice[service.rawValue] = "custom"
        prefs.planPrices[service.rawValue] = v
        open = false
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6) }

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.faint)
            .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 2)
    }

    private func row(title: String, detail: String?, price: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        PlanListRow(title: title, detail: detail, price: price, selected: selected, action: action)
    }
}

private struct PlanListRow: View {
    let title: String
    let detail: String?
    let price: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent).opacity(selected ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    if let detail { Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.dim) }
                }
                Spacer()
                if let price { Text(price).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.dim) }
            }
            .padding(.horizontal, 8).frame(minHeight: detail == nil ? 28 : 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.ink.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Alerts

private struct AlertsPane: View {
    @ObservedObject var prefs: Prefs
    @State private var hookInstalled = Hook.isInstalled
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                SettingRow(title: "Notifications", detail: "Banners when a plan nears its limit, resets, or is on pace to run out early.", icon: "bell.badge") {
                    Toggle("", isOn: $prefs.alertsEnabled).toggleStyle(PillToggle())
                }
            }

            SectionTitle("Warn me at")
            HStack(spacing: 12) {
                ThresholdChip(percent: 80, label: "Heads-up", on: prefs.thresholds.contains(80)) { toggle(80) }
                ThresholdChip(percent: 95, label: "Last call", on: prefs.thresholds.contains(95)) { toggle(95) }
            }
            .opacity(prefs.alertsEnabled ? 1 : 0.45)

            SectionTitle("Also tell me")
            Card {
                SettingRow(title: "When a limit resets", detail: "So you know you're clear to go again.") {
                    Toggle("", isOn: $prefs.alertOnReset).toggleStyle(PillToggle())
                }
                SettingRow(title: "When I'm on pace to run out early", detail: "From your average pace since the window opened.") {
                    Toggle("", isOn: $prefs.alertOnPace).toggleStyle(PillToggle())
                }
            }
            .opacity(prefs.alertsEnabled ? 1 : 0.45)

            SectionTitle("Before-cutoff hook")
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.06)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run a script on every alert").font(.system(size: 13))
                        Text("Save work or pause an agent before a limit hits. It runs even with notifications off.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(hookInstalled ? Theme.good : Theme.faint).frame(width: 6, height: 6)
                        Text(hookInstalled ? "Installed" : "Not set up").font(.system(size: 11, weight: .medium))
                            .foregroundStyle(hookInstalled ? Theme.good : Theme.dim)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((hookInstalled ? Theme.good : Theme.ink).opacity(0.1)))
                }
                HStack(spacing: 8) {
                    Text("~/.config/tally/hook").font(.system(size: 11.5, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.06)))
                    Text("Details arrive in TALLY_* variables").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    Spacer()
                }
                HStack(spacing: 8) {
                    SmallButton(title: testing ? "Running…" : "Run test", icon: "play.fill", enabled: hookInstalled && !testing) { runTest() }
                    SmallButton(title: "Open folder", icon: "folder", enabled: true) { openFolder() }
                    SmallButton(title: "Examples", icon: "book", enabled: true) {
                        NSWorkspace.shared.open(URL(string: "https://github.com/PratikRai0101/tally#before-cutoff-hook")!)
                    }
                    Spacer()
                    if let testResult { Text(testResult).font(.system(size: 11)).foregroundStyle(Theme.dim) }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            .onAppear { hookInstalled = Hook.isInstalled }
        }
    }

    private func toggle(_ t: Int) {
        if prefs.thresholds.contains(t) { prefs.thresholds.remove(t) } else { prefs.thresholds.insert(t) }
    }

    private func runTest() {
        testing = true
        Task.detached {
            let status = Hook.test()
            await MainActor.run {
                testing = false
                testResult = status == 0 ? "Ran fine (exit 0)" : "Exited with \(status)"
            }
        }
    }

    private func openFolder() {
        let dir = Hook.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
        hookInstalled = Hook.isInstalled
    }
}

private struct ThresholdChip: View {
    let percent: Int
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(percent)%").font(.system(size: 22, weight: .semibold, design: .monospaced))
                    Text(label).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(on ? Theme.accent : Theme.faint)
                }
                DitherMeter(color: on ? Theme.severity(Double(percent)) : Theme.faint, used: Double(percent) / 100, pace: nil)
                    .frame(height: 12)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Theme.accent.opacity(0.8) : Theme.line, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SmallButton: View {
    let title: String
    let icon: String
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.ink.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - Panel

private struct PanelPane: View {
    @ObservedObject var prefs: Prefs
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Sections")
            Card {
                SettingRow(title: "Token history", detail: "The dotted chart of usage over time on each plan's card.", icon: "chart.bar.xaxis") {
                    Toggle("", isOn: $prefs.tokenHistory).toggleStyle(PillToggle())
                }
                SettingRow(title: "Spend by project", detail: "Which repos your money went to. Project names stay on this Mac.", icon: "folder") {
                    Toggle("", isOn: $prefs.showProjects).toggleStyle(PillToggle())
                }
                SettingRow(title: "Spend by model", detail: "A map of every model, sized by its share of spend.", icon: "square.grid.2x2") {
                    Toggle("", isOn: $prefs.modelMap).toggleStyle(PillToggle())
                }
            }
            Footnote("Plans are switched on or off, and reordered, in Plans.")
        }
    }
}

// MARK: - Shared controls

struct ReorderDrop: DropDelegate {
    let target: Service
    @Binding var dragging: Service?
    let prefs: Prefs

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target,
              let fi = prefs.order.firstIndex(of: from), let ti = prefs.order.firstIndex(of: target) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            prefs.order.move(fromOffsets: IndexSet(integer: fi), toOffset: ti > fi ? ti + 1 : ti)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct Segmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { o in
                Button { withAnimation(.easeOut(duration: 0.12)) { selection = o } } label: {
                    Text(label(o))
                        .font(.system(size: 11.5, weight: selection == o ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4.5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selection == o ? Theme.raised : .clear)
                            .shadow(color: .black.opacity(selection == o ? 0.18 : 0), radius: 1.5, y: 0.5))
                        .foregroundStyle(selection == o ? Theme.text : Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.06)))
    }
}

/// A compact switch drawn in SwiftUI (matches the panel, renders in snapshots).
struct PillToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.accent : Theme.ink.opacity(0.15))
                Circle().fill(Color.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: 32, height: 19)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    var store: UsageStore?

    /// Set on the window rather than with SwiftUI's preferredColorScheme, which doesn't go back to System
    /// (nil) until the app loses and regains focus.
    func applyAppearance() {
        window?.appearance = Prefs.shared.nsAppearance
    }

    func show(pane: SettingsPane? = nil) {
        guard let store else { return }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(store: store, pane: pane ?? .plans))
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Tally Settings"
            w.isMovableByWindowBackground = true
            w.setContentSize(NSSize(width: 780, height: min(640, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
            w.contentMinSize = NSSize(width: 780, height: 480)
            w.contentMaxSize = NSSize(width: 780, height: 2000)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        } else if let pane, let host = window?.contentViewController as? NSHostingController<SettingsView> {
            host.rootView = SettingsView(store: store, pane: pane)
        }
        applyAppearance()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
