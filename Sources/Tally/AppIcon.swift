import SwiftUI

/// The app icon: three dithered limit meters (Claude orange, Codex white, OpenCode green) on a dark tile.
/// Rendered to PNG by `Tally --snapshot icon.png` with TALLY_ICON=1; build-app.sh turns it into AppIcon.icns.
struct AppIconView: View {
    var size: CGFloat = 1024

    var body: some View {
        let s = size
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x26262A), Color(hex: 0x141416)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: s * 0.006)
            HStack(alignment: .bottom, spacing: s * 0.07) {
                meter(Color(hex: 0xE2774F), 0.78)
                meter(Color(hex: 0xE8E8EA), 0.52)
                meter(Color(hex: 0x42C08D), 0.30)
            }
            .frame(height: s * 0.56)
            .offset(y: s * 0.02)
        }
        .frame(width: s * 0.82, height: s * 0.82)   // macOS icon grid: art inset inside the canvas
        .shadow(color: .black.opacity(0.35), radius: s * 0.02, y: s * 0.012)
        .frame(width: s, height: s)
    }

    private func meter(_ color: Color, _ fill: Double) -> some View {
        let w = size * 0.14
        return ZStack(alignment: .bottom) {
            // empty track
            DitherField(color: Color.white.opacity(0.13), pitch: size * 0.022, dot: size * 0.013) { _, _ in 1 }
            // used portion: dense at the bottom, thinning toward the top edge
            DitherField(color: color, pitch: size * 0.022, dot: size * 0.016) { _, v in
                let level = 1 - v   // 0 at top, 1 at bottom
                guard level <= fill else { return 0 }
                return 0.35 + 0.65 * min(1, (fill - level) / 0.18 + 0.2)
            }
        }
        .frame(width: w)
    }
}
