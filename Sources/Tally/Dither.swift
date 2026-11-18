import SwiftUI

/// Ordered (Bayer 4×4) dithering on a dot grid — the look of the reference disk app.
enum Bayer {
    static let m: [[Double]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ].map { $0.map { ($0 + 0.5) / 16 } }

    static func on(_ x: Int, _ y: Int, _ density: Double) -> Bool {
        density > m[y & 3][x & 3]
    }
}

/// Fills a rect with dithered dots. `density(u, v)` gets normalized coords (0…1).
struct DitherField: View {
    var color: Color
    var pitch: CGFloat = 4
    var dot: CGFloat = 2.4
    var offColor: Color? = nil
    var density: (Double, Double) -> Double

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / pitch), rows = Int(size.height / pitch)
            guard cols > 0, rows > 0 else { return }
            let ox = (size.width - CGFloat(cols) * pitch) / 2, oy = (size.height - CGFloat(rows) * pitch) / 2
            var on = Path(), off = Path()
            for y in 0..<rows {
                for x in 0..<cols {
                    let d = density((Double(x) + 0.5) / Double(cols), (Double(y) + 0.5) / Double(rows))
                    let r = CGRect(x: ox + CGFloat(x) * pitch + (pitch - dot) / 2,
                                   y: oy + CGFloat(y) * pitch + (pitch - dot) / 2, width: dot, height: dot)
                    if Bayer.on(x, y, d) { on.addRect(r) } else if offColor != nil { off.addRect(r) }
                }
            }
            if let offColor { ctx.fill(off, with: .color(offColor)) }
            ctx.fill(on, with: .color(color))
        }
    }
}

/// A horizontal stacked bar of dithered segments (the disk-usage bar).
struct DitherStackBar: View {
    struct Segment: Identifiable { let id: String; let color: Color; let fraction: Double }
    var segments: [Segment]
    var height: CGFloat = 46

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.025))
                DitherField(color: Theme.ink.opacity(0.07), pitch: 4, dot: 2) { _, _ in 1 }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                        let sw = max(3, w * s.fraction)
                        ZStack {
                            Rectangle().fill(s.color.opacity(0.13))
                            DitherField(color: s.color, pitch: 4, dot: 2.2) { u, v in
                                0.28 + 0.45 * v + 0.12 * sin(u * 9 + Double(i))
                            }
                        }
                        .frame(width: sw)
                        .overlay(Rectangle().stroke(s.color.opacity(0.75), lineWidth: 1))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ink.opacity(0.08), lineWidth: 1))
        }
        .frame(height: height)
    }
}

/// A limit meter: dithered fill for "used", faint grid for what's left, a tick at the expected pace.
struct DitherMeter: View {
    var color: Color
    var used: Double      // 0…1
    var pace: Double?     // 0…1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.03))
                DitherField(color: Theme.ink.opacity(0.06), pitch: 3, dot: 1.4) { u, v in
                    // diagonal hatching for the remaining part, like the reference's empty bars
                    (u * 40 + v * 4).truncatingRemainder(dividingBy: 2) < 0.7 ? 1 : 0
                }
                ZStack {
                    Rectangle().fill(color.opacity(0.16))
                    DitherField(color: color, pitch: 3, dot: 2) { u, _ in 0.35 + 0.55 * u }
                }
                .frame(width: max(0, w * min(1, used)))
                .overlay(alignment: .trailing) { Rectangle().fill(color).frame(width: used > 0 ? 1.5 : 0) }
                if let pace {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.ink)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: w * pace - 1)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.ink.opacity(0.07), lineWidth: 1))
        }
    }
}

/// Smooth area chart drawn as ordered-dither dots: dense near the baseline, a solid ridge on top.
struct DitherArea: View {
    var values: [Double]
    var color: Color

    var body: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 3, dot: CGFloat = 2
            let cols = Int(size.width / pitch), rows = Int(size.height / pitch)
            guard cols > 1, rows > 1, !values.isEmpty else { return }
            let maxV = max(values.max() ?? 0, 1e-9)
            // Catmull-Rom-ish smoothing via cosine interpolation between bucket centres.
            func sample(_ u: Double) -> Double {
                let x = u * Double(values.count) - 0.5
                let i = Int(floor(x)), t = x - floor(x)
                let a = values[max(0, min(values.count - 1, i))], b = values[max(0, min(values.count - 1, i + 1))]
                let w = (1 - cos(t * .pi)) / 2
                return (a * (1 - w) + b * w) / maxV
            }
            var base = Path(), fill = Path(), ridge = Path()
            for cx in 0..<cols {
                let h = sample((Double(cx) + 0.5) / Double(cols))
                let filled = h > 0.001 ? max(1, Int((h * Double(rows - 1)).rounded())) : 0
                let x = CGFloat(cx) * pitch
                base.addRect(CGRect(x: x, y: size.height - 1, width: dot, height: 1))
                for r in 0..<filled {
                    let y = size.height - pitch * CGFloat(r + 1)
                    let rect = CGRect(x: x, y: y, width: dot, height: dot)
                    if r == filled - 1 { ridge.addRect(rect); continue }
                    let density = 0.85 - 0.6 * Double(r) / Double(max(1, filled))
                    if Bayer.on(cx, r, density) { fill.addRect(rect) }
                }
            }
            ctx.fill(base, with: .color(Theme.ink.opacity(0.15)))
            ctx.fill(fill, with: .color(color.opacity(0.75)))
            ctx.fill(ridge, with: .color(color))
        }
    }
}

// MARK: - Squarified treemap

struct TreemapItem: Identifiable {
    let id: String
    let value: Double
}

enum Treemap {
    static func layout(_ items: [TreemapItem], in rect: CGRect) -> [String: CGRect] {
        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [:] }
        let scale = Double(rect.width * rect.height) / total
        var areas = items.sorted { $0.value > $1.value }.map { ($0.id, $0.value * scale) }
        var out: [String: CGRect] = [:]
        var r = rect

        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +)
            guard s > 0, let mx = row.max(), let mn = row.min() else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }

        while !areas.isEmpty {
            let side = Double(min(r.width, r.height))
            var row: [(String, Double)] = []
            while let next = areas.first {
                let cur = row.map(\.1)
                if row.isEmpty || worst(cur + [next.1], side) <= worst(cur, side) {
                    row.append(next); areas.removeFirst()
                } else { break }
            }
            let sum = row.reduce(0) { $0 + $1.1 }
            if r.width >= r.height {
                let w = CGFloat(sum / Double(r.height))
                var y = r.minY
                for (id, a) in row {
                    let h = CGFloat(a) / w
                    out[id] = CGRect(x: r.minX, y: y, width: w, height: h); y += h
                }
                r = CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height)
            } else {
                let h = CGFloat(sum / Double(r.width))
                var x = r.minX
                for (id, a) in row {
                    let w = CGFloat(a) / h
                    out[id] = CGRect(x: x, y: r.minY, width: w, height: h); x += w
                }
                r = CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h)
            }
        }
        return out
    }
}
