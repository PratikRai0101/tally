import AppKit
import ServiceManagement
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable { case columns = "Columns", bars = "Bars"; var id: String { rawValue } }
enum PercentMode: String, CaseIterable, Identifiable { case never = "Never", high = "High usage", always = "Always"; var id: String { rawValue } }
enum AppearanceMode: String, CaseIterable, Identifiable { case system = "System", light = "Light", dark = "Dark"; var id: String { rawValue } }
/// Which limit each menu bar meter shows.
enum MeterSource: String, CaseIterable, Identifiable { case tightest = "Tightest", session = "Session", weekly = "Weekly"; var id: String { rawValue } }
/// What the number after the meters shows.
enum SpendMode: String, CaseIterable, Identifiable {
    case off = "Off", today = "Today", week = "7d", month = "30d"
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var order: [Service] { didSet { d.set(order.map(\.rawValue), forKey: "order"); changed() } }
    @Published var hidden: Set<Service> { didSet { d.set(hidden.map(\.rawValue), forKey: "hidden"); changed() } }
    @Published var menuHidden: Set<Service> { didSet { d.set(menuHidden.map(\.rawValue), forKey: "menuHidden"); changed() } }
    @Published var menuStyle: MenuBarStyle { didSet { d.set(menuStyle.rawValue, forKey: "menuStyle"); changed() } }
    @Published var meterSource: MeterSource { didSet { d.set(meterSource.rawValue, forKey: "meterSource"); changed() } }
    @Published var percentMode: PercentMode { didSet { d.set(percentMode.rawValue, forKey: "percentMode"); changed() } }
    @Published var spendMode: SpendMode { didSet { d.set(spendMode.rawValue, forKey: "spendMode"); changed() } }
    @Published var showLogos: Bool { didSet { d.set(showLogos, forKey: "showLogos"); changed() } }
    @Published var tokenHistory: Bool { didSet { d.set(tokenHistory, forKey: "tokenHistory"); changed() } }
    @Published var modelMap: Bool { didSet { d.set(modelMap, forKey: "modelMap"); changed() } }
    @Published var showProjects: Bool { didSet { d.set(showProjects, forKey: "showProjects"); changed() } }
    @Published var appearance: AppearanceMode { didSet { d.set(appearance.rawValue, forKey: "appearance"); changed() } }
    @Published var colorBars: Bool { didSet { d.set(colorBars, forKey: "colorBars"); changed() } }
    @Published var alertsEnabled: Bool { didSet { d.set(alertsEnabled, forKey: "alertsEnabled"); changed() } }
    @Published var thresholds: Set<Int> { didSet { d.set(Array(thresholds), forKey: "thresholds"); changed() } }
    @Published var alertOnReset: Bool { didSet { d.set(alertOnReset, forKey: "alertOnReset"); changed() } }
    @Published var alertOnPace: Bool { didSet { d.set(alertOnPace, forKey: "alertOnPace"); changed() } }
    @Published var hotkeyEnabled: Bool { didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled"); changed() } }
    /// Monthly price overrides, keyed by service raw value.
    @Published var planPrices: [String: Double] { didSet { d.set(planPrices, forKey: "planPrices"); changed() } }

    var onChange: (() -> Void)?

    private init() {
        let saved = (d.stringArray(forKey: "order") ?? []).compactMap(Service.init(rawValue:))
        order = saved + Service.allCases.filter { !saved.contains($0) }
        hidden = Set((d.stringArray(forKey: "hidden") ?? []).compactMap(Service.init(rawValue:)))
        menuHidden = Set((d.stringArray(forKey: "menuHidden") ?? []).compactMap(Service.init(rawValue:)))
        menuStyle = MenuBarStyle(rawValue: d.string(forKey: "menuStyle") ?? "") ?? .columns
        meterSource = MeterSource(rawValue: d.string(forKey: "meterSource") ?? "") ?? .tightest
        percentMode = PercentMode(rawValue: d.string(forKey: "percentMode") ?? "") ?? .high
        spendMode = SpendMode(rawValue: d.string(forKey: "spendMode") ?? "") ?? ((d.object(forKey: "showSpend") as? Bool) == false ? .off : .today)
        showLogos = d.object(forKey: "showLogos") as? Bool ?? true
        tokenHistory = d.object(forKey: "tokenHistory") as? Bool ?? true
        modelMap = d.object(forKey: "modelMap") as? Bool ?? true
        showProjects = d.object(forKey: "showProjects") as? Bool ?? true
        appearance = AppearanceMode(rawValue: d.string(forKey: "appearance") ?? "") ?? .dark
        colorBars = d.object(forKey: "colorBars") as? Bool ?? true
        alertsEnabled = d.object(forKey: "alertsEnabled") as? Bool ?? true
        thresholds = Set((d.array(forKey: "thresholds") as? [Int]) ?? [80, 95])
        alertOnReset = d.object(forKey: "alertOnReset") as? Bool ?? true
        alertOnPace = d.object(forKey: "alertOnPace") as? Bool ?? true
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        planPrices = (d.dictionary(forKey: "planPrices") as? [String: Double]) ?? [:]
    }

    private func changed() { onChange?() }

    func isOn(_ s: Service) -> Bool { !hidden.contains(s) }
    func toggle(_ s: Service, _ on: Bool) { if on { hidden.remove(s) } else { hidden.insert(s) } }
    func inMenuBar(_ s: Service) -> Bool { !menuHidden.contains(s) }
    func toggleMenu(_ s: Service, _ on: Bool) { if on { menuHidden.remove(s) } else { menuHidden.insert(s) } }

    func price(_ s: Service, plan: String?) -> Double { planPrices[s.rawValue] ?? PlanPricing.defaultPrice(for: s, plan: plan) }

    var nsAppearance: NSAppearance? {
        switch appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var prefs = Prefs.shared
    var plans: [Service: String] = [:]
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    @State private var dragging: Service?
    var scrolls = true

    var body: some View {
        Group {
            if scrolls { ScrollView(.vertical, showsIndicators: false) { form } } else { form }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .frame(width: 440)
        .background(Theme.bg)
        .preferredColorScheme(prefs.colorScheme)
    }

    private var form: some View {
            VStack(alignment: .leading, spacing: 6) {
                group("Providers") {
                    HStack {
                        Spacer()
                        Text("Panel").frame(width: 44)
                        Text("Menu bar").frame(width: 56)
                    }
                    .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 10).padding(.top, 6)
                    ForEach(prefs.order) { s in
                        row {
                            Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(Theme.faint)
                            ServiceMark(service: s, size: 20)
                            Text(s.name)
                            Spacer()
                            Toggle("", isOn: Binding(get: { prefs.isOn(s) }, set: { prefs.toggle(s, $0) }))
                                .toggleStyle(PillToggle()).frame(width: 44)
                            Group {
                                if s.hasLimits {
                                    Toggle("", isOn: Binding(get: { prefs.inMenuBar(s) }, set: { prefs.toggleMenu(s, $0) }))
                                        .toggleStyle(PillToggle())
                                } else {
                                    Text("—").foregroundStyle(Theme.faint)
                                }
                            }
                            .frame(width: 56)
                        }
                        .contentShape(Rectangle())
                        .opacity(dragging == s ? 0.4 : 1)
                        .onDrag {
                            dragging = s
                            return NSItemProvider(object: s.rawValue as NSString)
                        }
                        .onDrop(of: [.text], delegate: ReorderDrop(target: s, dragging: $dragging, prefs: prefs))
                    }
                }
                caption("Drag to reorder. Only plans with limits can show a meter in the menu bar.")

                group("Menu bar") {
                    row { Text("Style"); Spacer(); Segmented(options: MenuBarStyle.allCases, selection: $prefs.menuStyle) { $0.rawValue } }
                    row { Text("Meter shows"); Spacer(); Segmented(options: MeterSource.allCases, selection: $prefs.meterSource) { $0.rawValue } }
                    row { Text("Percentages"); Spacer(); Segmented(options: PercentMode.allCases, selection: $prefs.percentMode) { $0.rawValue } }
                    row { Text("Spend"); Spacer(); Segmented(options: SpendMode.allCases, selection: $prefs.spendMode) { $0.rawValue } }
                    row { Text("Logos"); Spacer(); Toggle("", isOn: $prefs.showLogos).toggleStyle(PillToggle()) }
                }
                caption("“Tightest” shows whichever limit of that plan is closest to running out.")

                group("Alerts") {
                    row { Text("Notifications"); Spacer(); Toggle("", isOn: $prefs.alertsEnabled).toggleStyle(PillToggle()) }
                    row {
                        Text("Warn at"); Spacer()
                        ForEach([80, 95], id: \.self) { t in
                            Toggle(isOn: Binding(get: { prefs.thresholds.contains(t) },
                                                 set: { if $0 { prefs.thresholds.insert(t) } else { prefs.thresholds.remove(t) } })) {
                                Text("\(t)%").font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    row { Text("When a limit resets"); Spacer(); Toggle("", isOn: $prefs.alertOnReset).toggleStyle(PillToggle()) }
                    row { Text("On pace to run out early"); Spacer(); Toggle("", isOn: $prefs.alertOnPace).toggleStyle(PillToggle()) }
                }
                .disabled(false)

                group("Plan prices") {
                    ForEach([Service.claude, .codex, .opencodeGo], id: \.self) { s in
                        row {
                            ServiceMark(service: s, size: 18)
                            Text(plans[s] ?? s.name)
                            Spacer()
                            Text("$").foregroundStyle(Theme.dim)
                            TextField("", value: Binding(get: { prefs.price(s, plan: plans[s]) },
                                                         set: { prefs.planPrices[s.rawValue] = max(0, $0) }),
                                      format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 52)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.06)))
                            Text("/ mo").foregroundStyle(Theme.dim)
                        }
                    }
                }
                caption("Used for “value”: what your usage would cost at API prices vs what you pay.")

                group("Panel") {
                    row { Text("Token history"); Spacer(); Toggle("", isOn: $prefs.tokenHistory).toggleStyle(PillToggle()) }
                    row { Text("Spend by project"); Spacer(); Toggle("", isOn: $prefs.showProjects).toggleStyle(PillToggle()) }
                    row { Text("Spend by model"); Spacer(); Toggle("", isOn: $prefs.modelMap).toggleStyle(PillToggle()) }
                }

                group("General") {
                    row { Text("Appearance"); Spacer(); Segmented(options: AppearanceMode.allCases, selection: $prefs.appearance) { $0.rawValue } }
                    row { Text("Color bars by usage"); Spacer(); Toggle("", isOn: $prefs.colorBars).toggleStyle(PillToggle()) }
                    row {
                        Text("Open panel with")
                        Text("⌥⌘U").font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.08)))
                        Spacer()
                        Toggle("", isOn: $prefs.hotkeyEnabled).toggleStyle(PillToggle())
                    }
                    row {
                        Text("Launch at login"); Spacer()
                        Toggle("", isOn: Binding(get: { loginOn }, set: { on in
                            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                            loginOn = SMAppService.mainApp.status == .enabled
                        }))
                        .toggleStyle(PillToggle())
                    }
                }

                Text("Tally v1.2")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity).padding(.top, 10)
            }
            .padding(16)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.dim).padding(.top, 8)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 10).frame(height: 32)
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Theme.faint)
    }
}

private struct ReorderDrop: DropDelegate {
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
                Button { selection = o } label: {
                    Text(label(o))
                        .font(.system(size: 11.5, weight: selection == o ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selection == o ? Theme.ink.opacity(0.12) : .clear))
                        .foregroundStyle(selection == o ? Theme.text : Theme.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.05)))
    }
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    var plans: () -> [Service: String] = { [:] }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(plans: plans()))
            let w = NSWindow(contentViewController: host)
            w.setContentSize(NSSize(width: 440, height: min(780, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
            w.title = "Tally Settings"
            w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.appearance = Prefs.shared.nsAppearance
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A compact switch drawn in SwiftUI (matches the panel, renders in snapshots).
struct PillToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() } } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Color(hex: 0x3B82F6) : Theme.ink.opacity(0.15))
                Circle().fill(Color.white).padding(2).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
            .frame(width: 30, height: 18)
        }
        .buttonStyle(.plain)
    }
}
