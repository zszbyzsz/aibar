import XCTest
@testable import aibar

final class UsageAggregationTests: XCTestCase {
    func testBuildPayloadCalculatesPricedUsageAndProjects() {
        let now = Date()
        let day = UsageAggregation.isoDateOnly(now)
        let usage = [
            "input_tokens": 1_000_000,
            "cached_input_tokens": 200_000,
            "output_tokens": 100_000,
            "total_tokens": 1_100_000,
        ]
        let summary = FileSummary(
            endedAt: Formatting.isoTimestamp(from: now),
            usage: usage,
            usageByModel: ["gpt-test": usage],
            dailyUsageByModel: [day: ["gpt-test": usage]],
            limitsByKind: [:],
            planType: "Pro",
            planAt: Formatting.isoTimestamp(from: now),
            project: "aibar",
            toolCallCount: 2,
            filesChangedCount: 3
        )
        let entry = CachedEntry(mtime: now.timeIntervalSince1970, size: 1, summary: summary)
        let prices = ["gpt-test": ModelPrice(input: 2, cachedInput: 0.5, output: 8, source: "test", status: "live")]

        let payload = UsageAggregation.buildPayload(
            cacheFiles: ["session.jsonl": entry],
            prices: prices,
            priceStatus: "live",
            defaultPlan: "Codex",
            normalizeModel: { $0 ?? "unknown" }
        )

        XCTAssertEqual(payload.plan, "Pro")
        XCTAssertEqual(payload.monthTokens, 1_100_000)
        XCTAssertEqual(payload.monthToolCalls, 2)
        XCTAssertEqual(payload.monthFilesChanged, 3)
        XCTAssertEqual(payload.topProjects.first?.name, "aibar")
        XCTAssertEqual(payload.monthCost, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(payload.models.first?.apiEquivalentCost ?? 0, 2.5, accuracy: 0.000_001)
    }

    /// Cache reads and cache writes are slices *inside* `input_tokens`, each
    /// billed at its own rate. Regression test for both halves getting lost:
    /// cache writes were previously charged nothing at all, and on a provider
    /// that reports the three fields disjointly the read discount collapsed to
    /// whatever tiny uncached remainder was left.
    func testBuildPayloadBillsCacheReadsAndCacheWritesAtTheirOwnRates() {
        let now = Date()
        let day = UsageAggregation.isoDateOnly(now)
        let usage = [
            "input_tokens": 1_000_000,      // whole prompt…
            "cached_input_tokens": 600_000, // …of which this was a cache hit
            "cache_write_input_tokens": 300_000, // …and this was written to cache
            "output_tokens": 100_000,
            "total_tokens": 1_100_000,
        ]
        let summary = FileSummary(
            endedAt: Formatting.isoTimestamp(from: now),
            usage: usage,
            usageByModel: ["gpt-test": usage],
            dailyUsageByModel: [day: ["gpt-test": usage]],
            limitsByKind: [:],
            planType: nil,
            planAt: nil,
            project: nil
        )
        let entry = CachedEntry(mtime: now.timeIntervalSince1970, size: 1, summary: summary)
        let prices = [
            "gpt-test": ModelPrice(input: 2, cachedInput: 0.5, output: 8, cacheWrite: 2.5,
                                   source: "test", status: "live"),
        ]

        let payload = UsageAggregation.buildPayload(
            cacheFiles: ["session.jsonl": entry], prices: prices, priceStatus: "live",
            defaultPlan: "Codex", normalizeModel: { $0 ?? "unknown" }
        )

        // 100k uncached @ $2 + 300k written @ $2.50 + 600k cache-hit @ $0.50 +
        // 100k output @ $8 = 0.20 + 0.75 + 0.30 + 0.80
        let model = payload.models.first
        XCTAssertEqual(model?.inputCost ?? 0, 0.95, accuracy: 0.000_001)
        XCTAssertEqual(model?.cachedCost ?? 0, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(model?.outputCost ?? 0, 0.80, accuracy: 0.000_001)
        XCTAssertEqual(payload.monthCost, 2.05, accuracy: 0.000_001)
    }

    /// A price table that leaves `cacheWrite` unset retains the conventional
    /// behavior of charging cache writes at the normal input rate.
    func testCacheWriteRateDefaultsToInputRateWhenUnspecified() {
        let price = ModelPrice(input: 3, cachedInput: 0.3, output: 15, source: "test", status: "live")
        XCTAssertEqual(price.cacheWrite, 3)
    }

    /// Regression test for a real bug: a session file can report a named
    /// per-model sub-quota (e.g. a preview model's own limit) under the same
    /// `weekly` window as the account's real overall usage. A later
    /// timestamp on that named, near-empty sub-quota must never overwrite
    /// the real figure just because it's fresher — only another unnamed
    /// (overall) reading should ever replace it.
    func testWeeklyLimitIgnoresNamedSubQuotaEvenWhenFresher() {
        let now = Date()
        let earlier = Formatting.isoTimestamp(from: now.addingTimeInterval(-60))
        let later = Formatting.isoTimestamp(from: now)

        let usage = ["total_tokens": 100]
        let overallSummary = FileSummary(
            endedAt: earlier,
            usage: usage,
            usageByModel: [:],
            limitsByKind: [
                "weekly": LimitSlot(at: earlier, usedPercent: 42, windowMinutes: 10_080, resetsAt: nil, limitName: nil),
            ],
            planType: nil,
            planAt: nil,
            project: nil
        )
        let subQuotaSummary = FileSummary(
            endedAt: later,
            usage: usage,
            usageByModel: [:],
            limitsByKind: [
                "weekly": LimitSlot(at: later, usedPercent: 0, windowMinutes: 10_080, resetsAt: nil, limitName: "GPT-5.3-Codex-Spark"),
            ],
            planType: nil,
            planAt: nil,
            project: nil
        )

        let payload = UsageAggregation.buildPayload(
            cacheFiles: [
                "overall.jsonl": CachedEntry(mtime: 0, size: 1, summary: overallSummary),
                "subquota.jsonl": CachedEntry(mtime: 0, size: 1, summary: subQuotaSummary),
            ],
            prices: [:],
            priceStatus: "fallback",
            defaultPlan: "Codex",
            normalizeModel: { $0 ?? "unknown" }
        )

        XCTAssertEqual(payload.weekly?.usedPercent, 42)
    }
}
