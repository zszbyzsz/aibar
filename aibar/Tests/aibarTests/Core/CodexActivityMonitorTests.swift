import Foundation
import SQLite3
import XCTest
@testable import aibar

final class CodexActivityMonitorTests: XCTestCase {
    func testScreenToolsUseDedicatedActivityPhase() {
        XCTAssertEqual(
            CodexActivityMonitor.activityPhase(forToolName: "computer"),
            .usingScreen
        )
        XCTAssertEqual(
            CodexActivityMonitor.activityPhase(forToolName: "mcp__desktop__take_screenshot"),
            .usingScreen
        )
        XCTAssertEqual(
            CodexActivityMonitor.activityPhase(
                forToolName: nil,
                mcpServer: "node_repl",
                mcpTool: "js"
            ),
            .usingScreen
        )
        XCTAssertEqual(
            CodexActivityMonitor.activityPhase(forToolName: "exec"),
            .usingTool
        )
    }

    func testStateDatabaseSelectionUsesNewestThreadIndexWhenBothPathsExist() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-codex-home-\(UUID().uuidString)")
        let nestedDirectory = codexHome.appendingPathComponent("sqlite")
        let rootDatabase = codexHome.appendingPathComponent("state_5.sqlite")
        let nestedDatabase = nestedDirectory.appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        try makeStateDatabase(at: nestedDatabase, latestUpdate: 1_000)
        try makeStateDatabase(at: rootDatabase, latestUpdate: 2_000)

        XCTAssertEqual(
            CodexActivityMonitor.stateDatabaseURL(in: codexHome),
            rootDatabase,
            "A stale nested database must not mask the root database Codex is actively writing."
        )
    }

    func testMCPComputerUseKeepsScreenPhaseAfterTokenCount() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-codex-home-\(UUID().uuidString)")
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        let rollout = codexHome.appendingPathComponent("rollout.jsonl")
        let now = Date()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let lines = [
            mcpEvent(server: "node_repl", tool: "js"),
            tokenCountEvent(),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        try makeActivityStateDatabase(at: database, rollout: rollout, updatedAt: now)

        let states = CodexActivityMonitor(codexHome: codexHome).activeThreadStates(now: now, limit: 1)
        guard let entry = states.first,
              case let .active(activity) = entry.state
        else {
            return XCTFail("Expected the recent MCP rollout to resolve as active.")
        }

        XCTAssertEqual(activity.phase, .usingScreen)
        XCTAssertEqual(activity.conversationTitle, "Improve activity capsule")
        XCTAssertNil(activity.goalObjective)
        XCTAssertEqual(activity.displayTitle, "Improve activity capsule")
        XCTAssertEqual(activity.currentContextTokens, 184_000)
        XCTAssertEqual(activity.conversationTokens, 789_000_000)
    }

    func testActiveGoalObjectiveTakesPriorityOverItsConversationTitle() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibar-goal-title-\(UUID().uuidString)")
        let database = codexHome.appendingPathComponent("state_5.sqlite")
        let rollout = codexHome.appendingPathComponent("rollout.jsonl")
        let now = Date()
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let lines = [
            goalEvent(
                status: "active",
                timeUsedSeconds: 60,
                updatedAt: Int(now.timeIntervalSince1970),
                objective: "  Rebuild\n the   plan display  "
            ),
            event(type: "task_started", startedAt: Int(now.timeIntervalSince1970)),
            tokenCountEvent(),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout)
        try makeActivityStateDatabase(
            at: database,
            rollout: rollout,
            updatedAt: now,
            title: "Conversation fallback title"
        )

        let states = CodexActivityMonitor(codexHome: codexHome).activeThreadStates(now: now, limit: 1)
        guard let entry = states.first,
              case let .active(activity) = entry.state
        else {
            return XCTFail("Expected the active Goal conversation.")
        }

        XCTAssertEqual(activity.conversationTitle, "Conversation fallback title")
        XCTAssertEqual(activity.goalObjective, "Rebuild the plan display")
        XCTAssertEqual(activity.displayTitle, "Rebuild the plan display")
        XCTAssertEqual(entry.key, activity.threadID)
    }

    func testLiveActivityWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["AIBAR_LIVE_CODEX_ACTIVITY_TEST"] == "1" else {
            throw XCTSkip("Set AIBAR_LIVE_CODEX_ACTIVITY_TEST=1 to inspect the local Codex activity index")
        }

        let states = CodexActivityMonitor().activeThreadStates()
        XCTAssertTrue(
            states.contains { entry in
                if case .active = entry.state { return true }
                return false
            },
            "Expected a currently active Codex thread in the local state index."
        )
    }

    @MainActor
    func testLiveCapsuleReceivesActivityWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AIBAR_LIVE_CODEX_ACTIVITY_TEST"] == "1" else {
            throw XCTSkip("Set AIBAR_LIVE_CODEX_ACTIVITY_TEST=1 to exercise the live activity capsule")
        }

        let controller = ActivityStatusBarController()
        try await Task.sleep(for: .seconds(7))

        XCTAssertFalse(
            controller.rows.isEmpty,
            "The capsule should receive the active thread found in Codex's local state index."
        )
    }

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

    private func goalEvent(
        status: String,
        timeUsedSeconds: Int,
        updatedAt: Int,
        objective: String? = nil
    ) -> String {
        var goal: [String: Any] = [
            "status": status,
            "timeUsedSeconds": timeUsedSeconds,
            "updatedAt": updatedAt,
        ]
        if let objective { goal["objective"] = objective }
        let object: [String: Any] = [
            "timestamp": "2026-07-31T06:01:19Z",
            "type": "event_msg",
            "payload": [
                "type": "thread_goal_updated",
                "goal": goal,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func mcpEvent(server: String, tool: String) -> String {
        let object: [String: Any] = [
            "timestamp": "2026-08-02T15:00:00Z",
            "type": "event_msg",
            "payload": [
                "type": "mcp_tool_call_end",
                "invocation": ["server": server, "tool": tool],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func tokenCountEvent() -> String {
        let object: [String: Any] = [
            "timestamp": "2026-08-02T15:00:01Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": ["total_tokens": 184_000],
                    "total_token_usage": ["total_tokens": 789_000_000],
                ],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeStateDatabase(at url: URL, latestUpdate: Int64) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "CodexActivityMonitorTests", code: 1)
        }
        defer { sqlite3_close(database) }

        let schema = "CREATE TABLE threads (updated_at INTEGER NOT NULL, archived INTEGER NOT NULL)"
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "INSERT INTO threads (updated_at, archived) VALUES (\(latestUpdate), 0)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }

    private func makeActivityStateDatabase(
        at url: URL,
        rollout: URL,
        updatedAt: Date,
        title: String = "Improve activity capsule"
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "CodexActivityMonitorTests", code: 2)
        }
        defer { sqlite3_close(database) }

        let schema = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            cwd TEXT NOT NULL,
            model TEXT,
            tokens_used INTEGER NOT NULL,
            sandbox_policy TEXT NOT NULL,
            approval_mode TEXT NOT NULL,
            thread_source TEXT,
            title TEXT NOT NULL,
            archived INTEGER NOT NULL
        );
        CREATE TABLE thread_spawn_edges (
            parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)

        let timestamp = Int64(nowMilliseconds(updatedAt))
        let query = """
        INSERT INTO threads (
            id, rollout_path, created_at_ms, updated_at_ms, updated_at, cwd,
            model, tokens_used, sandbox_policy, approval_mode, thread_source, title, archived
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, query, -1, &statement, nil), SQLITE_OK)
        guard let statement else {
            throw NSError(domain: "CodexActivityMonitorTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, "thread", -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, rollout.path, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 3, timestamp)
        sqlite3_bind_int64(statement, 4, timestamp)
        sqlite3_bind_int64(statement, 5, timestamp / 1_000)
        sqlite3_bind_text(statement, 6, "/tmp/aibar", -1, sqliteTransient)
        sqlite3_bind_text(statement, 7, "gpt-5.6", -1, sqliteTransient)
        sqlite3_bind_int64(statement, 8, 42)
        sqlite3_bind_text(statement, 9, "workspace-write", -1, sqliteTransient)
        sqlite3_bind_text(statement, 10, "on-request", -1, sqliteTransient)
        sqlite3_bind_text(statement, 11, "user", -1, sqliteTransient)
        sqlite3_bind_text(statement, 12, title, -1, sqliteTransient)
        sqlite3_bind_int(statement, 13, 0)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func nowMilliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1_000
    }
}
