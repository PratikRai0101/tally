import AppKit
import ServiceManagement
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable { case columns = "Columns", bars = "Bars"; var id: String { rawValue } }
enum PercentMode: String, CaseIterable, Identifiable { case never = "Never", high = "High usage", always = "Always"; var id: String { rawValue } }
/// What the label next to each menu bar meter shows.
enum LabelKind: String, CaseIterable, Identifiable { case percent = "% used", cost = "Cost", tokens = "Tokens"; var id: String { rawValue } }
/// Time range for cost / token labels.
enum LabelPeriod: String, CaseIterable, Identifiable {
    case today = "Today", week = "7d", month = "30d"
    var id: String { rawValue }
}
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
    @Published var labelKind: LabelKind { didSet { d.set(labelKind.rawValue, forKey: "labelKind"); changed() } }
    @Published var labelPeriod: LabelPeriod { didSet { d.set(labelPeriod.rawValue, forKey: "labelPeriod"); changed() } }
    @Published var spendMode: SpendMode { didSet { d.set(spendMode.rawValue, forKey: "spendMode"); changed() } }
    /// Whether the menu bar total is dollars or tokens.
    @Published var totalMetric: Metric { didSet { d.set(totalMetric.rawValue, forKey: "totalMetric"); changed() } }
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
    /// The plan picked in Settings → Plans, keyed by service raw value: a PlanCatalog id, or "custom" (price in planPrices).
    @Published var planChoice: [String: String] { didSet { d.set(planChoice, forKey: "planChoice"); changed() } }

    var onChange: (() -> Void)?

    private init() {
        let saved = (d.stringArray(forKey: "order") ?? []).compactMap(Service.init(rawValue:))
        order = saved + Service.allCases.filter { !saved.contains($0) }
        hidden = Set((d.stringArray(forKey: "hidden") ?? []).compactMap(Service.init(rawValue:)))
        menuHidden = Set((d.stringArray(forKey: "menuHidden") ?? []).compactMap(Service.init(rawValue:)))
        menuStyle = MenuBarStyle(rawValue: d.string(forKey: "menuStyle") ?? "") ?? .columns
        meterSource = MeterSource(rawValue: d.string(forKey: "meterSource") ?? "") ?? .tightest
        percentMode = PercentMode(rawValue: d.string(forKey: "percentMode") ?? "") ?? .high
        labelKind = LabelKind(rawValue: d.string(forKey: "labelKind") ?? "") ?? .percent
        labelPeriod = LabelPeriod(rawValue: d.string(forKey: "labelPeriod") ?? "") ?? .today
        totalMetric = Metric(rawValue: d.string(forKey: "totalMetric") ?? "") ?? .cost
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
        planChoice = (d.dictionary(forKey: "planChoice") as? [String: String]) ?? [:]
    }

    private func changed() { onChange?() }

    func isOn(_ s: Service) -> Bool { !hidden.contains(s) }
    func toggle(_ s: Service, _ on: Bool) { if on { hidden.remove(s) } else { hidden.insert(s) } }
    func inMenuBar(_ s: Service) -> Bool { !menuHidden.contains(s) }
    func toggleMenu(_ s: Service, _ on: Bool) { if on { menuHidden.remove(s) } else { menuHidden.insert(s) } }

    /// The plan in effect: what you picked, else what the provider reports. nil means a custom price (or nothing known).
    func planOption(_ s: Service, detected: String?) -> PlanOption? {
        if let c = planChoice[s.rawValue] { return PlanCatalog.option(s, id: c) }
        let auto = PlanCatalog.detect(s, plan: detected)
        // A price typed in before plans had a picker: keep it unless it's just the detected plan's price.
        if let typed = planPrices[s.rawValue], typed != auto?.price { return nil }
        return auto
    }

    func price(_ s: Service, plan: String?) -> Double {
        if let o = planOption(s, detected: plan) { return o.price }
        return planPrices[s.rawValue] ?? 0
    }

    func choosePlan(_ s: Service, _ id: String?) {
        if let id { planChoice[s.rawValue] = id } else { planChoice.removeValue(forKey: s.rawValue) }
        if id != "custom" { planPrices.removeValue(forKey: s.rawValue) }
    }

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

