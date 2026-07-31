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
        "gpt-5.6-sol": price(input: 5.0, cachedInput: 0.5, output: 30.0, model: "gpt-5.6-sol"),
        "gpt-5.6-terra": price(input: 2.0, cachedInput: 0.2, output: 12.0, model: "gpt-5.6-terra"),
        "gpt-5.6-luna": price(input: 0.2, cachedInput: 0.02, output: 1.2, model: "gpt-5.6-luna"),
        "gpt-5.5": price(input: 5.0, cachedInput: 0.5, output: 30.0, model: "gpt-5.5"),
        "gpt-5.4": price(input: 2.5, cachedInput: 0.25, output: 15.0, model: "gpt-5.4"),
        "gpt-5.4-mini": price(input: 0.75, cachedInput: 0.075, output: 4.5, model: "gpt-5.4-mini"),
    ]

    private static let ttl: TimeInterval = 12 * 3600

    private var cachedAt = Date.distantPast
    private var cachedPrices: [String: ModelPrice] = [:]
    private var cachedStatus = "fallback"

    /// Returns something usable without waiting for the network. This lets a
    /// first-run dashboard render its local usage immediately while `prices()`
    /// refreshes the official rates in parallel.
    func cachedOrFallbackPrices() -> (models: [String: ModelPrice], status: String) {
        guard !cachedPrices.isEmpty else { return (Self.fallbackPrices, "fallback") }
        return (cachedPrices, cachedStatus == "live" ? "cached" : cachedStatus)
    }

    /// Live-fetches current per-model $/1M-token rates (input, cached input, output) from
    /// each model's official doc page, refreshing at most every 12h; falls back to the last
    /// verified values when offline so the popover never shows a blank price.
    func prices() async -> (models: [String: ModelPrice], status: String) {
        if !cachedPrices.isEmpty, Date().timeIntervalSince(cachedAt) < Self.ttl {
            return (cachedPrices, cachedStatus == "live" ? "cached" : cachedStatus)
        }

        var result: [String: ModelPrice] = [:]

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

        let liveCount = result.values.filter { $0.status == "live" }.count
        let status = liveCount == Self.modelPages.count
            ? "live"
            : (liveCount > 0 ? "partial" : "fallback")
        if !result.isEmpty {
            cachedPrices = result
            cachedAt = Date()
            cachedStatus = status
        }
        return (result, status)
    }

    private static func price(input: Double, cachedInput: Double, output: Double, model: String) -> ModelPrice {
        let longContext = longContextRates(for: model)
        return ModelPrice(
            input: input,
            cachedInput: cachedInput,
            output: output,
            cacheWrite: cacheWriteRate(input: input, model: model),
            longContextThreshold: longContext?.threshold,
            longInputMultiplier: longContext?.input,
            longCachedInputMultiplier: longContext?.cachedInput,
            longCacheWriteMultiplier: longContext?.cacheWrite,
            longOutputMultiplier: longContext?.output,
            source: modelPages[model]!,
            status: "fallback"
        )
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
        let longContext = longContextRates(for: model)
        return ModelPrice(
            input: input,
            cachedInput: cached,
            output: output,
            cacheWrite: cacheWriteRate(input: input, model: model),
            longContextThreshold: longContext?.threshold,
            longInputMultiplier: longContext?.input,
            longCachedInputMultiplier: longContext?.cachedInput,
            longCacheWriteMultiplier: longContext?.cacheWrite,
            longOutputMultiplier: longContext?.output,
            source: urlString,
            status: "live"
        )
    }

    /// GPT-5.6 and later charge cache writes at 1.25× their uncached input
    /// rate; cache reads remain at the discounted cached-input rate.
    private static func cacheWriteRate(input: Double, model: String) -> Double {
        model.hasPrefix("gpt-5.6-") ? input * 1.25 : input
    }

    /// GPT-5.6, GPT-5.5, and GPT-5.4 apply their long-context tier to the
    /// complete request once input exceeds 272K tokens. GPT-5.4 mini has no
    /// published long-context tier, so it intentionally stays nil.
    private static func longContextRates(
        for model: String
    ) -> (threshold: Int, input: Double, cachedInput: Double, cacheWrite: Double, output: Double)? {
        let supportsLongContextPricing = model.hasPrefix("gpt-5.6-") || model == "gpt-5.5" || model == "gpt-5.4"
        guard supportsLongContextPricing else { return nil }
        return (272_000, 2, 2, 2, 1.5)
    }

    private static func extract(pattern: String, from text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[matchRange])
    }
}
