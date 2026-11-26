import AppKit
import SwiftUI

@main
struct TallyMain {
    static func main() {
        if CommandLine.arguments.contains("--dump") { Dump.run(); return }
        // `Tally --parse cursor|grok response.json` checks the parsers against a saved response.
        if let i = CommandLine.arguments.firstIndex(of: "--parse"), CommandLine.arguments.count > i + 2,
           let data = FileManager.default.contents(atPath: CommandLine.arguments[i + 2]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let cursor = CommandLine.arguments[i + 1] == "cursor"
            var l = ServiceLimits(service: cursor ? .cursor : .grok, windows: [])
            if cursor { LimitsFetcher.parseCursor(json, into: &l) } else { LimitsFetcher.parseGrok(json, into: &l) }
            print("[\(l.plan ?? "?")] \(l.error ?? "") \(l.notes.map { "\($0.0): \($0.1)" }.joined(separator: ", "))")
            for w in l.windows { print("  \(w.title): \(String(format: "%.1f", w.usedPercent))% used, window \(Int((w.windowSeconds ?? 0) / 86_400))d, resets in \(Fmt.countdown(to: w.resetsAt))") }
            return
        }
        if CommandLine.arguments.contains("--test-hook") { exit(Hook.test()) }
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
        SettingsWindow.shared.store = store
        Notifier.shared.requestPermission()
        updateHotKey()
        updateStatusItem()
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--open-settings") }) {
            SettingsWindow.shared.show(pane: SettingsPane(rawValue: String(a.split(separator: "=").last ?? "")))
        }
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }

    private func applyAppearance() {
        popover.appearance = prefs.nsAppearance
        SettingsWindow.shared.applyAppearance()
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
        button.image = MenuBarRenderer.statusImage(store: store, prefs: prefs)
        let display = prefs.limitDisplay
        button.toolTip = store.visibleServices(prefs).compactMap { s -> String? in
            guard let w = store.limits[s]?.binding else { return nil }
            let pct = display == .remaining ? display.summary(used: w.usedPercent) : "\(Int(w.usedPercent))% used"
            return "\(s.name): \(w.title.lowercased()) \(pct), resets in \(Fmt.countdown(to: w.resetsAt))"
        }.joined(separator: "\n") + "\nToday: \(Fmt.money(store.todayCost))"
    }
}

/// Draws the whole status item as one image: [icon][meter] per service, then today's spend.
enum MenuBarRenderer {
    struct Entry { let service: Service; let used: Double?; var cost: Double = 0; var tokens: Int = 0; var live = false }

    /// The status item image for the current numbers and prefs (also drawn in Settings → Menu bar).
    @MainActor static func statusImage(store: UsageStore, prefs: Prefs) -> NSImage {
        let entries: [Entry] = store.visibleServices(prefs).compactMap { s in
            guard s.hasLimits, prefs.inMenuBar(s), s.showsWithoutUsage || store.limits[s]?.windows.isEmpty == false else { return nil }
            let t = store.labelTotals[prefs.labelPeriod]?[s]
            return Entry(service: s, used: store.meterWindow(s, prefs.meterSource).map { $0.usedPercent / 100 },
                         cost: t?.cost ?? 0, tokens: t?.tokens ?? 0, live: store.live[s] != nil)
        }
        let spend: String? = store.lastUpdated == nil ? "…" : store.total(prefs.spendMode, prefs.totalMetric)
        return image(entries: entries, style: prefs.menuStyle, percents: prefs.percentMode, label: prefs.labelKind, display: prefs.limitDisplay,
                     colored: prefs.colorBars, trailing: spend, logos: prefs.showLogos)
    }

    static func image(entries: [Entry], style: MenuBarStyle, percents: PercentMode, label kind: LabelKind = .percent, display: QuotaDisplay = .used,
                      colored: Bool, trailing: String?,
                      logos: Bool = true) -> NSImage {
        let h: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let spendFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let iconW: CGFloat = logos ? 14 : 0
        let meterW: CGFloat = style == .columns ? 6 : 20
        let gap: CGFloat = 3, between: CGFloat = 9

        /// The label after a meter: % used, % left, cost or tokens; "High usage" shows it only once the limit passes 70%.
        func labelText(_ e: Entry) -> String? {
            switch percents {
            case .never: return nil
            case .high: guard let u = e.used, u >= 0.7 else { return nil }
            case .always: break
            }
            switch kind {
            case .off: return nil
            case .percent: return e.used.map { display.label(used: $0 * 100) }
            case .cost: return Fmt.moneyShort(e.cost)
            case .tokens: return Fmt.tokens(e.tokens)
            }
        }
        let pctW: [CGFloat] = entries.map { e in
            labelText(e).map { ($0 as NSString).size(withAttributes: [.font: font]).width + 2 } ?? 0
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
                let fill = display == .remaining ? 1 - used : used
                let fillColor: NSColor = colored ? severity(used) : label
                drawMeter(at: x, style: style, width: meterW, height: h, used: fill, known: e.used != nil,
                          fill: fillColor, empty: label.withAlphaComponent(0.22))
                x += meterW
                if let t = labelText(e) {
                    (t as NSString).draw(at: NSPoint(x: x + 2, y: (h - font.capHeight) / 2 - 3),
                                         withAttributes: [.font: font, .foregroundColor: colored && kind.isPercentage ? severity(used) : label])
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
            async let cu = LimitsFetcher.cursor()
            async let gr = LimitsFetcher.grok()
            async let gm = LimitsFetcher.gemini()
            for l in await [c, x, g, cu, gr, gm].compactMap({ $0 }) {
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
        if env["TALLY_ICON"] != nil {
            let r = ImageRenderer(content: AppIconView(size: 1024))
            r.scale = 1
            write(r.nsImage, to: path)
            return
        }
        // TALLY_STATES=1: the meter's forecast and freshness states with made-up numbers, for design checks.
        if env["TALLY_STATES"] != nil {
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                let r = ImageRenderer(content: MeterStates().environment(\.colorScheme, .dark))
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
        // TALLY_DEMO_DIR: render every state the promo video needs from one fetch (avoids rate limits).
        if let dir = env["TALLY_DEMO_DIR"] {
            PopoverView.hidePrivate = true
            let sc = CGFloat(Double(env["TALLY_SCALE"] ?? "") ?? 2)  // e.g. 6 for 4K video cuts
            for (name, per, tok) in [("p7", Period.week, false), ("p24", .day, false), ("p30", .month, false), ("p7t", .week, true)] {
                store.period = per; store.metric = tok ? .tokens : .cost
                NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                    let r = ImageRenderer(content: PopoverView(store: store, fixedHeight: true).environment(\.colorScheme, .dark))
                    r.scale = sc
                    write(r.nsImage, to: "\(dir)/\(name).png", scale: sc)
                }
            }
            store.period = .week; store.metric = .cost
            menubar(store, light: false, to: "\(dir)/mb.png")
            print("wrote \(dir)")
            return
        }
        if let p = env["TALLY_PERIOD"], let per = Period(rawValue: p) { store.period = per }
        if env["TALLY_TOKENS"] != nil { store.metric = .tokens }
        // TALLY_SHARE=1: render the share deck instead of the panel, as out-1.png … out-7.png.
        if env["TALLY_SHARE"] != nil {
            let stats = ShareStats(store: store)
            let base = (path as NSString).deletingPathExtension
            let count = ShareDeck.names(stats).count
            for i in 0..<count {
                if let img = ShareCardRenderer.image(stats, page: i) { write(img, to: "\(base)-\(i + 1).png", scale: ShareCardRenderer.scale(i, stats)) }
            }
            print("wrote \(base)-1…\(count).png")
            return
        }
        let light = env["TALLY_LIGHT"] != nil
        PopoverView.hidePrivate = env["TALLY_PRIVATE"] != nil
        let view = PopoverView(store: store, fixedHeight: true).environment(\.colorScheme, light ? .light : .dark)
        NSAppearance(named: light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: view)
            r.scale = 2
            write(r.nsImage, to: path, scale: 2)
            if let mb = env["TALLY_MENUBAR"] { menubar(store, light: light, to: mb) }
        }
        print("wrote \(path)")
    }

    private static func menubar(_ store: UsageStore, light: Bool, to mb: String) {
        let prefs = Prefs.shared
        var imgs: [NSImage] = []
        for (style, kind) in [(MenuBarStyle.columns, LabelKind.percent), (.columns, .cost), (.bars, .tokens)] {
            let entries = store.visibleServices(prefs).filter(\.hasLimits).map { s -> MenuBarRenderer.Entry in
                let t = store.labelTotals[.today]?[s]
                return MenuBarRenderer.Entry(service: s, used: store.limits[s]?.binding.map { $0.usedPercent / 100 },
                                             cost: t?.cost ?? 0, tokens: t?.tokens ?? 0)
            }
            imgs.append(MenuBarRenderer.image(entries: entries, style: style, percents: .always, label: kind, colored: true,
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

    private static func write(_ img: NSImage?, to path: String, scale: CGFloat = 1) {
        guard let img else { return }
        var rect = NSRect(origin: .zero, size: NSSize(width: img.size.width * scale, height: img.size.height * scale))
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}

private struct MeterStates: View {
    var body: some View {
        let now = Date()
        let session = LimitWindow(title: "Session", usedPercent: 62, resetsAt: now.addingTimeInterval(2.5 * 3600), windowSeconds: 5 * 3600)
        let weekly = LimitWindow(title: "Weekly", usedPercent: 58, resetsAt: now.addingTimeInterval(3 * 86_400), windowSeconds: 7 * 86_400)
        var hit = Forecast(runsOutIn: 50 * 60, beforeReset: true, ratePerHour: 45.6); hit.early = 100 * 60
        var wk = Forecast(runsOutIn: 1.7 * 86_400, beforeReset: true, ratePerHour: 1.0, average: true); wk.early = 1.3 * 86_400
        var stale = ServiceLimits(service: .claude, plan: "Claude Pro", windows: [weekly])
        stale.source = "live"; stale.checkedAt = now.addingTimeInterval(-25 * 60)
        stale.staleReason = "Claude Code's sign-in expired 12m ago. It renews the next time you use Claude Code."
        var logs = ServiceLimits(service: .codex, plan: "ChatGPT Plus", windows: [weekly])
        logs.source = "logs"; logs.checkedAt = now.addingTimeInterval(-47 * 60); logs.staleReason = "Couldn't reach ChatGPT."
        var live = ServiceLimits(service: .claude, windows: [weekly]); live.source = "live"; live.checkedAt = now.addingTimeInterval(-120)
        return VStack(alignment: .leading, spacing: 14) {
            LimitRow(window: session, color: Theme.severity(62), percentColor: Theme.severity(62), forecast: hit)
            LimitRow(window: weekly, color: Theme.severity(58), percentColor: Theme.severity(58), forecast: wk)
            Divider()
            ForEach([("Live", live), ("Check failed", stale), ("Codex fallback", logs)], id: \.0) { name, lim in
                let f = Freshness(lim)!
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(name).font(.system(size: 14, weight: .medium)); Spacer()
                        Text(f.label).font(.system(size: 10.5)).foregroundStyle(f.stale ? Theme.warn : Theme.faint) }
                    if let reason = lim.staleReason {
                        Text(lim.source == "logs" ? "\(reason) Showing an estimate from this Mac's logs, so other devices aren't counted."
                                                  : "\(reason) Showing the last good reading.")
                            .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    LimitRow(window: weekly, color: Theme.severity(58), percentColor: Theme.severity(58), forecast: nil).opacity(f.stale ? 0.55 : 1)
                }
            }
        }
        .padding(20).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
    }
}
