import Foundation

/// Per-token prices, loaded from a LiteLLM-format price table.
/// Order: T3 Code's cached copy → our own cache → fresh download from LiteLLM on GitHub.
final class Pricing {
    struct Rate {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
        var cacheWrite1h: Double
    }

    private var table: [String: Rate] = [:]
    private var memo: [String: Rate?] = [:]
    private let lock = NSLock()

    static let litellmURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    static var cacheURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tally", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model-prices.json")
    }

    var isLoaded: Bool { lock.withLock { !table.isEmpty } }

    func load() async {
        if isLoaded { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".t3/userdata/usage-model-rates.json"),
            Pricing.cacheURL,
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url), ingest(data) { return }
        }
        if let (data, _) = try? await URLSession.shared.data(from: Pricing.litellmURL), ingest(data) {
            try? data.write(to: Pricing.cacheURL)
        }
    }

    @discardableResult
    private func ingest(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let doc = (obj["document"] as? [String: Any]) ?? obj
        var t: [String: Rate] = [:]
        for (key, value) in doc {
            guard let v = value as? [String: Any],
                  let inp = v["input_cost_per_token"] as? Double,
                  let out = v["output_cost_per_token"] as? Double else { continue }
            let read = v["cache_read_input_token_cost"] as? Double ?? inp * 0.1
            let write = v["cache_creation_input_token_cost"] as? Double ?? inp * 1.25
            let write1h = v["cache_creation_input_token_cost_above_1hr"] as? Double ?? write * 1.6
            t[key.lowercased()] = Rate(input: inp, output: out, cacheRead: read, cacheWrite: write, cacheWrite1h: write1h)
        }
        guard !t.isEmpty else { return false }
        lock.withLock { table = t; memo = [:] }
        return true
    }

    func rate(for rawModel: String) -> Rate? {
        let model = rawModel.lowercased()
        return lock.withLock {
            if let cached = memo[model] { return cached }
            let r = resolve(model)
            memo[model] = r
            return r
        }
    }

    private func resolve(_ model: String) -> Rate? {
        var names = [model]
        if let slash = model.lastIndex(of: "/") { names.append(String(model[model.index(after: slash)...])) }
        // Strip date suffixes like -20251001, bracketed context tags like [1m],
        // and Antigravity display names like "Gemini 3.5 Flash (Medium)" → "gemini-3.5-flash".
        for n in names {
            let cleaned = n.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\[.*\]$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if cleaned != n { names.append(cleaned) }
            let slug = cleaned.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            if slug != cleaned { names.append(slug) }
            let dotDash = slug.replacingOccurrences(of: ".", with: "-")
            if dotDash != slug { names.append(dotDash) }
        }
        for n in names {
            if let r = table[n] { return r }
            for prefix in ["anthropic/", "openai/", "anthropic.", "openai.", "xai/", "deepseek/", "gemini/", "google/", "vertex_ai/"] {
                if let r = table[prefix + n] { return r }
            }
        }
        // Longest table key that the model name starts with.
        if let base = names.last {
            let match = table.keys.filter { !$0.contains("/") && $0.count >= 6 && base.hasPrefix($0) }
                .max(by: { $0.count < $1.count })
            if let match { return table[match] }
        }
        return nil
    }
}
