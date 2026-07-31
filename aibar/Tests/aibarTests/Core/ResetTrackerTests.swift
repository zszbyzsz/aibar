import XCTest
@testable import aibar

final class ResetTrackerTests: XCTestCase {
    /// Unique provider per test so parallel/repeated runs never share
    /// UserDefaults state with each other.
    private func freshProvider() -> String { "test-\(UUID().uuidString)" }

    private func cleanUp(provider: String, kind: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "resetTracker.lastDeadline.\(provider).\(kind)")
        defaults.removeObject(forKey: "resetTracker.count.\(provider).\(kind)")
    }

    func testObserveReturnsZeroWithoutIncrementingWhenSeenForTheFirstTime() {
        let provider = freshProvider()
        addTeardownBlock { self.cleanUp(provider: provider, kind: "session") }

        let count = ResetTracker.observe(provider: provider, kind: "session", resetsAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        XCTAssertEqual(count, 0)
    }

    func testObserveIncrementsOnlyWhenThePreviousDeadlineHasActuallyPassed() {
        let provider = freshProvider()
        addTeardownBlock { self.cleanUp(provider: provider, kind: "session") }

        let pastDeadline = Date().addingTimeInterval(-60).timeIntervalSince1970
        _ = ResetTracker.observe(provider: provider, kind: "session", resetsAt: pastDeadline)

        // A new, different deadline observed after the old one already passed
        // means the window genuinely rolled over.
        let newDeadline = Date().addingTimeInterval(3600).timeIntervalSince1970
        let count = ResetTracker.observe(provider: provider, kind: "session", resetsAt: newDeadline)
        XCTAssertEqual(count, 1)

        // Observing the same deadline again must not double-count.
        let countAgain = ResetTracker.observe(provider: provider, kind: "session", resetsAt: newDeadline)
        XCTAssertEqual(countAgain, 1)
    }

    func testObserveDoesNotCountAServerNudgeToAFutureDeadlineMidWindow() {
        let provider = freshProvider()
        addTeardownBlock { self.cleanUp(provider: provider, kind: "session") }

        let futureDeadline = Date().addingTimeInterval(3600).timeIntervalSince1970
        _ = ResetTracker.observe(provider: provider, kind: "session", resetsAt: futureDeadline)

        // The deadline changes but the previous one never actually passed —
        // this must not be treated as a rollover.
        let nudgedDeadline = Date().addingTimeInterval(7200).timeIntervalSince1970
        let count = ResetTracker.observe(provider: provider, kind: "session", resetsAt: nudgedDeadline)
        XCTAssertEqual(count, 0)
    }

    func testObserveWithNilResetsAtReturnsCurrentCountUnchanged() {
        let provider = freshProvider()
        addTeardownBlock { self.cleanUp(provider: provider, kind: "session") }

        let count = ResetTracker.observe(provider: provider, kind: "session", resetsAt: nil)
        XCTAssertEqual(count, 0)
    }
}
