import AppKit
import SwiftUI

// MARK: - Numbers on the card

/// Everything the share card shows, taken from the store for its current period. No project names.
struct ShareStats {
    struct Row: Identifiable {
        let service: Service
        let plan: String
        let cost: Double
        let multiple: Double?
        var id: Service { service }
    }

    let period: Period
    let apiValue: Double
    let planCost: Double
    let multiple: Double?
    let tokens: Int
    let sessions: Int
    let rows: [Row]
    let series: [Double]
    let tint: Color

    @MainActor init(store: UsageStore) {
        let prefs = Prefs.shared
        period = store.period
        let share = store.period.seconds / (30 * 86_400)
        var planCost = 0.0, coveredValue = 0.0
        var rows: [Row] = []
        for (s, sum) in store.services where sum.cost > 0.005 {
            let lim = store.limits[s]
            let price = prefs.price(s, plan: lim?.plan)
            var x: Double?
            if price > 0 {
                let cost = price * share
                planCost += cost; coveredValue += sum.cost
                x = sum.cost / cost
            }
            rows.append(Row(service: s, plan: lim?.plan ?? s.defaultPlan, cost: sum.cost, multiple: x))
        }
        self.rows = rows.sorted { $0.cost > $1.cost }
        apiValue = store.services.values.reduce(0) { $0 + $1.cost }
        self.planCost = planCost
        multiple = planCost > 0 ? coveredValue / planCost : nil
        tokens = store.services.values.reduce(0) { $0 + $1.tokens }
        sessions = store.totals.sessions
        // Spend over time, summed across plans, for the dithered chart.
        let n = store.buckets.values.map(\.count).max() ?? 0
        var series = Array(repeating: 0.0, count: n)
        for list in store.buckets.values { for (i, b) in list.enumerated() where i < n { series[i] += b.cost } }
        self.series = series
        tint = self.rows.first?.service.color ?? Theme.good
    }

    var periodPhrase: String {
        switch period {
        case .day: return "the last 24 hours"
        case .week: return "the last 7 days"
        case .month: return "the last 30 days"
        }
    }

    var multipleText: String? { multiple.map { String(format: $0 >= 10 ? "%.0f×" : "%.1f×", $0) } }

    /// Text for a post that goes with the image.
    var postText: String {
        var t = "\(Fmt.money(apiValue)) of AI coding at API prices in \(periodPhrase)"
        if let m = multipleText { t += ", on \(Fmt.money(planCost)) worth of plans (\(m))" }
        return t + ". Tracking it with Tally, a free menu bar app for Mac: https://github.com/PratikRai0101/tally"
    }
}

// MARK: - The card (1200 × 630, the size X, LinkedIn and Slack previews expect)

struct ShareCardView: View {
    let stats: ShareStats
    static let size = CGSize(width: 1200, height: 630)

    private let bg = Color(hex: 0x19191B)
    private let text = Color(hex: 0xEDEDEF)
    private let dim = Color(hex: 0x8D8D93)
    private let faint = Color(hex: 0x5A5A60)
    private let line = Color(hex: 0x2E2E32)

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: 620)
            Rectangle().fill(line).frame(width: 1)
            right.frame(maxWidth: .infinity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(bg)
        .foregroundStyle(text)
        .environment(\.colorScheme, .dark)
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MY AI CODING · \(stats.periodPhrase.uppercased())")
                .font(.system(size: 15, weight: .medium, design: .monospaced)).tracking(1.2)
                .foregroundStyle(dim)
            Text(bigMoney(stats.apiValue))
                .font(.system(size: 132, weight: .regular)).monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(1)
                .padding(.top, 18)
            Text("at API prices").font(.system(size: 24)).foregroundStyle(dim)
            Spacer(minLength: 20)
            DitherArea(values: stats.series.isEmpty ? [0] : stats.series, color: stats.tint)
                .frame(height: 118)
            Spacer(minLength: 28)
            HStack(spacing: 12) {
                AppIconView(size: 40).frame(width: 40, height: 40)
                Text("Tally").font(.system(size: 22, weight: .medium))
                Text("every AI plan at a glance").font(.system(size: 15)).foregroundStyle(faint)
            }
        }
        .padding(.horizontal, 56).padding(.top, 52).padding(.bottom, 44)
    }

    private var right: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let m = stats.multipleText {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(m).font(.system(size: 68, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(stats.multiple ?? 0 >= 1 ? Theme.good : Theme.warn)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("what my plans cost").font(.system(size: 19))
                        Text("\(Fmt.money(stats.planCost)) for the same stretch").font(.system(size: 15)).foregroundStyle(dim)
                    }
                }
                Rectangle().fill(line).frame(height: 1).padding(.top, 26).padding(.bottom, 8)
            }
            let top = Array(stats.rows.prefix(stats.multiple == nil ? 5 : 4))
            let maxCost = max(top.first?.cost ?? 1, 1e-9)
            ForEach(top) { r in
                VStack(spacing: 9) {
                    HStack(spacing: 12) {
                        ServiceMark(service: r.service, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.service.name).font(.system(size: 17, weight: .medium))
                            Text(r.multiple.map { "\(r.plan) · " + String(format: $0 >= 10 ? "%.0f× value" : "%.1f× value", $0) } ?? r.plan)
                                .font(.system(size: 13)).foregroundStyle(dim)
                        }
                        Spacer()
                        Text(Fmt.money(r.cost)).font(.system(size: 18, design: .monospaced))
                    }
                    let f = max(0.015, r.cost / maxCost)
                    DitherField(color: r.service.color, pitch: 3, dot: 2.2, offColor: Color.white.opacity(0.07)) { u, _ in
                        u <= f ? 0.55 + 0.45 * (u / f) : 0
                    }
                    .frame(height: 12)
                }
                .padding(.vertical, 12)
            }
            Spacer(minLength: 0)
            HStack {
                Text("\(Fmt.tokens(stats.tokens)) tokens · \(stats.sessions) sessions")
                Spacer()
                Text("tally-site.vercel.app")
            }
            .font(.system(size: 14, design: .monospaced)).foregroundStyle(faint)
        }
        .padding(.horizontal, 48).padding(.top, 48).padding(.bottom, 46)
    }

    private func bigMoney(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : Fmt.money(v)
    }
}

// MARK: - Rendering

enum ShareCardRenderer {
    /// The card as a 2× bitmap (2400 × 1260 px).
    @MainActor static func image(_ stats: ShareStats) -> NSImage? {
        var out: NSImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: ShareCardView(stats: stats))
            r.scale = 2
            out = r.nsImage
        }
        return out
    }

    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
            w.title = "Share your usage"
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
    @State private var status = ""
    @State private var anchor: NSView?

    private let scale: CGFloat = 0.55

    var body: some View {
        let stats = ShareStats(store: store)
        VStack(alignment: .leading, spacing: 16) {
            ShareCardView(stats: stats)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: ShareCardView.size.width * scale, height: ShareCardView.size.height * scale, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
            HStack(spacing: 10) {
                Segmented(options: Period.allCases, selection: $store.period) { $0.rawValue }
                Text("No project names are included.").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
            }
            HStack(spacing: 10) {
                Button("Copy Image") { copy(stats) }
                Button("Save…") { save(stats) }
                Button("Share…") { share(stats) }
                    .background(AnchorView(view: $anchor))
                Spacer()
                Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.good)
                Button("Copy & Post on X") { postOnX(stats) }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22).padding(.bottom, 22).padding(.top, 34)
        .frame(width: ShareCardView.size.width * scale + 44)
        .background(Theme.bg)
        .environment(\.colorScheme, .dark)
    }

    private func copy(_ stats: ShareStats) {
        guard let img = ShareCardRenderer.image(stats) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        status = "Copied"
    }

    private func save(_ stats: ShareStats) {
        guard let img = ShareCardRenderer.image(stats), let data = ShareCardRenderer.png(img) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "tally-\(stats.period.rawValue).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
            status = "Saved"
        }
    }

    private func share(_ stats: ShareStats) {
        guard let img = ShareCardRenderer.image(stats), let anchor else { return }
        let picker = NSSharingServicePicker(items: [img, stats.postText])
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
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
