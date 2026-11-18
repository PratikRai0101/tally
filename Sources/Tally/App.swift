import AppKit
import SwiftUI

@main
struct TallyMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") { Dump.run(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshot.run(to: CommandLine.arguments[i + 1]) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var store: UsageStore!
    private let prefs = Prefs.shared
    private var tick: Timer?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
        }
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        applyAppearance()

        store.onChange = { [weak self] in self?.updateStatusItem() }
        prefs.onChange = { [weak self] in
            self?.applyAppearance()
            self?.updateStatusItem()
            self?.updateHotKey()
        }
        SettingsWindow.shared.plans = { [weak self] in
            Dictionary(uniqueKeysWithValues: (self?.store.limits ?? [:]).compactMap { k, v in v.plan.map { (k, $0) } })
        }
        Notifier.shared.requestPermission()
        updateHotKey()
        updateStatusItem()
        if CommandLine.arguments.contains("--open-settings") { SettingsWindow.shared.show() }
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }

    private func applyAppearance() {
        popover.appearance = prefs.nsAppearance
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Tally", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePopover()
    }

    private func updateHotKey() {
        if prefs.hotkeyEnabled, hotKey == nil {
            hotKey = HotKey { [weak self] in self?.togglePopover() }
        } else if !prefs.hotkeyEnabled, let h = hotKey {
            h.unregister(); hotKey = nil
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        store.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshNow() { store.refresh(force: true) }
    @objc private func openSettings() { SettingsWindow.shared.show() }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let entries: [MenuBarRenderer.Entry] = store.visibleServices(prefs).compactMap { s in
            guard s.hasLimits, prefs.inMenuBar(s) else { return nil }
            return MenuBarRenderer.Entry(service: s, used: store.meterWindow(s, prefs.meterSource).map { $0.usedPercent / 100 },
                                         live: store.live[s] != nil)
        }
        let spend: String? = store.lastUpdated == nil ? "…" : store.spend(prefs.spendMode).map(Fmt.moneyShort)
        button.image = MenuBarRenderer.image(entries: entries, style: prefs.menuStyle, percents: prefs.percentMode,
                                             colored: prefs.colorBars, trailing: spend, logos: prefs.showLogos)
        button.toolTip = store.visibleServices(prefs).compactMap { s -> String? in
            guard let w = store.limits[s]?.binding else { return nil }
            return "\(s.name): \(w.title.lowercased()) \(Int(w.usedPercent))% used, resets in \(Fmt.countdown(to: w.resetsAt))"
        }.joined(separator: "\n") + "\nToday: \(Fmt.money(store.todayCost))"
    }
}

/// Draws the whole status item as one image: [icon][meter] per service, then today's spend.
enum MenuBarRenderer {
    struct Entry { let service: Service; let used: Double?; var live = false }

    static func image(entries: [Entry], style: MenuBarStyle, percents: PercentMode, colored: Bool, trailing: String?,
                      logos: Bool = true) -> NSImage {
        let h: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let spendFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let iconW: CGFloat = logos ? 14 : 0
        let meterW: CGFloat = style == .columns ? 6 : 20
        let gap: CGFloat = 3, between: CGFloat = 9

        func pctText(_ used: Double?) -> String? {
            guard let used else { return nil }
            switch percents {
            case .never: return nil
            case .always: return "\(Int((used * 100).rounded()))%"
            case .high: return used >= 0.7 ? "\(Int((used * 100).rounded()))%" : nil
            }
        }
        let pctW: [CGFloat] = entries.map { e in
            pctText(e.used).map { ($0 as NSString).size(withAttributes: [.font: font]).width + 2 } ?? 0
        }
        let spendW = trailing.map { ($0 as NSString).size(withAttributes: [.font: spendFont]).width } ?? 0
        var width: CGFloat = 0
        for (i, _) in entries.enumerated() { width += iconW + (logos ? gap : 0) + meterW + pctW[i] + (i < entries.count - 1 ? between : 0) }
        if spendW > 0 { width += (entries.isEmpty ? 0 : between) + spendW }
        width = max(width, 16)

        let img = NSImage(size: NSSize(width: ceil(width), height: h), flipped: true) { _ in
            let label = NSColor.labelColor
            var x: CGFloat = 0
            for (i, e) in entries.enumerated() {
                if !logos {
                    // no icon
                } else if let logo = e.service.monoLogo {
                    let side: CGFloat = 13
                    tinted(logo.image, label).draw(in: NSRect(x: x + (iconW - side) / 2, y: (h - side) / 2, width: side, height: side))
                } else {
                    let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
                        .applying(.init(paletteColors: [label]))
                    if let sym = NSImage(systemSymbolName: e.service.symbol, accessibilityDescription: e.service.name)?
                        .withSymbolConfiguration(cfg) {
                        let s = sym.size
                        sym.draw(in: NSRect(x: x + (iconW - s.width) / 2, y: (h - s.height) / 2, width: s.width, height: s.height))
                    }
                }
                if logos && e.live {
                    // a small dot under the logo while a session is running
                    (colored ? NSColor(hex: 0x42C08D) : label).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x + iconW - 3.5, y: h - 5, width: 3.5, height: 3.5)).fill()
                }
                x += iconW + (logos ? gap : 0)
                let used = min(1, max(0, e.used ?? 0))
                let fillColor: NSColor = colored ? severity(used) : label
                drawMeter(at: x, style: style, width: meterW, height: h, used: used, known: e.used != nil,
                          fill: fillColor, empty: label.withAlphaComponent(0.22))
                x += meterW
                if let t = pctText(e.used) {
                    (t as NSString).draw(at: NSPoint(x: x + 2, y: (h - font.capHeight) / 2 - 3),
                                         withAttributes: [.font: font, .foregroundColor: colored ? severity(used) : label])
                    x += pctW[i]
                }
                if i < entries.count - 1 { x += between }
            }
            if let trailing {
                if !entries.isEmpty { x += between }
                (trailing as NSString).draw(at: NSPoint(x: x, y: (h - spendFont.capHeight) / 2 - 3.5),
                                            withAttributes: [.font: spendFont, .foregroundColor: label])
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Columns: 3×7 dot column that fills bottom-up. Bars: 10×3 dot bar that fills left-to-right.
    private static func drawMeter(at x0: CGFloat, style: MenuBarStyle, width: CGFloat, height: CGFloat,
                                  used: Double, known: Bool, fill: NSColor, empty: NSColor) {
        let pitch: CGFloat = 2, dot: CGFloat = 1.6
        if style == .columns {
            let cols = 3, rows = 7
            let top = (height - CGFloat(rows) * pitch) / 2
            let filled = used * Double(rows)
            for r in 0..<rows {
                let fromBottom = rows - 1 - r
                let level = filled - Double(fromBottom)
                for c in 0..<cols {
                    let on = known && (level >= 1 || (level > 0 && Bayer.on(c, r, level)))
                    (on ? fill : empty).setFill()
                    NSRect(x: x0 + CGFloat(c) * pitch, y: top + CGFloat(r) * pitch, width: dot, height: dot).fill()
                }
            }
        } else {
            let cols = 10, rows = 3
            let top = (height - CGFloat(rows) * pitch) / 2
            let filled = used * Double(cols)
            for c in 0..<cols {
                let level = filled - Double(c)
                for r in 0..<rows {
                    let on = known && (level >= 1 || (level > 0 && Bayer.on(c, r, level)))
                    (on ? fill : empty).setFill()
                    NSRect(x: x0 + CGFloat(c) * pitch, y: top + CGFloat(r) * pitch, width: dot, height: dot).fill()
                }
            }
        }
    }

    /// Paints a template logo in `color` (needed because the status item is one composite, non-template image).
    private static func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func severity(_ used: Double) -> NSColor {
        used >= 0.9 ? NSColor(hex: 0xE5484D) : (used >= 0.7 ? NSColor(hex: 0xE5B23C) : NSColor(hex: 0x42C08D))
    }
}

/// `Tally --dump` prints what the panel would show, for checking numbers from the terminal.
enum Dump {
    static func run() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let pricing = Pricing()
            await pricing.load()
            let t0 = Date()
            let res = UsageScanner(pricing: pricing).scan(since: Date().addingTimeInterval(-Period.month.seconds))
            print(String(format: "scanned %d records in %.2fs", res.records.count, Date().timeIntervalSince(t0)))
            for period in Period.allCases {
                let since = Date().addingTimeInterval(-period.seconds)
                let rs = res.records.filter { $0.date >= since }
                print("\n== \(period.label): \(Fmt.money(rs.reduce(0) { $0 + $1.cost })) · \(Fmt.tokens(rs.reduce(0) { $0 + $1.tokens }))")
                for s in Service.allCases {
                    let sr = rs.filter { $0.service == s }
                    guard !sr.isEmpty else { continue }
                    let tools = Dictionary(grouping: sr, by: \.tool).map { "\($0.key.name) \(Fmt.money($0.value.reduce(0) { $0 + $1.cost }))" }
                    print("  \(s.name.padding(toLength: 13, withPad: " ", startingAt: 0)) \(Fmt.money(sr.reduce(0) { $0 + $1.cost }))  \(Fmt.tokens(sr.reduce(0) { $0 + $1.tokens }))  [\(tools.joined(separator: ", "))]")
                }
            }
            async let c = LimitsFetcher.claude()
            async let x = LimitsFetcher.codex(fallback: res.codexLogLimits)
            async let g = LimitsFetcher.opencodeGo()
            for l in await [c, x, g] {
                print("\n\(l.service.name) [\(l.plan ?? "?")] \(l.source ?? "") \(l.error ?? "") \(l.notes.map { "\($0.0): \($0.1)" }.joined(separator: ", "))")
                for w in l.windows { print("  \(w.title): \(Int(w.usedPercent))% used, resets in \(Fmt.countdown(to: w.resetsAt))") }
            }
            sem.signal()
        }
        sem.wait()
    }
}

/// `Tally --snapshot out.png` renders the panel to a PNG (used for design checks).
/// Env: TALLY_PERIOD=24h|7d|30d, TALLY_TOKENS=1, TALLY_LIGHT=1, TALLY_MENUBAR=path.png
@MainActor
enum Snapshot {
    static func run(to path: String) {
        _ = NSApplication.shared
        let env = ProcessInfo.processInfo.environment
        if env["TALLY_SETTINGS"] != nil {
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                let r = ImageRenderer(content: SettingsView(scrolls: false).environment(\.colorScheme, .dark))
                r.scale = 2
                write(r.nsImage, to: path, scale: 2)
            }
            return
        }
        let store = UsageStore()
        let deadline = Date().addingTimeInterval(60)
        while (store.lastUpdated == nil || store.isLoading) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        if let p = env["TALLY_PERIOD"], let per = Period(rawValue: p) { store.period = per }
        if env["TALLY_TOKENS"] != nil { store.metric = .tokens }
        let light = env["TALLY_LIGHT"] != nil
        let view = PopoverView(store: store, fixedHeight: true).environment(\.colorScheme, light ? .light : .dark)
        NSAppearance(named: light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: view)
            r.scale = 2
            write(r.nsImage, to: path, scale: 2)
            if let mb = env["TALLY_MENUBAR"] {
                let prefs = Prefs.shared
                var imgs: [NSImage] = []
                for style in MenuBarStyle.allCases {
                    let entries = store.visibleServices(prefs).filter(\.hasLimits).map {
                        MenuBarRenderer.Entry(service: $0, used: store.limits[$0]?.binding.map { $0.usedPercent / 100 })
                    }
                    imgs.append(MenuBarRenderer.image(entries: entries, style: style, percents: .always, colored: true,
                                                      trailing: Fmt.moneyShort(store.todayCost)))
                }
                let w = imgs.map(\.size.width).max() ?? 0
                let combo = NSImage(size: NSSize(width: w + 16, height: 22 * CGFloat(imgs.count) + 8), flipped: true) { rect in
                    (light ? NSColor(hex: 0xE8E6E1) : NSColor(hex: 0x2A2A2E)).setFill(); rect.fill()
                    for (i, im) in imgs.enumerated() { im.draw(in: NSRect(x: 8, y: 6 + CGFloat(i) * 22, width: im.size.width, height: im.size.height)) }
                    return true
                }
                write(combo, to: mb, scale: 4)
            }
        }
        print("wrote \(path)")
    }

    private static func write(_ img: NSImage?, to path: String, scale: CGFloat = 1) {
        guard let img else { return }
        var rect = NSRect(origin: .zero, size: NSSize(width: img.size.width * scale, height: img.size.height * scale))
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}
