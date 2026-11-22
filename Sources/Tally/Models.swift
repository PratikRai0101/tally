import AppKit
import SwiftUI

/// The app that made the request (where the logs come from).
enum Tool: String, CaseIterable, Identifiable, Hashable {
    case claudeCode, codex, pi, opencode, grok
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .pi: return "Pi"
        case .opencode: return "OpenCode"
        case .grok: return "Grok CLI"
        }
    }

    var logo: Logo {
        switch self {
        case .claudeCode: return .clawdMono
        case .codex: return .codex
        case .pi: return .pi
        case .opencode: return .opencode
        case .grok: return .grok
        }
    }
}

/// The subscription / account that paid for it. Cards, limits and the menu bar are per service.
enum Service: String, CaseIterable, Identifiable, Hashable {
    case claude, codex, cursor, grok, opencodeGo, opencodeZen, openai, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .opencodeGo: return "OpenCode Go"
        case .opencodeZen: return "OpenCode Zen"
        case .openai: return "OpenAI"
        case .other: return "Other"
        }
    }

    var defaultPlan: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .opencodeGo: return "Go subscription"
        case .opencodeZen: return "Free models"
        case .openai: return "API"
        case .other: return "Misc providers"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "circle.hexagongrid"
        case .cursor: return "cursorarrow"
        case .grok: return "sparkle"
        case .opencodeGo: return "bolt.square"
        case .opencodeZen: return "square.dashed"
        case .openai: return "circle.grid.cross"
        case .other: return "ellipsis.circle"
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Full-colour logo for cards (nil → use the tinted mono logo or symbol).
    var colorLogo: Logo? {
        switch self {
        case .claude: return .clawd
        case .codex: return .codexColor
        default: return nil
        }
    }

    /// Single-colour logo for the menu bar and small places.
    var monoLogo: Logo? {
        switch self {
        case .claude: return .clawdMono
        case .codex: return .codex
        case .cursor: return .cursor
        case .grok: return .grok
        case .opencodeGo, .opencodeZen: return .opencode
        case .openai: return .openai
        case .other: return nil
        }
    }

    var nsColor: NSColor {
        switch self {
        case .claude: return NSColor(hex: 0xE2774F)
        case .codex: return .dynamic(light: NSColor(hex: 0x3A3A40), dark: NSColor(hex: 0xE8E8EA))
        case .cursor: return NSColor(hex: 0x2BB5C9)
        case .grok: return NSColor(hex: 0xE5566F)
        case .opencodeGo: return NSColor(hex: 0x42C08D)
        case .opencodeZen: return NSColor(hex: 0x4E95F5)
        case .openai: return NSColor(hex: 0x9B7BEA)
        case .other: return NSColor(hex: 0xD9B44A)
        }
    }

    var hasLimits: Bool { self == .claude || self == .codex || self == .opencodeGo || self == .cursor || self == .grok }

    /// Shown even with no usage on this Mac (their limits are the point). Cursor and Grok appear once
    /// they have usage or a live reading, so people who don't use them don't get an empty card.
    var showsWithoutUsage: Bool { self == .claude || self == .codex || self == .opencodeGo }

    /// Maps a provider id from Pi / OpenCode logs onto a service.
    static func from(provider: String?) -> Service {
        switch provider?.lowercased() ?? "" {
        case "anthropic", "claude": return .claude
        case "openai-codex", "codex", "chatgpt": return .codex
        case "xai", "grok": return .grok
        case "cursor": return .cursor
        case "opencode-go": return .opencodeGo
        case "opencode", "opencode-zen": return .opencodeZen
        case "openai": return .openai
        default: return .other
        }
    }
}

struct UsageRecord {
    let date: Date
    let tool: Tool
    let service: Service
    let model: String
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let cost: Double
    let session: String
    var dedupKey: String? = nil
    var cwd: String = ""

    var tokens: Int { input + cacheRead + cacheWrite + output }
}

/// A time a plan refused requests because a limit was used up, read from the agents' logs.
struct Lockout {
    let date: Date
    let service: Service
    var kind: String          // five_hour, seven_day, … or "limit" when the log doesn't say
    var resetAt: Date?
}

/// A limit reading below 100% (Codex logs these as you go), for "closest call".
struct NearMiss {
    let date: Date
    let service: Service
    let kind: String
    let percent: Double
}

struct LimitWindow: Identifiable {
    let id = UUID()
    let title: String
    let usedPercent: Double      // 0...100
    let resetsAt: Date?
    let windowSeconds: Double?

    var leftPercent: Double { max(0, 100 - usedPercent) }

    /// Fraction of the window that has elapsed (where "on pace" usage would be).
    var pace: Double? {
        guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSinceNow / windowSeconds))
    }
}

struct ServiceLimits {
    let service: Service
    var plan: String?
    var windows: [LimitWindow]
    var notes: [(String, String)] = []   // label, value
    var error: String?
    var source: String?
    /// When these numbers were read (the request time for live data, the log line's time for log estimates).
    var checkedAt: Date?
    /// Set when the latest check failed and these are the last good numbers; says why.
    var staleReason: String?

    /// The window closest to running out.
    var binding: LimitWindow? { windows.max { $0.usedPercent < $1.usedPercent } }
}

enum Period: String, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
    var seconds: TimeInterval {
        switch self {
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

enum Metric: String, CaseIterable, Identifiable {
    case cost = "Cost", tokens = "Tokens"
    var id: String { rawValue }
}

// MARK: - Formatting

enum Fmt {
    static func money(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v < 0.01 { return "<$0.01" }
        if v >= 1000 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    static func moneyShort(_ v: Double) -> String {
        if v < 0.01 { return "$0" }
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 10 { return String(format: "$%.1f", v) }
        return String(format: "$%.2f", v)
    }

    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch d {
        case 1e9...: return trim(d / 1e9) + "B"
        case 1e6...: return trim(d / 1e6) + "M"
        case 1e3...: return trim(d / 1e3) + "K"
        default: return "\(n)"
        }
    }

    private static func trim(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : (v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
    }

    static func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        var s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        let d = s / 86_400; s %= 86_400
        let h = s / 3600; s %= 3600
        let m = max(1, s / 60)
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(-date.timeIntervalSinceNow)
        if s < 10 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 2 * 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
}

// MARK: - Colors

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Light/dark aware palette (the popover follows the Appearance setting).
enum Theme {
    private static func dyn(_ l: UInt32, _ d: UInt32, _ a: CGFloat = 1) -> Color {
        Color(nsColor: .dynamic(light: NSColor(hex: l, alpha: a), dark: NSColor(hex: d, alpha: a)))
    }
    static let bg = dyn(0xF6F5F2, 0x19191B)
    static let card = dyn(0xFFFFFF, 0x1F1F22)
    static let line = dyn(0xE3E1DC, 0x2E2E32)
    static let text = dyn(0x1C1C1E, 0xEDEDEF)
    static let dim = dyn(0x6E6E73, 0x8D8D93)
    static let faint = dyn(0xA1A1A6, 0x5A5A60)
    /// Neutral ink for empty grids / hatching.
    static let ink = Color(nsColor: .dynamic(light: .black, dark: .white))
    /// Settings sidebar and raised segmented-control thumb.
    static let sidebar = dyn(0xEFEDE8, 0x151517)
    static let raised = dyn(0xFFFFFF, 0x3A3A3F)
    /// Tally orange (site and Wrapped).
    static let accent = Color(hex: 0xE5874C)

    static let good = Color(hex: 0x42C08D)
    static let warn = Color(hex: 0xE5B23C)
    static let bad = Color(hex: 0xE5484D)

    static func severity(_ used: Double) -> Color {
        used >= 90 ? bad : (used >= 70 ? warn : good)
    }
}
