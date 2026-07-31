import Foundation
import XCTest
@testable import aibar

final class CodexActivityMonitorTests: XCTestCase {
    func testLatestTaskStartComesFromMostRecentTurnInsteadOfThreadCreation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let oldStart = event(type: "task_started", startedAt: 1_000)
        let oldCompletion = event(type: "task_complete")
        let currentStart = event(type: "task_started", startedAt: 9_000)
        // Keep the current turn's start well outside the 64 KiB activity tail;
        // this is the shape that exposed the bug in a long-running thread.
        let largeCurrentTurn = event(type: "agent_message", extra: String(repeating: "x", count: 180_000))
        let activeEvent = event(type: "token_count")
        try ([oldStart, oldCompletion, currentStart, largeCurrentTurn, activeEvent].joined(separator: "\n") + "\n")
            .data(using: .utf8)?
            .write(to: url)

        let startedAt = CodexActivityMonitor.latestTaskStartedAt(inRolloutAt: url.path)

        XCTAssertEqual(startedAt?.timeIntervalSince1970, 9_000)
    }

    func testTaskStartFallsBackToEnvelopeTimestampWhenStartedAtIsMissing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = #"{"timestamp":"2026-07-31T06:01:19Z","type":"event_msg","payload":{"type":"task_started"}}"#
        try Data((line + "\n").utf8).write(to: url)

        let startedAt = CodexActivityMonitor.latestTaskStartedAt(inRolloutAt: url.path)

        XCTAssertEqual(startedAt?.timeIntervalSince1970, 1_785_477_679)
    }

    private func event(type: String, startedAt: Int? = nil, extra: String? = nil) -> String {
        var payload: [String: Any] = ["type": type]
        if let startedAt { payload["started_at"] = startedAt }
        if let extra { payload["message"] = extra }
        let object: [String: Any] = [
            "timestamp": "2026-07-31T06:01:19Z",
            "type": "event_msg",
            "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
