import AppKit
import SwiftUI

// A "Wrapped" deck: six 1080×1920 story slides and one 1200×630 card for X, built from the store's
// current period. Dithered with the same Bayer 4×4 method as the website's specimen. No project names.

// MARK: - Numbers

struct ShareStats {
    struct Row: Identifiable {
        let service: Service
        let plan: String
        let cost: Double
        let multiple: Double?
        var id: Service { service }

        var name: String {
            switch service {
            case .claude: return plan.hasPrefix("Claude") ? plan : "Claude \(plan)"
            case .openai: return "OpenAI API"
            default: return service.name
            }
        }
        var meta: String {
            var t = Fmt.money(cost)
            if service == .codex { t += " · \(plan)" }
            if let m = multiple { t += " · " + ShareStats.times(m) + (service == .codex ? "" : " value") }
            else if service == .openai { t += " · pay as you go" }
            return t
        }
    }

    struct Persona { let name: String; let line: String }

    let period: Period
    let apiValue: Double
    let planCost: Double
    let multiple: Double?
    let tokens: Int
    let sessions: Int
    let rows: [Row]
    let models: [String]
    let rhythm: Rhythm
    let end = Date()

    @MainActor init(store: UsageStore) {
        let prefs = Prefs.shared
        period = store.period
        let share = store.period.seconds / (30 * 86_400)
        var planCost = 0.0, covered = 0.0
        var rows: [Row] = []
        for (s, sum) in store.services where sum.cost > 0.005 {
            let lim = store.limits[s]
            let price = prefs.price(s, plan: lim?.plan)
            var x: Double?
            if price > 0 { planCost += price * share; covered += sum.cost; x = sum.cost / (price * share) }
            rows.append(Row(service: s, plan: lim?.plan ?? s.defaultPlan, cost: sum.cost, multiple: x))
        }
        self.rows = rows.sorted { $0.cost > $1.cost }
        apiValue = store.services.values.reduce(0) { $0 + $1.cost }
        self.planCost = planCost
        multiple = planCost > 0 ? covered / planCost : nil
        tokens = store.services.values.reduce(0) { $0 + $1.tokens }
        sessions = store.totals.sessions
        // The same model can come through two plans; rank by name.
        var byName: [String: Double] = [:]
        for m in store.models { byName[m.displayName, default: 0] += m.cost }
        models = byName.sorted { $0.value > $1.value }.prefix(4).map(\.key)
        rhythm = store.rhythm()
    }

    static func times(_ m: Double) -> String { String(format: m >= 10 ? "%.0f×" : "%.1f×", m) }
    var multipleText: String? { multiple.map(Self.times) }
    var money: String { apiValue >= 100 ? String(format: "$%.0f", apiValue) : Fmt.money(apiValue) }

    var span: String {
        switch period { case .day: return "24 hours"; case .week: return "seven days"; case .month: return "30 days" }
    }
    var unitWord: String {
        switch period { case .day: return "day"; case .week: return "week"; case .month: return "month" }
    }

    var dateRange: String {
        let cal = Calendar.current
        let days = period == .day ? 1 : (period == .week ? 7 : 30)
        let start = cal.date(byAdding: .day, value: -(days - 1), to: end)!
        let f = DateFormatter(); f.dateFormat = "MMM d"
        if days == 1 { return f.string(from: end) }
        let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
        let tail = DateFormatter(); tail.dateFormat = sameMonth ? "d" : "MMM d"
        return "\(f.string(from: start)) – \(tail.string(from: end))"
    }

    /// "1.10 billion" for the tokens slide.
    var tokenWords: String {
        let d = Double(tokens)
        if d >= 1e9 { return String(format: d >= 1e10 ? "%.1f billion" : "%.2f billion", d / 1e9) }
        if d >= 1e6 { return String(format: d >= 1e8 ? "%.0f million" : "%.1f million", d / 1e6) }
        return Fmt.tokens(tokens)
    }

    /// War and Peace is ~587k words, about 780k tokens.
    var warAndPeace: Double { Double(tokens) / 780_000 }

    static func hourName(_ h: Int) -> String {
        h == 0 ? "midnight" : h == 12 ? "noon" : "\(h % 12)\u{00A0}\(h < 12 ? "am" : "pm")"
    }

    var persona: Persona {
        let hrs = rhythm.hours, total = max(hrs.reduce(0, +), 1e-12)
        let share = { (r: Range<Int>) in r.reduce(0) { $0 + hrs[$1] } / total }
        let night = share(0..<5), morning = share(5..<12), evening = share(18..<24)
        let weekend = (rhythm.weekdays[0] + rhythm.weekdays[6]) / max(rhythm.weekdays.reduce(0, +), 1e-12)
        let peak = hrs.indices.max { hrs[$0] < hrs[$1] } ?? 12
        let name: String
        if period != .day && weekend >= 0.45 { name = "Weekender" }
        else if night >= 0.3 { name = "Night Owl" }
        else if (morning < 0.05 || peak >= 22 || peak < 5) && evening + night >= 0.3 { name = "Late Shift" }
        else if morning >= 0.4 { name = "Early Bird" }
        else { name = "Day Shift" }

        var s = morning < 0.005 ? "Not one prompt before noon. " : "\(Int((morning * 100).rounded()))% of it before noon. "
        s += "Peak at \(Self.hourName(peak))"
        s += night > 0.02 && peak != 0 ? ", still going past midnight. " : ". "
        if period != .day, let d = rhythm.peakBar {
            let f = DateFormatter(); f.dateFormat = "EEEE"
            s += "\(f.string(from: d)) was your biggest day."
        }
        return Persona(name: name, line: s.trimmingCharacters(in: .whitespaces))
    }

    var postText: String {
        var t = "My \(unitWord) in AI coding: \(money) at API prices"
        if let m = multipleText { t += " on \(Fmt.money(planCost)) of plans (\(m))" }
        t += ". \(Fmt.tokens(tokens)) tokens, and apparently I'm \(persona.name == "Weekender" ? "a Weekender" : "on the \(persona.name)")."
        return t + " Made with Tally, a free Mac menu bar app: https://github.com/PratikRai0101/tally"
    }
}

// MARK: - Dithering

/// Paints intensities into a low-res RGB mask (one channel per colour), then turns each cell into a
/// square dot when it beats the Bayer threshold. Coordinates are in card points, origin top-left.
struct DotLayer {
    var paths: [Path] = [Path(), Path(), Path()]
    var colors: [Color?]

    init(size: CGSize, cell: CGFloat, colors: [Color?], dot: CGFloat = 0.78, paint: (DotPainter) -> Void) {
        self.colors = colors
        let w = Int(ceil(size.width / cell)), h = Int(ceil(size.height / cell))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1 / cell, y: -1 / cell)
        ctx.setBlendMode(.lighten)
        paint(DotPainter(ctx: ctx))
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return }
        let z = cell * dot
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = data[i], g = data[i + 1], b = data[i + 2]
                let v = Double(max(r, g, b)) / 255
                guard v >= 0.04, Bayer.on(x, y, v) else { continue }
                let c = r >= g && r >= b ? 0 : (g >= b ? 1 : 2)
                paths[c].addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: z, height: z))
            }
        }
    }
}

struct DotPainter {
    let ctx: CGContext

    static func ch(_ i: Int, _ v: Double) -> CGColor {
        let q = CGFloat(max(0, min(1, v)))
        return CGColor(red: i == 0 ? q : 0, green: i == 1 ? q : 0, blue: i == 2 ? q : 0, alpha: 1)
    }

    /// A shaded ball: light at the top-left highlight, full at the rim.
    func sphere(_ i: Int, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ lvl: Double = 1) {
        let cols = [Self.ch(i, 0.34 * lvl), Self.ch(i, 0.7 * lvl), Self.ch(i, lvl), Self.ch(i, 0)] as CFArray
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 0.5, 0.86, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: x - r * 0.35, y: y - r * 0.4), startRadius: 0,
                               endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
    }

    func vGradient(_ i: Int, in rect: CGRect, top: Double, bottom: Double) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [Self.ch(i, top), Self.ch(i, bottom)] as CFArray, locations: [0, 1]) else { return }
        ctx.saveGState(); ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
    }

    /// Heavy text filled with a vertical ramp. Returns its width.
    @discardableResult
    func text(_ i: Int, _ s: String, size: CGFloat, x: CGFloat, baseline: CGFloat, maxWidth: CGFloat, top: Double = 0.6) -> CGFloat {
        var font = NSFont.systemFont(ofSize: size, weight: .heavy)
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .kern: -size * 0.03]))
        var w = CTLineGetTypographicBounds(line, nil, nil, nil)
        if w > maxWidth {
            let fit = size * maxWidth / w
            font = NSFont.systemFont(ofSize: fit, weight: .heavy)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .kern: -fit * 0.03]))
            w = CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        let cap = font.capHeight
        // Clip to the glyph outlines (text drawing modes don't clip reliably in a bitmap context).
        let outline = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (g, p) in zip(glyphs, pos) {
                if let gp = CTFontCreatePathForGlyph(runFont, g, nil) {
                    outline.addPath(gp, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x + p.x, ty: baseline - p.y))
                }
            }
        }
        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [Self.ch(i, top), Self.ch(i, 1)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: baseline - cap * 1.15), end: CGPoint(x: 0, y: baseline), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
        return w
    }

    /// The Tally mascot: an 11×11 squircle of balls with two tall eyes cut out.
    func mascot(cx: CGFloat, cy: CGFloat, size s: CGFloat, look: (CGFloat, CGFloat) = (0, 0), color: (Int) -> Int = { _ in 1 }) {
        let c = s / 11
        for y in 0..<11 {
            for x in 0..<11 {
                let u = (Double(x) - 5) / 5.4, v = (Double(y) - 5) / 5.4
                if pow(u, 4) + pow(v, 4) <= 1 { sphere(color(x), cx + CGFloat(x - 5) * c, cy + CGFloat(y - 5) * c, c * 0.47) }
            }
        }
        let k = s / 320
        ctx.saveGState(); ctx.setBlendMode(.normal); ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for ex in [116.0, 204.0] {
            let w = 40 * k, h = 98 * k
            let r = CGRect(x: cx + (CGFloat(ex) - 160) * k + look.0 * k * 16 - w / 2, y: cy - 4 * k + look.1 * k * 12 - h / 2, width: w, height: h)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)); ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

struct Dots: View {
    let layer: DotLayer
    var body: some View {
        Canvas { ctx, _ in
            for (p, c) in zip(layer.paths, layer.colors) { if let c { ctx.fill(p, with: .color(c)) } }
        }
    }
}

// MARK: - Look

private enum W {
    static let paper = Color(hex: 0xFBFBFA), ink = Color(hex: 0x0E0E0D), orange = Color(hex: 0xE5874C)
    static let green = Color(hex: 0x3FB987), grey = Color(hex: 0xA9A9A5), soft = Color(hex: 0xD9D9D5), dim = Color(hex: 0x3A3A37)
    static let story = CGSize(width: 1080, height: 1920), wide = CGSize(width: 1200, height: 630)

    static func tile(_ s: Service) -> Color {
        switch s {
        case .claude: return orange
        case .codex: return paper
        case .opencodeGo: return green
        default: return s.color
        }
    }
}

private extension View {
    func at(_ x: CGFloat, _ y: CGFloat) -> some View { offset(x: x, y: y) }
}

private func heavy(_ s: String, _ size: CGFloat) -> Text {
    Text(s).font(.system(size: size, weight: .heavy)).tracking(-size * 0.045)
}

/// Lines of the heavy display face, set tighter than SwiftUI's default leading allows.
private struct Display: View {
    let lines: [String]
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: -size * 0.2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in heavy(l, size).lineLimit(1).fixedSize() }
        }
    }
}

private func mono(_ s: String, _ size: CGFloat = 26) -> some View {
    Text(s).font(.system(size: size, weight: .regular, design: .monospaced)).tracking(size * 0.08).textCase(.uppercase)
}

private func serif(_ s: String, _ size: CGFloat) -> some View {
    Text(s).font(.system(size: size, weight: .regular, design: .serif)).tracking(-size * 0.01).lineSpacing(size * 0.06)
}

private func boxed(_ s: String, _ size: CGFloat, _ bg: Color, _ fg: Color) -> some View {
    heavy(s, size).foregroundStyle(fg).padding(.horizontal, size * 0.12).background(bg)
}

private func sticker(_ s: String, _ bg: Color, _ angle: Double) -> some View {
    heavy(s, 76).foregroundStyle(W.ink).lineLimit(1).fixedSize()
        .padding(EdgeInsets(top: 16, leading: 30, bottom: 22, trailing: 30)).background(bg).rotationEffect(.degrees(angle))
}

private struct Brand: View {
    var size: CGFloat = 56
    var body: some View {
        HStack(spacing: size * 0.32) {
            AppIconView(size: size * 1.22).frame(width: size, height: size)
            Text("Tally").font(.system(size: size * 0.6, weight: .semibold)).tracking(-size * 0.012)
        }
    }
}

// MARK: - Slides

enum ShareDeck {
    static let names = ["intro", "total", "plans", "tokens", "hours", "summary", "post"]
    static var count: Int { names.count }

    @MainActor @ViewBuilder
    static func page(_ i: Int, _ st: ShareStats) -> some View {
        switch i {
        case 0: Intro(st: st)
        case 1: Total(st: st)
        case 2: Plans(st: st)
        case 3: Tokens(st: st)
        case 4: Hours(st: st)
        case 5: Summary(st: st)
        default: Post(st: st)
        }
    }

    static func size(_ i: Int) -> CGSize { i == count - 1 ? W.wide : W.story }
}

private struct Intro: View {
    let st: ShareStats
    var body: some View {
        ZStack(alignment: .topLeading) {
            W.orange
            Dots(layer: DotLayer(size: W.story, cell: 6, colors: [nil, W.ink, nil]) { p in
                p.mascot(cx: 540, cy: 760, size: 820, look: (0, 0.5))
            })
            HStack { Brand(); Spacer(); mono(st.dateRange) }.frame(width: 920).at(80, 80)
            VStack(alignment: .leading, spacing: 40) {
                Display(lines: ["Your \(st.unitWord) in", "AI coding."], size: 176)
                serif("Let’s see where it all went.", 52)
            }
            .frame(width: 940, height: 1920 - 120, alignment: .bottomLeading).at(80, 0)
        }
        .foregroundStyle(W.ink)
    }
}

private struct Total: View {
    let st: ShareStats
    var body: some View {
        let r = st.rhythm
        let n = max(1, r.bars.count), gap: CGFloat = n > 10 ? 6 : 26, bw = (920 - gap * CGFloat(n - 1)) / CGFloat(n)
        let mx = max(r.bars.max() ?? 0, 1e-12)
        ZStack(alignment: .topLeading) {
            W.ink
            Dots(layer: DotLayer(size: W.story, cell: 5, colors: [W.orange, W.dim, nil]) { p in
                p.text(0, st.money, size: 360, x: 64, baseline: 690, maxWidth: 950, top: 0.55)
                for (i, v) in r.bars.enumerated() {
                    let h = v > 0 ? 24 + 300 * sqrt(v / mx) : 6
                    p.vGradient(0, in: CGRect(x: 80 + CGFloat(i) * (bw + gap), y: 1770 - h, width: bw, height: h), top: 0.5, bottom: 1)
                }
            })
            mono("Your agents ran up").foregroundStyle(W.grey).at(80, 200)
            Display(lines: ["of AI coding at", "API prices."], size: 104).foregroundStyle(W.paper).at(80, 750)
            if let m = st.multipleText {
                sticker("You paid \(Fmt.money(st.planCost)).", W.green, -4).at(70, 1070)
                sticker("That’s \(m) your money.", W.paper, 3).at(170, 1200)
            } else {
                sticker("\(Fmt.tokens(st.tokens)) tokens.", W.green, -4).at(70, 1070)
                sticker("\(st.sessions) sessions.", W.paper, 3).at(170, 1200)
            }
            ForEach(Array(r.barLabels.enumerated()), id: \.offset) { i, l in
                mono(l, 22).foregroundStyle(W.grey).fixedSize()
                    .frame(width: max(bw, 60)).at(80 + CGFloat(i) * (bw + gap) + bw / 2 - max(bw, 60) / 2, 1790)
            }
        }
    }
}

private struct Plans: View {
    let st: ShareStats
    var body: some View {
        let rows = Array(st.rows.prefix(4))
        ZStack(alignment: .topLeading) {
            W.green
            heavy("Your top plans", 150).at(80, 200)
            VStack(alignment: .leading, spacing: 56) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 36) {
                        heavy("\(i + 1)", 96).frame(width: 90, alignment: .leading)
                        ZStack {
                            W.ink
                            let n = [5, 4, 3, 2][i]
                            Dots(layer: DotLayer(size: CGSize(width: 190, height: 190), cell: 4, colors: [W.tile(r.service), nil, nil]) { p in
                                let pt = 190 / CGFloat(n)
                                for y in 0..<n { for x in 0..<n { p.sphere(0, pt * (CGFloat(x) + 0.5), pt * (CGFloat(y) + 0.5), pt * 0.47) } }
                            })
                        }
                        .frame(width: 190, height: 190)
                        VStack(alignment: .leading, spacing: 12) {
                            heavy(r.name, 62).lineLimit(1).minimumScaleFactor(0.6)
                            Text(r.meta).font(.system(size: 28, design: .monospaced)).opacity(0.75).lineLimit(1).minimumScaleFactor(0.6)
                        }
                    }
                }
            }
            .frame(width: 920, alignment: .leading).at(80, 560)
            serif(footnote, 62).frame(width: 920, height: 1920 - 110, alignment: .bottomLeading).at(80, 0)
        }
        .foregroundStyle(W.ink)
    }

    private var footnote: String {
        guard let top = st.rows.first, st.apiValue > 0 else { return "Nothing to see yet." }
        var t = "\(top.service.name) did \(Int((top.cost / st.apiValue * 100).rounded()))% of the work."
        if let m = st.models.first { t += " Your top model was \(m)." }
        return t
    }
}

private struct Tokens: View {
    let st: ShareStats
    var body: some View {
        let copies = st.warAndPeace
        let per = max(1, Int(ceil(copies / 1600)))
        let n = max(1, Int((copies / Double(per)).rounded()))
        let cols = n > 200 ? 44 : max(6, Int(ceil(sqrt(Double(n) * 1.3))))
        let pitch = min(120, 920 / CGFloat(cols))
        ZStack(alignment: .topLeading) {
            W.paper
            Dots(layer: DotLayer(size: W.story, cell: 3, colors: [W.orange, W.ink, nil]) { p in
                for i in 0..<n {
                    p.sphere(i == 0 ? 0 : 1, 80 + CGFloat(i % cols) * pitch + pitch / 2, 680 + CGFloat(i / cols) * pitch + pitch / 2, pitch * 0.42, 0.95)
                }
            })
            VStack(alignment: .leading, spacing: -150 * 0.2) {
                boxed(st.tokenWords, 150, W.orange, W.ink)
                heavy("tokens.", 150).padding(.leading, 0)
            }
            .at(80, 180)
            HStack(spacing: 12) {
                Rectangle().fill(W.orange).frame(width: 16, height: 16)
                mono(per == 1 ? "= one War and Peace" : "= \(per) copies of War and Peace", 22)
            }
            .foregroundStyle(Color(hex: 0x6B6B68)).frame(width: 920, alignment: .trailing).at(80, 620)
            serif(line(copies), 56).frame(width: 920, height: 1920 - 130, alignment: .bottomLeading).at(80, 0)
        }
        .foregroundStyle(W.ink)
    }

    private func line(_ c: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        let round = c >= 1000 ? (c / 100).rounded() * 100 : (c >= 100 ? (c / 10).rounded() * 10 : c.rounded())
        let amount = c < 1.5 ? "about one copy" : "about \(f.string(from: NSNumber(value: round)) ?? "")\u{00A0}copies"
        return "That’s \(amount) of War and Peace, read and written in \(st.span)."
    }
}

private struct Hours: View {
    let st: ShareStats
    var body: some View {
        let hrs = st.rhythm.hours, mx = max(hrs.max() ?? 0, 1e-12), cx: CGFloat = 540, cy: CGFloat = 780
        let p = st.persona, words = p.name.split(separator: " ").map(String.init)
        ZStack(alignment: .topLeading) {
            W.ink
            Dots(layer: DotLayer(size: W.story, cell: 5, colors: [W.orange, W.dim, nil]) { pt in
                for h in 0..<24 {
                    let v = hrs[h], a = Double(h) / 24 * 2 * .pi - .pi / 2
                    let len = v > 0 ? 50 + 270 * sqrt(v / mx) : 14
                    var s = 0.0
                    while s < len {
                        let rr = 100 + s + 13
                        pt.sphere(v > 0 ? 0 : 1, cx + cos(a) * rr, cy + sin(a) * rr, 11.5, v > 0 ? 0.55 + 0.45 * s / len : 0.8)
                        s += 26
                    }
                }
                pt.mascot(cx: cx, cy: cy, size: 170, look: (0.6, -0.3))
            })
            mono("Your coding hours").foregroundStyle(W.grey).at(80, 150)
            ForEach([("Midnight", 0), ("6 am", 6), ("Noon", 12), ("6 pm", 18)], id: \.1) { t, h in
                let a = Double(h) / 24 * 2 * .pi - .pi / 2, r: CGFloat = h % 12 == 0 ? 450 : 420
                mono(t, 22).foregroundStyle(W.grey).fixedSize().position(x: cx + cos(a) * r, y: cy + sin(a) * r)
            }
            .frame(width: 1080, height: 1920)
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: -168 * 0.2) {
                    if words.count > 1 {
                        HStack(spacing: 30) { heavy("The", 168).foregroundStyle(W.paper); boxed(words[0], 168, W.orange, W.ink) }
                        boxed(words.dropFirst().joined(separator: " "), 168, W.orange, W.ink)
                    } else {
                        heavy("The", 168).foregroundStyle(W.paper)
                        boxed(p.name, 168, W.orange, W.ink)
                    }
                }
                serif(p.line, 52).foregroundStyle(W.soft).frame(width: 910, alignment: .leading)
            }
            .frame(width: 920, height: 1920 - 110, alignment: .bottomLeading).at(80, 0)
        }
    }
}

private struct RankList: View {
    let title: String
    let items: [String]
    var size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.4) {
            mono(title, size * 0.6).opacity(0.7)
            VStack(alignment: .leading, spacing: size * 0.38) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 0) {
                        Text("\(i + 1)").opacity(0.55).frame(width: size * 1.15, alignment: .leading)
                        Text(s).lineLimit(1).minimumScaleFactor(0.55)
                    }
                    .font(.system(size: size, weight: .bold)).tracking(-size * 0.025)
                }
            }
        }
    }
}

private struct Stat: View {
    let k: String, v: String
    var size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.18) {
            mono(k, size * 0.27).opacity(0.7)
            heavy(v, size).lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}

private struct Art: View {
    let size: CGSize
    let cell: CGFloat
    var body: some View {
        ZStack {
            W.ink
            Dots(layer: DotLayer(size: size, cell: cell, colors: [W.orange, W.paper, W.green]) { p in
                p.mascot(cx: size.width / 2, cy: size.height * 0.52, size: min(size.width, size.height) * 0.8, look: (0.3, 0.1)) { x in
                    x <= 3 ? 0 : (x <= 6 ? 1 : 2)
                }
            })
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct Summary: View {
    let st: ShareStats
    var body: some View {
        ZStack(alignment: .topLeading) {
            W.orange
            Art(size: CGSize(width: 920, height: 740), cell: 5).at(80, 180)
            HStack(alignment: .top, spacing: 40) {
                RankList(title: "Top plans", items: st.rows.prefix(4).map(\.name), size: 40).frame(width: 440, alignment: .leading)
                RankList(title: "Top models", items: st.models, size: 40).frame(width: 440, alignment: .leading)
            }
            .at(80, 990)
            Grid(alignment: .leading, horizontalSpacing: 40, verticalSpacing: 40) {
                GridRow {
                    Stat(k: "At API prices", v: st.money, size: 88).frame(width: 440, alignment: .leading)
                    Stat(k: "Value", v: st.multipleText ?? "—", size: 88).frame(width: 440, alignment: .leading)
                }
                GridRow {
                    Stat(k: "Tokens", v: Fmt.tokens(st.tokens), size: 88)
                    Stat(k: "Shift", v: st.persona.name.components(separatedBy: " ").first ?? "", size: 88)
                }
            }
            .at(80, 1360)
            HStack { Brand(); Spacer(); mono("\(st.dateRange) · tally-site.vercel.app", 24) }
                .frame(width: 920).frame(height: 1920 - 80, alignment: .bottom).at(80, 0)
        }
        .foregroundStyle(W.ink)
    }
}

private struct Post: View {
    let st: ShareStats
    var body: some View {
        ZStack(alignment: .topLeading) {
            W.orange
            Art(size: CGSize(width: 550, height: 550), cell: 4).at(40, 40)
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 24) {
                    Stat(k: "At API prices", v: st.money, size: 70).frame(width: 242, alignment: .leading)
                    Stat(k: "Value", v: st.multipleText ?? Fmt.tokens(st.tokens), size: 70).frame(width: 242, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 24) {
                    RankList(title: "Top plans", items: st.rows.prefix(4).map(\.name), size: 22).frame(width: 242, alignment: .leading)
                    RankList(title: "Top models", items: st.models, size: 22).frame(width: 242, alignment: .leading)
                }
            }
            .at(640, 52)
            HStack { Brand(size: 34); Spacer(); mono("\(st.dateRange) · The \(st.persona.name)", 15) }
                .frame(width: 508).frame(height: 630 - 44, alignment: .bottom).at(640, 0)
        }
        .foregroundStyle(W.ink)
    }
}

// MARK: - Rendering

enum ShareCardRenderer {
    /// Stories render at 1080×1920 px; the post card at 2× (2400×1260 px).
    static func scale(_ page: Int) -> CGFloat { page == ShareDeck.count - 1 ? 2 : 1 }

    @MainActor static func image(_ stats: ShareStats, page: Int) -> NSImage? {
        var out: NSImage?
        let sz = ShareDeck.size(page)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: ShareDeck.page(page, stats).frame(width: sz.width, height: sz.height).clipped()
                .environment(\.colorScheme, .dark))
            r.scale = scale(page)
            out = r.nsImage
        }
        return out
    }

    static func png(_ img: NSImage, scale: CGFloat) -> Data? {
        var rect = NSRect(origin: .zero, size: NSSize(width: img.size.width * scale, height: img.size.height * scale))
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

// MARK: - Share window

@MainActor
final class ShareWindow {
    static let shared = ShareWindow()
    private var window: NSWindow?

    func show(store: UsageStore) {
        if window == nil {
            let host = NSHostingController(rootView: ShareView(store: store))
            let w = NSWindow(contentViewController: host)
            w.title = "Your Tally Wrapped"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ShareView: View {
    @ObservedObject var store: UsageStore
    @State private var page = 0
    @State private var status = ""
    @State private var anchor: NSView?

    private let stage = CGSize(width: 640, height: 640)

    var body: some View {
        let stats = ShareStats(store: store)
        let sz = ShareDeck.size(page)
        let k = min(stage.width / sz.width, stage.height / sz.height)
        VStack(spacing: 14) {
            ZStack {
                ShareDeck.page(page, stats)
                    .frame(width: sz.width, height: sz.height).clipped()
                    .scaleEffect(k)
                    .frame(width: sz.width * k, height: sz.height * k)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
                    .id(page)
                HStack {
                    arrow("chevron.left", -1, .leftArrow)
                    Spacer()
                    arrow("chevron.right", 1, .rightArrow)
                }
            }
            .frame(width: stage.width + 80, height: stage.height)
            HStack(spacing: 7) {
                ForEach(0..<ShareDeck.count, id: \.self) { i in
                    Capsule().fill(i == page ? Color.white : Color.white.opacity(0.22))
                        .frame(width: i == ShareDeck.count - 1 ? 18 : 7, height: 7)
                        .onTapGesture { page = i }
                }
            }
            HStack(spacing: 10) {
                Segmented(options: Period.allCases, selection: $store.period) { $0.rawValue }
                Text(page == ShareDeck.count - 1 ? "Post · 1200×630" : "Story \(page + 1) of 6 · 1080×1920")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim)
                Spacer()
                Text("No project names are included.").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 10) {
                Button("Copy Image") { copy(stats) }
                Button("Save All…") { saveAll(stats) }
                Button("Share…") { share(stats) }.background(AnchorView(view: $anchor))
                Spacer()
                Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.good)
                Button("Copy & Post on X") { postOnX(stats) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 34)
        .frame(width: stage.width + 124)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
    }

    private func arrow(_ symbol: String, _ step: Int, _ key: KeyEquivalent) -> some View {
        Button { page = (page + step + ShareDeck.count) % ShareDeck.count; status = "" } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain).keyboardShortcut(key, modifiers: [])
    }

    private func copy(_ stats: ShareStats) {
        guard let img = ShareCardRenderer.image(stats, page: page) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        status = "Copied"
    }

    private func saveAll(_ stats: ShareStats) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for i in 0..<ShareDeck.count {
            guard let img = ShareCardRenderer.image(stats, page: i),
                  let data = ShareCardRenderer.png(img, scale: ShareCardRenderer.scale(i)) else { continue }
            let name = i == ShareDeck.count - 1 ? "tally-\(stats.period.rawValue)-post.png" : "tally-\(stats.period.rawValue)-\(i + 1)-\(ShareDeck.names[i]).png"
            try? data.write(to: dir.appendingPathComponent(name))
        }
        status = "Saved \(ShareDeck.count) images"
    }

    private func share(_ stats: ShareStats) {
        guard let img = ShareCardRenderer.image(stats, page: page), let anchor else { return }
        NSSharingServicePicker(items: [img, stats.postText]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// X's web intent can't attach images, so the card goes on the clipboard to paste into the post.
    private func postOnX(_ stats: ShareStats) {
        copy(stats)
        var c = URLComponents(string: "https://x.com/intent/post")!
        c.queryItems = [URLQueryItem(name: "text", value: stats.postText)]
        if let url = c.url { NSWorkspace.shared.open(url) }
        status = "Image copied: paste it into the post"
    }
}

/// Hands SwiftUI's backing NSView to AppKit APIs that need an anchor (the share picker).
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
