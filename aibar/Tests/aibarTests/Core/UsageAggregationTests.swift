import XCTest
@testable import aibar

final class UsageAggregationTests: XCTestCase {
    func testOfficialNormalizationPreservesModelRatiosAndExactTotal() {
        let normalized = UsageAggregation.normalizedUsageByModel(
            [
                "gpt-sol": ["input_tokens": 900, "cached_input_tokens": 100, "total_tokens": 900],
                "gpt-terra": ["input_tokens": 100, "total_tokens": 100],
            ],
            targetTokens: 110
        )

        XCTAssertEqual(normalized["gpt-sol"]?["total_tokens"], 99)
        XCTAssertEqual(normalized["gpt-terra"]?["total_tokens"], 11)
        XCTAssertEqual(normalized.values.reduce(0) { $0 + ($1["total_tokens"] ?? 0) }, 110)
        XCTAssertEqual(normalized["gpt-sol"]?["cached_input_tokens"], 11)
    }

    func testOfficialAccountUsageAtomicallyRecalculatesModelsProjectsAndCosts() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let now = Date()
        let day = UsageAggregation.isoDateOnly(now, timeZone: utc)
        let solUsage = [
            "input_tokens": 9_000_000,
            "cached_input_tokens": 1_800_000,
            "output_tokens": 1_000_000,
            "total_tokens": 10_000_000,
        ]
        let terraUsage = [
            "input_tokens": 1_000_000,
            "output_tokens": 0,
            "total_tokens": 1_000_000,
        ]
        func entry(project: String, model: String, usage: [String: Int], endedAt: Date) -> CachedEntry {
            let summary = FileSummary(
                endedAt: Formatting.isoTimestamp(from: endedAt),
                usage: usage,
                usageByModel: [model: usage],
                dailyUsageByModel: [day: [model: usage]],
                limitsByKind: [:], planType: nil, planAt: nil,
                project: project
            )
            return CachedEntry(mtime: endedAt.timeIntervalSince1970, size: 1, summary: summary)
        }
        let official = CodexAccountTokenUsage(
            dailyTokens: [day: 1_100_000],
            lifetimeTokens: nil,
            peakDailyTokens: 1_100_000
        )
        let prices = [
            "gpt-sol": ModelPrice(input: 1, cachedInput: 0.5, output: 10, source: "test", status: "live"),
            "gpt-terra": ModelPrice(input: 2, cachedInput: 0.2, output: 12, source: "test", status: "live"),
        ]

        let payload = UsageAggregation.buildPayload(
            cacheFiles: [
                "sol.jsonl": entry(project: "alpha", model: "gpt-sol", usage: solUsage, endedAt: now),
                "terra.jsonl": entry(project: "beta", model: "gpt-terra", usage: terraUsage, endedAt: now.addingTimeInterval(-1)),
            ],
            prices: prices,
            priceStatus: "live",
            defaultPlan: "Codex",
            normalizeModel: { $0 ?? "unknown" },
            accountUsage: official,
            calendarTimeZone: utc
        )

        XCTAssertEqual(payload.monthTokens, 1_100_000)
        XCTAssertEqual(payload.models.reduce(0) { $0 + $1.tokens }, 1_100_000)
        XCTAssertEqual(payload.topProjects.reduce(0) { $0 + $1.tokens }, 1_100_000)
        XCTAssertEqual(payload.models.map(\.tokens), [1_000_000, 100_000])
        XCTAssertEqual(payload.topProjects.map(\.tokens), [1_000_000, 100_000])
        XCTAssertEqual(payload.monthInputTokens, 1_000_000)
        XCTAssertEqual(payload.monthCachedTokens, 180_000)
        XCTAssertEqual(payload.monthCost, 2.01, accuracy: 0.000_001)
        XCTAssertEqual(payload.models.reduce(0) { $0 + $1.apiEquivalentCost }, payload.monthCost, accuracy: 0.000_001)
        XCTAssertEqual(payload.topProjects.reduce(0) { $0 + $1.apiEquivalentCost }, payload.monthCost, accuracy: 0.000_001)
        XCTAssertEqual(payload.daily.first { $0.date == day }?.cost ?? 0, payload.monthCost, accuracy: 0.000_001)
    }

    func testAccountOnlyUsageRemainsExplicitlyUnattributed() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let day = UsageAggregation.isoDateOnly(Date(), timeZone: utc)
        let official = CodexAccountTokenUsage(
            dailyTokens: [day: 42_000],
            lifetimeTokens: nil,
            peakDailyTokens: 42_000
        )

        let payload = UsageAggregation.buildPayload(
            cacheFiles: [:], prices: [:], priceStatus: "fallback",
            defaultPlan: "Codex", normalizeModel: { $0 ?? "unknown" },
            accountUsage: official, calendarTimeZone: utc
        )

        XCTAssertEqual(payload.monthTokens, 42_000)
        XCTAssertEqual(payload.models.map(\.model), ["unknown"])
        XCTAssertEqual(payload.models.map(\.tokens), [42_000])
        XCTAssertEqual(payload.topProjects.map(\.name), [UsageAggregation.unattributedProject])
        XCTAssertEqual(payload.topProjects.map(\.tokens), [42_000])
        XCTAssertEqual(payload.monthCost, 0)
    }

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
        XCTAssertEqual(payload.topProjects.first?.models.map(\.model), ["gpt-test"])
        XCTAssertEqual(payload.topProjects.first?.models.first?.tokens, 1_100_000)
        XCTAssertEqual(payload.models.first?.dailyTokens.count, 30)
        XCTAssertEqual(payload.models.first?.dailyTokens.last, 1_100_000)
        XCTAssertEqual(payload.topProjects.first?.dailyTokens.count, 90)
        XCTAssertEqual(payload.topProjects.first?.dailyTokens.last, 1_100_000)
        XCTAssertEqual(payload.monthCost, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(payload.models.first?.apiEquivalentCost ?? 0, 2.5, accuracy: 0.000_001)
    }

    func testBuildPayloadKeepsProjectUsageForNinetyDaysWithoutExtendingMonthlyTotals() {
        let calendar = Calendar(identifier: .gregorian)
        let sixtyDaysAgo = calendar.date(byAdding: .day, value: -60, to: Date())!
        let day = UsageAggregation.isoDateOnly(sixtyDaysAgo)
        let primaryUsage = ["total_tokens": 600]
        let secondaryUsage = ["total_tokens": 400]
        let summary = FileSummary(
            endedAt: Formatting.isoTimestamp(from: sixtyDaysAgo),
            usage: ["total_tokens": 1_000],
            usageByModel: ["gpt-primary": primaryUsage, "gpt-secondary": secondaryUsage],
            dailyUsageByModel: [day: ["gpt-primary": primaryUsage, "gpt-secondary": secondaryUsage]],
            limitsByKind: [:], planType: nil, planAt: nil, project: "older-project"
        )

        let payload = UsageAggregation.buildPayload(
            cacheFiles: ["older.jsonl": CachedEntry(mtime: 0, size: 1, summary: summary)],
            prices: [:], priceStatus: "fallback", defaultPlan: "Codex",
            normalizeModel: { $0 ?? "unknown" }
        )

        XCTAssertEqual(payload.monthTokens, 0)
        XCTAssertEqual(payload.topProjects.first?.name, "older-project")
        XCTAssertEqual(payload.topProjects.first?.tokens, 1_000)
        XCTAssertEqual(payload.topProjects.first?.models.map(\.model), ["gpt-primary", "gpt-secondary"])
        XCTAssertEqual(payload.topProjects.first?.models.map(\.tokens), [600, 400])
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

    func testBuildPayloadAppliesLongContextRatesToOnlyFlaggedEvents() {
        let now = Date()
        let day = UsageAggregation.isoDateOnly(now)
        let usage = [
            // 1M short + 1M long input; each half contains the same category mix.
            "input_tokens": 2_000_000,
            "cached_input_tokens": 1_200_000,
            "cache_write_input_tokens": 400_000,
            "output_tokens": 200_000,
            "total_tokens": 2_200_000,
            "long_context_input_tokens": 1_000_000,
            "long_context_cached_input_tokens": 600_000,
            "long_context_cache_write_input_tokens": 200_000,
            "long_context_output_tokens": 100_000,
        ]
        let summary = FileSummary(
            endedAt: Formatting.isoTimestamp(from: now),
            usage: usage,
            usageByModel: ["gpt-test": usage],
            dailyUsageByModel: [day: ["gpt-test": usage]],
            limitsByKind: [:], planType: nil, planAt: nil, project: nil
        )
        let price = ModelPrice(
            input: 2, cachedInput: 0.5, output: 8, cacheWrite: 2.5,
            longContextThreshold: 272_000,
            longInputMultiplier: 2, longCachedInputMultiplier: 2,
            longCacheWriteMultiplier: 2, longOutputMultiplier: 1.5,
            source: "test", status: "live"
        )

        let payload = UsageAggregation.buildPayload(
            cacheFiles: ["session.jsonl": CachedEntry(mtime: 0, size: 1, summary: summary)],
            prices: ["gpt-test": price], priceStatus: "live", defaultPlan: "Codex",
            normalizeModel: { $0 ?? "unknown" }
        )

        // Short: 200k input @2 + 200k write @2.5 + 600k cached @.5 + 100k output @8 = 2.0
        // Long: the same mix at 2x input/cache/write and 1.5x output = 3.6
        XCTAssertEqual(payload.monthCost, 5.6, accuracy: 0.000_001)
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
