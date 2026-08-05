import XCTest
@testable import aibar

final class UsageScannerTests: XCTestCase {
    private func writeFixture(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageScannerTests-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPriorCacheVersionsRemainReadableDuringMCPBackfill() {
        XCTAssertTrue(UsageScanner.canReadCacheVersion(7))
        XCTAssertTrue(UsageScanner.canReadCacheVersion(8))
        XCTAssertTrue(UsageScanner.canReadCacheVersion(9))
        XCTAssertFalse(UsageScanner.canReadCacheVersion(6))
    }

    func testLegacyCacheSummaryDecodesWithoutNewToolCounters() throws {
        // v7 caches contain real token/project summaries but predate the two
        // optional per-tool fields. A missing field must not invalidate the
        // entire on-disk cache and trigger a full transcript rebuild.
        let data = Data(
            #"{"endedAt":"2026-08-02T10:00:00Z","usage":{"total_tokens":42},"usageByModel":{"gpt-5.6-sol":{"total_tokens":42}},"limitsByKind":{},"planType":"Pro","planAt":null,"project":"aibar","toolCallCount":3,"filesChangedCount":1}"#
                .utf8
        )

        let summary = try JSONDecoder().decode(FileSummary.self, from: data)

        XCTAssertEqual(summary.usage["total_tokens"], 42)
        XCTAssertEqual(summary.toolCallCount, 3)
        XCTAssertEqual(summary.toolUsage, [:])
        XCTAssertEqual(summary.dailyToolUsage, [:])
        XCTAssertEqual(summary.mcpCallCount, 0)
        XCTAssertEqual(summary.mcpUsage, [:])
        XCTAssertEqual(summary.dailyMCPUsage, [:])
        XCTAssertEqual(summary.dailyUsageByModel, [:])
    }

    func testParseSessionAggregatesTokensToolCallsAndLimits() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/my-project"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.6-sol","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":500,"total_tokens":1500}}}}"#,
            #"{"timestamp":"2026-07-20T10:02:00Z","type":"event_msg","payload":{"type":"function_call"}}"#,
            #"{"timestamp":"2026-07-20T10:02:30Z","type":"event_msg","payload":{"type":"mcp_tool_call_end","invocation":{"server":"figma","tool":"get_design_context"}}}"#,
            #"{"timestamp":"2026-07-20T10:03:00Z","type":"event_msg","payload":{"type":"patch_apply_end","changes":{"a.swift":{},"b.swift":{}}}}"#,
            #"{"timestamp":"2026-07-20T10:04:00Z","type":"event_msg","payload":{"type":"turn_context","rate_limits":{"plan_type":"Pro","primary":{"window_minutes":300,"used_percent":45.5,"resets_at":1780000000},"secondary":{"window_minutes":10080,"used_percent":12.3,"resets_at":1781000000}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))

        XCTAssertEqual(summary.project, "my-project")
        XCTAssertEqual(summary.usage["total_tokens"], 1500)
        XCTAssertEqual(summary.usage["input_tokens"], 1000)
        XCTAssertEqual(summary.usageByModel["gpt-5.6-sol"]?["total_tokens"], 1500)
        XCTAssertEqual(summary.toolCallCount, 1)
        XCTAssertEqual(summary.mcpCallCount, 1)
        XCTAssertEqual(summary.mcpUsage, ["figma": 1])
        XCTAssertEqual(summary.dailyMCPUsage["2026-07-20"], ["figma": 1])
        XCTAssertEqual(summary.filesChangedCount, 2)
        XCTAssertEqual(summary.planType, "Pro")
        XCTAssertEqual(summary.limitsByKind["session"]?.usedPercent, 45.5)
        XCTAssertEqual(summary.limitsByKind["session"]?.windowMinutes, 300)
        XCTAssertEqual(summary.limitsByKind["weekly"]?.usedPercent, 12.3)
        XCTAssertEqual(summary.endedAt, "2026-07-20T10:04:00Z")
    }

    func testParseSessionReturnsNilWhenNoTokenUsageEventsPresent() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/empty"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"function_call"}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        XCTAssertNil(scanner.parseSession(url: url))
    }

    func testParseSessionSkipsMalformedLinesWithoutFailingTheWholeFile() throws {
        let lines = [
            "not json at all",
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.6-terra","info":{"last_token_usage":{"input_tokens":10,"total_tokens":10}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))
        XCTAssertEqual(summary.usage["total_tokens"], 10)
    }

    func testNormalizedModelMapsBareGpt56ToSolButLeavesOtherNamesAlone() {
        let scanner = UsageScanner()
        XCTAssertEqual(scanner.normalizedModel("gpt-5.6"), "gpt-5.6-sol")
        XCTAssertEqual(scanner.normalizedModel("gpt-5.6-terra"), "gpt-5.6-terra")
        XCTAssertEqual(scanner.normalizedModel(nil), "unknown")
        XCTAssertEqual(scanner.normalizedModel(""), "unknown")
    }

    /// Regression test for a real over-count: Codex re-emits the previous turn's
    /// `token_count` when it refreshes its usage display, so the same
    /// `last_token_usage` shows up again with an unmoved `total_token_usage`.
    /// Only the running total proves tokens were actually billed.
    func testParseSessionIgnoresRepeatedTokenCountWithUnchangedRunningTotal() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"total_tokens":1100},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"total_tokens":1100}}}}"#,
            #"{"timestamp":"2026-07-20T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":900,"output_tokens":50,"total_tokens":1250},"total_token_usage":{"input_tokens":2200,"cached_input_tokens":1300,"output_tokens":150,"total_tokens":2350}}}}"#,
            // Same running total as the line above: a redisplay, not an API call.
            #"{"timestamp":"2026-07-20T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200,"cached_input_tokens":900,"output_tokens":50,"total_tokens":1250},"total_token_usage":{"input_tokens":2200,"cached_input_tokens":1300,"output_tokens":150,"total_tokens":2350}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))

        XCTAssertEqual(summary.usage["total_tokens"], 2350)
        XCTAssertEqual(summary.usage["input_tokens"], 2200)
        XCTAssertEqual(summary.usage["cached_input_tokens"], 1300)
        XCTAssertEqual(summary.usageByModel["gpt-5.6-sol"]?["total_tokens"], 2350)
    }

    /// A repeat is only a repeat when the running total is identical — two turns
    /// that happen to consume the same number of tokens must both be counted.
    func testParseSessionKeepsIdenticalUsageWhenRunningTotalAdvances() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":10,"total_tokens":510},"total_token_usage":{"input_tokens":500,"output_tokens":10,"total_tokens":510}}}}"#,
            #"{"timestamp":"2026-07-20T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":10,"total_tokens":510},"total_token_usage":{"input_tokens":1000,"output_tokens":20,"total_tokens":1020}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))
        XCTAssertEqual(summary.usage["total_tokens"], 1020)
    }

    /// Codex can refresh a non-billing detail in the running snapshot while
    /// keeping its authoritative total unchanged. That is still a redisplay,
    /// even though comparing the entire dictionary would make it look new.
    func testParseSessionIgnoresTokenCountWhenOnlyRunningSnapshotDetailsChange() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":10,"total_tokens":510},"total_token_usage":{"input_tokens":500,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":510}}}}"#,
            #"{"timestamp":"2026-07-20T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"output_tokens":0,"reasoning_output_tokens":7,"total_tokens":7},"total_token_usage":{"input_tokens":500,"output_tokens":10,"reasoning_output_tokens":7,"total_tokens":510}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))
        XCTAssertEqual(summary.usage["total_tokens"], 510)
        XCTAssertEqual(summary.usage["reasoning_output_tokens"], 0)
    }

    /// A new transcript sometimes starts with a stale UI-only total even
    /// though no billed category moved. Its running total may be inherited
    /// from a parent transcript, so that value alone cannot validate it.
    func testParseSessionIgnoresInitialGhostTotalWithNoBillableCategories() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":4554},"total_token_usage":{"input_tokens":613000,"cached_input_tokens":600000,"cache_write_input_tokens":0,"output_tokens":931,"reasoning_output_tokens":100,"total_tokens":613931}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        XCTAssertNil(scanner.parseSession(url: url))
    }

    /// Legacy records without a running counter still rely on their last-usage
    /// value, so the ghost filter must not discard valid total-only history.
    func testParseSessionKeepsTotalOnlyUsageWhenNoRunningCounterExists() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","model":"gpt-5.6-sol","info":{"last_token_usage":{"total_tokens":123}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))
        XCTAssertEqual(summary.usage["total_tokens"], 123)
    }

    func testParseSessionPreservesPerEventLongContextSlicesForPricing() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":272001,"cached_input_tokens":200000,"cache_write_input_tokens":50000,"output_tokens":1000,"total_tokens":273001},"total_token_usage":{"input_tokens":272001,"cached_input_tokens":200000,"cache_write_input_tokens":50000,"output_tokens":1000,"total_tokens":273001}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))
        let usage = try XCTUnwrap(summary.usageByModel["gpt-5.6-sol"])
        XCTAssertEqual(usage["long_context_input_tokens"], 272_001)
        XCTAssertEqual(usage["long_context_cached_input_tokens"], 200_000)
        XCTAssertEqual(usage["long_context_cache_write_input_tokens"], 50_000)
        XCTAssertEqual(usage["long_context_output_tokens"], 1_000)
    }

    /// Older Codex sessions log their first `token_count` events before any
    /// `turn_context` names a model. Left as "unknown" those tokens match no
    /// price table entry and are costed at $0, so they're re-attributed to the
    /// first model the session does name.
    func testParseSessionBackfillsModelForEventsLoggedBeforeFirstTurnContext() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/legacy"}}"#,
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":800,"output_tokens":40,"total_tokens":840},"total_token_usage":{"input_tokens":800,"output_tokens":40,"total_tokens":840}}}}"#,
            #"{"timestamp":"2026-07-20T10:02:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-07-20T10:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"output_tokens":10,"total_tokens":210},"total_token_usage":{"input_tokens":1000,"output_tokens":50,"total_tokens":1050}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))

        // Day keys are bucketed in the viewer's own timezone, so derive the
        // expected key rather than hard-coding the fixture's UTC date.
        let day = UsageAggregation.isoDateOnly(try XCTUnwrap(Formatting.parseISODate("2026-07-20T10:01:00Z")))
        XCTAssertNil(summary.usageByModel["unknown"])
        XCTAssertEqual(summary.usageByModel["gpt-5.6-sol"]?["total_tokens"], 1050)
        XCTAssertEqual(summary.dailyUsageByModel[day]?["gpt-5.6-sol"]?["total_tokens"], 1050)
        XCTAssertNil(summary.dailyUsageByModel[day]?["unknown"])
    }

    /// Nothing to back-fill onto: a session that never names a model has to stay
    /// "unknown" rather than being guessed into somebody's price table.
    func testParseSessionLeavesUsageUnknownWhenSessionNeverNamesAModel() throws {
        let lines = [
            #"{"timestamp":"2026-07-20T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":800,"output_tokens":40,"total_tokens":840}}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = UsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))
        XCTAssertEqual(summary.usageByModel["unknown"]?["total_tokens"], 840)
    }

    func testClassifyWindowBucketsBySessionWeeklyMonthly() {
        let scanner = UsageScanner()
        XCTAssertNil(scanner.classifyWindow(0))
        XCTAssertNil(scanner.classifyWindow(-10))
        XCTAssertEqual(scanner.classifyWindow(300), "session")
        XCTAssertEqual(scanner.classifyWindow(600), "session")
        XCTAssertEqual(scanner.classifyWindow(601), "weekly")
        XCTAssertEqual(scanner.classifyWindow(20_000), "weekly")
        XCTAssertEqual(scanner.classifyWindow(20_001), "monthly")
    }
}
