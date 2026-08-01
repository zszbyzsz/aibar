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

    func testActiveGoalUsesAccumulatedRuntimeAcrossAutomaticTurns() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-goal-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            goalEvent(status: "active", timeUsedSeconds: 600, updatedAt: 10_000),
            event(type: "task_started", startedAt: 10_100),
            event(type: "task_complete"),
            event(type: "task_started", startedAt: 10_500),
            event(type: "token_count"),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        let startedAt = CodexActivityMonitor.activityStartedAt(inRolloutAt: url.path)

        // 10,000 - 600: the clock represents total active goal runtime, not
        // only the latest automatic task that began at 10,500.
        XCTAssertEqual(startedAt?.timeIntervalSince1970, 9_400)
    }

    func testPausedGoalFallsBackToLatestConversationTurn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-paused-goal-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [
            goalEvent(status: "active", timeUsedSeconds: 600, updatedAt: 10_000),
            goalEvent(status: "paused", timeUsedSeconds: 900, updatedAt: 10_300),
            event(type: "task_started", startedAt: 10_500),
            event(type: "token_count"),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        let startedAt = CodexActivityMonitor.activityStartedAt(inRolloutAt: url.path)

        XCTAssertEqual(startedAt?.timeIntervalSince1970, 10_500)
    }

    func testClearedGoalFallsBackToLatestConversationTurn() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-cleared-goal-rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let cleared = #"{"timestamp":"2026-07-31T06:01:19Z","type":"event_msg","payload":{"type":"thread_goal_cleared"}}"#
        let lines = [
            goalEvent(status: "active", timeUsedSeconds: 600, updatedAt: 10_000),
            cleared,
            event(type: "task_started", startedAt: 10_500),
            event(type: "token_count"),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)

        let startedAt = CodexActivityMonitor.activityStartedAt(inRolloutAt: url.path)

        XCTAssertEqual(startedAt?.timeIntervalSince1970, 10_500)
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

    private func goalEvent(status: String, timeUsedSeconds: Int, updatedAt: Int) -> String {
        let object: [String: Any] = [
            "timestamp": "2026-07-31T06:01:19Z",
            "type": "event_msg",
            "payload": [
                "type": "thread_goal_updated",
                "goal": [
                    "status": status,
                    "timeUsedSeconds": timeUsedSeconds,
                    "updatedAt": updatedAt,
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
