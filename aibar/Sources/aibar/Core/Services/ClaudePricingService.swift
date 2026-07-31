import Foundation

/// Anthropic doesn't publish per-model $/1M rates in the single scrapable
/// per-model doc-page format PricingService relies on for OpenAI's models, so
/// this only ever serves the fallback table below — always reported as
/// "fallback" status, which the UI already renders as "使用离线缓存价格" and
/// a dim (non-live) price-source dot on every model row.
actor ClaudePricingService {
    private static let source = "https://docs.claude.com/en/docs/about-claude/pricing"
    /// Anthropic bills a 5-minute cache write at 1.25x the model's input rate —
    /// unlike OpenAI, it's a real line item, and Claude Code's transcripts report
    /// those tokens separately from both input and cache reads.
    private static let cacheWriteMultiplier = 1.25

    private static func price(input: Double, cachedInput: Double, output: Double) -> ModelPrice {
        ModelPrice(input: input, cachedInput: cachedInput, output: output,
                   cacheWrite: input * cacheWriteMultiplier, source: source, status: "fallback")
    }

    static let fallbackPrices: [String: ModelPrice] = [
        "claude-opus-4-8": price(input: 15.0, cachedInput: 1.5, output: 75.0),
        "claude-sonnet-5": price(input: 3.0, cachedInput: 0.3, output: 15.0),
        "claude-haiku-4-5": price(input: 1.0, cachedInput: 0.1, output: 5.0),
        "claude-fable-5": price(input: 3.0, cachedInput: 0.3, output: 15.0),
    ]

    func prices() async -> (models: [String: ModelPrice], status: String) {
        (Self.fallbackPrices, "fallback")
    }
}
