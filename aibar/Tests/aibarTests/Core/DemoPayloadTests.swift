import XCTest
@testable import aibar

@MainActor
final class DemoPayloadTests: XCTestCase {
    func testDemoPayloadKeepsDashboardTotalsInternallyConsistent() {
        let payload = UsageStore.demoPayload()
        let lastThirtyDays = payload.daily.suffix(30)

        XCTAssertEqual(payload.monthTokens, lastThirtyDays.reduce(0) { $0 + $1.tokens })
        XCTAssertEqual(
            payload.monthCost,
            lastThirtyDays.reduce(0) { $0 + $1.cost },
            accuracy: 0.001
        )
        XCTAssertEqual(payload.monthTokens, payload.models.reduce(0) { $0 + $1.tokens })
        XCTAssertEqual(
            payload.monthCost,
            payload.models.reduce(0) { $0 + $1.apiEquivalentCost },
            accuracy: 0.001
        )
    }

    func testDemoPayloadExercisesCurrentHeatmapAndGoalStates() {
        let payload = UsageStore.demoPayload()

        XCTAssertTrue(payload.daily.contains { $0.tokens >= UsageMilestone.billionThreshold })
        XCTAssertTrue(payload.daily.contains { $0.tokens >= UsageMilestone.onePointFiveBillionThreshold })
        XCTAssertTrue(payload.daily.contains { $0.tokens >= UsageMilestone.fiveBillionThreshold })

        guard let activity = payload.activeProject else {
            return XCTFail("Demo payload should include active Goal activity")
        }
        switch activity.timingScope {
        case .continuousGoal:
            break
        case .currentTurn:
            XCTFail("Demo activity should exercise the continuous Goal presentation")
        }
    }
}
