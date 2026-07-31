import Foundation

actor PricingService {
    static let modelPages: [String: String] = [
        "gpt-5.6-sol": "https://developers.openai.com/api/docs/models/gpt-5.6-sol",
        "gpt-5.6-terra": "https://developers.openai.com/api/docs/models/gpt-5.6-terra",
        "gpt-5.6-luna": "https://developers.openai.com/api/docs/models/gpt-5.6-luna",
        "gpt-5.5": "https://developers.openai.com/api/docs/models/gpt-5.5",
        "gpt-5.4": "https://developers.openai.com/api/docs/models/gpt-5.4",
        "gpt-5.4-mini": "https://developers.openai.com/api/docs/models/gpt-5.4-mini",
    ]

    /// Last values verified against each model's doc page. Every model in
    /// `modelPages` needs an entry: a model listed for a live fetch but missing
    /// here has no rate at all when that fetch fails, so its usage quietly costs
    /// $0 instead of falling back to a known-stale-but-right number.
    static let fallbackPrices: [String: ModelPrice] = [
        "gpt-5.6-sol": ModelPrice(input: 5.0, cachedInput: 0.5, output: 30.0, source: modelPages["gpt-5.6-sol"]!, status: "fallback"),
        "gpt-5.6-terra": ModelPrice(input: 2.5, cachedInput: 0.25, output: 15.0, source: modelPages["gpt-5.6-terra"]!, status: "fallback"),
        "gpt-5.6-luna": ModelPrice(input: 1.0, cachedInput: 0.1, output: 6.0, source: modelPages["gpt-5.6-luna"]!, status: "fallback"),
        "gpt-5.5": ModelPrice(input: 5.0, cachedInput: 0.5, output: 30.0, source: modelPages["gpt-5.5"]!, status: "fallback"),
        "gpt-5.4": ModelPrice(input: 2.5, cachedInput: 0.25, output: 15.0, source: modelPages["gpt-5.4"]!, status: "fallback"),
        "gpt-5.4-mini": ModelPrice(input: 0.75, cachedInput: 0.075, output: 4.5, source: modelPages["gpt-5.4-mini"]!, status: "fallback"),
    ]

    private static let ttl: TimeInterval = 12 * 3600

    private var cachedAt = Date.distantPast
    private var cachedPrices: [String: ModelPrice] = [:]

    /// Live-fetches current per-model $/1M-token rates (input, cached input, output) from
    /// each model's official doc page, refreshing at most every 12h; falls back to the last
    /// verified values when offline so the popover never shows a blank price.
    func prices() async -> (models: [String: ModelPrice], status: String) {
        if !cachedPrices.isEmpty, Date().timeIntervalSince(cachedAt) < Self.ttl {
            return (cachedPrices, "cached")
        }

        var result: [String: ModelPrice] = [:]
        var anyLive = false

        await withTaskGroup(of: (String, ModelPrice?).self) { group in
            for (model, urlString) in Self.modelPages {
                group.addTask {
                    (model, await Self.fetchOne(model: model, urlString: urlString))
                }
            }
            for await (model, price) in group {
                if let price {
                    result[model] = price
                }
            }
        }

        for (model, _) in Self.modelPages where result[model] == nil {
            if let fallback = Self.fallbackPrices[model] {
                result[model] = fallback
            } else if let previous = cachedPrices[model] {
                result[model] = previous
            }
        }

        anyLive = result.values.contains { $0.status == "live" }
        if !result.isEmpty {
            cachedPrices = result
            cachedAt = Date()
        }
        return (result, anyLive ? "live" : "fallback")
    }

    private static func fetchOne(model: String, urlString: String) async -> ModelPrice? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("aibarUsage/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        // A retired model's page still answers with a full HTML body under a 404,
        // so status has to be checked before trusting anything scraped out of it.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let html = String(decoding: data, as: UTF8.self)
        guard
            let input = extract(pattern: #">Input</div><div[^>]*>\$([0-9]+(?:\.[0-9]+)?)</div>"#, from: html),
            let cached = extract(pattern: #">Cached input</div><div[^>]*>\$([0-9]+(?:\.[0-9]+)?)</div>"#, from: html),
            let output = extract(pattern: #">Output</div><div[^>]*>\$([0-9]+(?:\.[0-9]+)?)</div>"#, from: html)
        else { return nil }
        return ModelPrice(input: input, cachedInput: cached, output: output, source: urlString, status: "live")
    }

    private static func extract(pattern: String, from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[matchRange])
    }
}
