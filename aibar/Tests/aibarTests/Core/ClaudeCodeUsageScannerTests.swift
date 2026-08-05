import XCTest
@testable import aibar

final class ClaudeCodeUsageScannerTests: XCTestCase {
    private func writeFixture(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeUsageScannerTests-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testParseSessionSumsUsageAndCountsFileEditingToolsOnly() throws {
        let lines = [
            #"{"type":"user","cwd":"/Users/x/my-project","timestamp":"2026-07-20T09:00:00Z"}"#,
            #"{"type":"assistant","timestamp":"2026-07-20T09:01:00Z","message":{"model":"claude-sonnet-5-20250929","usage":{"input_tokens":1000,"cache_read_input_tokens":200,"cache_creation_input_tokens":50,"output_tokens":300},"content":[{"type":"tool_use","name":"Edit"},{"type":"tool_use","name":"mcp__figma__get_design_context"}]}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = ClaudeCodeUsageScanner()

        let summary = try XCTUnwrap(scanner.parseSession(url: url))

        XCTAssertEqual(summary.project, "my-project")
        XCTAssertEqual(summary.usage["total_tokens"], 1550)
        // Anthropic's own `input_tokens` (1000) counts only the uncached
        // remainder; it's widened here to the whole prompt — uncached plus cache
        // reads plus cache writes — to match the shape UsageAggregation prices.
        XCTAssertEqual(summary.usage["input_tokens"], 1250)
        XCTAssertEqual(summary.usage["cached_input_tokens"], 200)
        XCTAssertEqual(summary.usage["cache_write_input_tokens"], 50)
        // Model's dated snapshot suffix is stripped so it still keys into the price table.
        XCTAssertEqual(summary.usageByModel["claude-sonnet-5"]?["total_tokens"], 1550)
        XCTAssertNil(summary.usageByModel["claude-sonnet-5-20250929"])
        // Both tool_use blocks count as tool calls, but only Edit is a file-changing tool.
        XCTAssertEqual(summary.toolCallCount, 2)
        XCTAssertEqual(summary.filesChangedCount, 1)
        XCTAssertEqual(summary.mcpCallCount, 1)
        XCTAssertEqual(summary.mcpUsage, ["figma": 1])
    }

    func testParseSessionReturnsNilWhenNoAssistantUsageEventsPresent() throws {
        let lines = [
            #"{"type":"user","cwd":"/Users/x/empty","timestamp":"2026-07-20T09:00:00Z"}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = ClaudeCodeUsageScanner()

        XCTAssertNil(scanner.parseSession(url: url))
    }

    func testParseSessionIgnoresAssistantMessagesWithZeroUsage() throws {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-07-20T09:01:00Z","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":0,"output_tokens":0}}}"#,
        ]
        let url = try writeFixture(lines)
        let scanner = ClaudeCodeUsageScanner()

        XCTAssertNil(scanner.parseSession(url: url))
    }

    func testNormalizedModelStripsTrailingDateSnapshotOnly() {
        let scanner = ClaudeCodeUsageScanner()
        XCTAssertEqual(scanner.normalizedModel("claude-sonnet-5-20250929"), "claude-sonnet-5")
        XCTAssertEqual(scanner.normalizedModel("claude-haiku-4-5"), "claude-haiku-4-5")
        XCTAssertEqual(scanner.normalizedModel(nil), "unknown")
        XCTAssertEqual(scanner.normalizedModel(""), "unknown")
        // Only a trailing 8-digit date suffix should be stripped, not an
        // arbitrary numeric-looking tail.
        XCTAssertEqual(scanner.normalizedModel("claude-sonnet-5-123"), "claude-sonnet-5-123")
    }
}
