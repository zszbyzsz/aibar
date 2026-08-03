import XCTest
@testable import aibar

final class ActivityCapsulePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    func testCompletionIsAnnouncedFirstThenRetainedAfterRunningRows() {
        let running = [activeRow(key: "running")]
        let completed = completion(key: "done", secondsAgo: 5)

        let announcing = ActivityCapsulePolicy.rows(
            running: running,
            announcement: completed,
            retained: [completed]
        )
        XCTAssertEqual(announcing.map(\.id), ["completed-done", "active-running"])

        let retained = ActivityCapsulePolicy.rows(
            running: running,
            announcement: nil,
            retained: [completed]
        )
        XCTAssertEqual(retained.map(\.id), ["active-running", "completed-done"])
    }

    func testCompletedRowsRemainForExactlyTwoMinutesWhileProjectsRun() {
        XCTAssertEqual(ActivityCapsulePolicy.completionRetentionDuration, 120)

        let stillVisible = completion(key: "visible", secondsAgo: 119.9)
        let expired = completion(key: "expired", secondsAgo: 120)
        let retained = ActivityCapsulePolicy.retainedCompletions(
            from: [expired, stillVisible],
            now: now,
            hasRunningProjects: true
        )

        XCTAssertEqual(retained.map(\.key), ["visible"])
    }

    func testCompletionShelfIsPreservedWhenAllProjectsFinish() {
        let retained = ActivityCapsulePolicy.retainedCompletions(
            from: [completion(key: "done", secondsAgo: 10)],
            now: now,
            hasRunningProjects: false
        )

        XCTAssertEqual(retained.map(\.key), ["done"])
        XCTAssertEqual(ActivityCapsulePolicy.allCompletedRetentionDuration, 30)
    }

    func testSingleFinalCompletionRemainsDirectlyActionable() {
        let completed = completion(key: "done", secondsAgo: 0)

        let rows = ActivityCapsulePolicy.rows(
            running: [],
            announcement: completed,
            retained: [completed]
        )

        XCTAssertEqual(rows.map(\.id), ["completed-done"])
    }

    func testMultipleFinalCompletionsCollapseIntoSummaryUntilClicked() {
        let first = completion(key: "first", secondsAgo: 10)
        let second = completion(key: "second", secondsAgo: 0)

        let collapsed = ActivityCapsulePolicy.rows(
            running: [],
            announcement: second,
            retained: [first, second]
        )
        XCTAssertEqual(collapsed.map(\.id), ["completion-summary"])
        XCTAssertEqual(collapsed.first?.display, .completionSummary(count: 2))

        let expanded = ActivityCapsulePolicy.rows(
            running: [],
            announcement: nil,
            retained: [first, second],
            completionReviewExpanded: true
        )
        XCTAssertEqual(
            expanded.map(\.id),
            ["completion-summary", "completed-first", "completed-second"]
        )
    }

    func testMultipleCompletionsKeepChronologicalTailOrder() {
        let retained = ActivityCapsulePolicy.retainedCompletions(
            from: [
                completion(key: "latest", secondsAgo: 10),
                completion(key: "earliest", secondsAgo: 30)
            ],
            now: now,
            hasRunningProjects: true
        )

        XCTAssertEqual(retained.map(\.key), ["earliest", "latest"])
    }

    private func completion(key: String, secondsAgo: TimeInterval) -> RetainedCompletion {
        RetainedCompletion(
            key: key,
            project: key,
            outcome: .completed,
            completedAt: now.addingTimeInterval(-secondsAgo)
        )
    }

    private func activeRow(key: String) -> CapsuleRow {
        CapsuleRow(
            id: "active-\(key)",
            threadID: key,
            display: .active(ProjectActivity(
                project: key,
                conversationTitle: key,
                goalObjective: nil,
                model: nil,
                phase: .working,
                lastActivityAt: now,
                startedAt: now,
                currentContextTokens: 0,
                conversationTokens: 0,
                sandboxPolicy: "",
                approvalMode: "",
                threadID: key
            ))
        )
    }
}
