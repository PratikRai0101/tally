import Foundation

/// One subscription you can pick in Settings → Plans. Prices are US list prices per month, billed monthly
/// (checked on the providers' pricing pages, November 2026). Seat plans are per person.
struct PlanOption: Identifiable, Hashable {
    let id: String
    let name: String
    let price: Double
    var perSeat = false
    var legacy = false
    var note: String? = nil

    var priceLabel: String {
        let p = price == 0 ? "Free" : (price.rounded() == price ? String(format: "$%.0f", price) : Fmt.money(price))
        return price == 0 ? p : p + (perSeat ? "/seat" : "/mo")
    }
}

enum PlanCatalog {
    /// The plans each service sells. Empty for pay-as-you-go services (API keys, free models).
    static func options(_ s: Service) -> [PlanOption] {
        switch s {
        case .claude:
            return [
                .init(id: "free", name: "Free", price: 0),
                .init(id: "pro", name: "Pro", price: 20),
                .init(id: "max", name: "Max", price: 100, note: "Formerly Max 5×"),
                .init(id: "ultra", name: "Ultra", price: 200, note: "Formerly Max 20×"),
                .init(id: "team", name: "Team Standard", price: 25, perSeat: true),
                .init(id: "team-premium", name: "Team Premium", price: 125, perSeat: true),
            ]
        case .codex:
            return [
                .init(id: "free", name: "Free", price: 0),
                .init(id: "go", name: "Go", price: 8, note: "Priced by region"),
                .init(id: "plus", name: "Plus", price: 20),
                .init(id: "pro100", name: "Pro", price: 100),
                .init(id: "pro200", name: "Pro", price: 200, note: "Higher Codex limits"),
                .init(id: "business", name: "Business", price: 25, perSeat: true),
            ]
        case .cursor, .grok:
            // Since Oct 12, 2026 Cursor and Grok are sold as one X Subscription with a shared usage pool.
            let other = s == .cursor ? "Grok" : "Cursor"
            var list: [PlanOption] = [
                .init(id: "free", name: "Free", price: 0),
                .init(id: "plus", name: "Plus", price: 8),
                .init(id: "premium", name: "Premium", price: 30),
                .init(id: "super", name: "Super", price: 100),
                .init(id: "ultra", name: "Ultra", price: 200),
            ]
            if s == .cursor { list.append(.init(id: "teams", name: "Teams", price: 30, perSeat: true)) }
            list.append(.init(id: "shared", name: "Paid on \(other)", price: 0,
                              note: "Same X Subscription, so it isn't counted twice"))
            if s == .cursor {
                list += [
                    .init(id: "hobby", name: "Hobby", price: 0, legacy: true),
                    .init(id: "pro", name: "Pro", price: 20, legacy: true),
                    .init(id: "pro-plus", name: "Pro+", price: 60, legacy: true),
                    .init(id: "ultra-legacy", name: "Ultra", price: 200, legacy: true),
                    .init(id: "teams-legacy", name: "Teams", price: 40, perSeat: true, legacy: true),
                ]
            } else {
                list += [
                    .init(id: "supergrok", name: "SuperGrok", price: 30, legacy: true),
                    .init(id: "heavy", name: "SuperGrok Heavy", price: 300, legacy: true),
                    .init(id: "x-premium-plus", name: "X Premium+", price: 40, legacy: true),
                ]
            }
            return list
        case .opencodeGo:
            return [
                .init(id: "go", name: "Go", price: 10),
                .init(id: "go-plus", name: "Go Plus", price: 40),
                .init(id: "go-teams", name: "Go Teams", price: 20, perSeat: true),
            ]
        case .opencodeZen, .openai, .other:
            return []
        }
    }

    static func option(_ s: Service, id: String) -> PlanOption? { options(s).first { $0.id == id } }

    /// Matches the plan name a provider reports ("Claude Max", "ChatGPT Plus", "SuperGrok", "Cursor Pro+") to the catalog.
    static func detect(_ s: Service, plan: String?) -> PlanOption? {
        let p = (plan ?? "").lowercased()
        func has(_ k: String) -> Bool { p.contains(k) }
        let id: String?
        switch s {
        case .claude:
            id = has("ultra") || has("20x") ? "ultra" : has("max") ? "max" : has("premium") ? "team-premium"
                : has("team") ? "team" : has("pro") ? "pro" : has("free") ? "free" : nil
        case .codex:
            id = has("business") || has("team") ? "business" : has("pro") ? "pro200" : has("plus") ? "plus"
                : has(" go") || p.hasSuffix("go") ? "go" : has("free") ? "free" : nil
        case .cursor:
            id = has("pro+") || has("pro plus") ? "pro-plus" : has("hobby") ? "hobby" : has("pro") ? "pro"
                : has("premium") ? "premium" : has("super") ? "super" : has("ultra") ? "ultra" : has("plus") ? "plus"
                : has("team") ? "teams" : has("free") ? "free" : nil
        case .grok:
            id = has("heavy") ? "heavy" : has("supergrok") ? "supergrok" : has("premium+") ? "x-premium-plus"
                : has("ultra") ? "ultra" : has("super") ? "super" : has("premium") ? "premium" : has("plus") ? "plus"
                : has("free") ? "free" : nil
        case .opencodeGo:
            id = has("plus") ? "go-plus" : has("team") ? "go-teams" : "go"
        case .opencodeZen, .openai, .other:
            id = nil
        }
        return id.flatMap { option(s, id: $0) }
    }
}
