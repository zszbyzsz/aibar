import Foundation
import XCTest
@testable import aibar

final class UsageTimelineTests: XCTestCase {
    func testHeatmapInterpolatesContinuouslyBetweenStableTokenAnchors() {
        XCTAssertEqual(UsageHeatmapScale.position(for: 0), 0)
        XCTAssertEqual(UsageHeatmapScale.position(for: 100_000_000), 0.25)
        XCTAssertEqual(UsageHeatmapScale.position(for: 500_000_000), 0.5)
        XCTAssertEqual(UsageHeatmapScale.position(for: 1_000_000_000), 0.75)
        XCTAssertEqual(UsageHeatmapScale.position(for: 5_000_000_000), 1)
        XCTAssertEqual(UsageHeatmapScale.position(for: 8_000_000_000), 1)

        let betweenAnchors = UsageHeatmapScale.position(for: 300_000_000)
        XCTAssertGreaterThan(betweenAnchors, 0.25)
        XCTAssertLessThan(betweenAnchors, 0.5)
    }

    func testHeatmapLegendSamplesTheFullContinuousScale() {
        XCTAssertEqual(UsageHeatmapScale.legendPositions, [0, 0.25, 0.5, 0.75, 1])
    }

    func testUsageMilestonesUseInclusiveOneFiveAndTenBillionThresholds() {
        XCTAssertEqual(UsageMilestone.level(for: 999_999_999), .none)
        XCTAssertEqual(UsageMilestone.level(for: 1_000_000_000), .billion)
        XCTAssertEqual(UsageMilestone.level(for: 4_999_999_999), .billion)
        XCTAssertEqual(UsageMilestone.level(for: 5_000_000_000), .fiveBillion)
        XCTAssertEqual(UsageMilestone.level(for: 9_999_999_999), .fiveBillion)
        XCTAssertEqual(UsageMilestone.level(for: 10_000_000_000), .tenBillion)
    }

    func testUsageMilestonesMapToDotSparkleAndPulsarCore() {
        XCTAssertEqual(UsageMilestone.none.adornment, .none)
        XCTAssertEqual(UsageMilestone.billion.adornment, .dot)
        XCTAssertEqual(UsageMilestone.fiveBillion.adornment, .sparkle)
        XCTAssertEqual(UsageMilestone.tenBillion.adornment, .pulsarCore)
    }

    func testTenBillionMilestoneStaysOutOfTheVisibleLegend() {
        XCTAssertEqual(UsageMilestone.visibleLegendTiers, [.billion, .fiveBillion])
        XCTAssertFalse(UsageMilestone.visibleLegendTiers.contains(.tenBillion))
    }

    func testTimelineMarkerLegendUsesEndAndWeeklyRefreshLabels() {
        XCTAssertEqual(L.subscriptionEndLegend(.zh), "结束")
        XCTAssertEqual(L.weeklyRefreshLegend(.zh), "周刷新")
        XCTAssertEqual(L.subscriptionEndLegend(.en), "End")
        XCTAssertEqual(L.weeklyRefreshLegend(.en), "Weekly reset")
    }

    func testResetLegendAndTenDayCountdownRemainUnchanged() {
        XCTAssertEqual(L.resetExpiryLegend(.zh), "重置 >10天")
        XCTAssertEqual(L.resetExpiryUrgentLegend(.zh), "重置 ≤10天")
        XCTAssertEqual(L.resetExpiryLegend(.en), "Reset >10d")
        XCTAssertEqual(L.resetExpiryUrgentLegend(.en), "Reset ≤10d")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        DateComponents(
            calendar: utcCalendar,
            timeZone: utcCalendar.timeZone,
            year: year, month: month, day: day, hour: hour
        ).date!
    }

    func testTimelineUsesTwentyTwoCompleteWeeksAroundFurthestAccountBoundary() {
        let weeklyReset = date(2026, 8, 4, hour: 1).timeIntervalSince1970
        let subscriptionEnd = date(2026, 8, 13, hour: 18)
        let timeline = UsageTimeline(
            daily: [],
            resetCredits: RateLimitResetCredits(
                availableCount: 2,
                expiresAt: [date(2026, 8, 8).timeIntervalSince1970, date(2026, 8, 16).timeIntervalSince1970]
            ),
            weeklyResetAt: weeklyReset,
            subscriptionEndsAt: subscriptionEnd,
            now: date(2026, 7, 31),
            calendar: utcCalendar
        )

        XCTAssertEqual(timeline.points.count, 154)
        XCTAssertEqual(timeline.points.first?.date, "2026-03-16")
        XCTAssertEqual(timeline.points.last?.date, "2026-08-16")
        XCTAssertEqual(timeline.todayKey, "2026-07-31")
        XCTAssertEqual(timeline.weeklyResetKey, "2026-08-04")
        XCTAssertEqual(timeline.subscriptionEndKey, "2026-08-13")
        XCTAssertEqual(timeline.resetExpiriesByDate.count, 2)
    }

    func testTimelineEndsTodayWhenThereAreNoAccountBoundaries() {
        let timeline = UsageTimeline(
            daily: [],
            resetCredits: nil,
            weeklyResetAt: nil,
            subscriptionEndsAt: nil,
            now: date(2026, 7, 31),
            calendar: utcCalendar
        )

        XCTAssertEqual(timeline.points.count, 154)
        XCTAssertEqual(timeline.points.first?.date, "2026-03-02")
        XCTAssertEqual(timeline.points.last?.date, "2026-08-02")
        XCTAssertNil(timeline.weeklyResetKey)
        XCTAssertNil(timeline.subscriptionEndKey)
        XCTAssertTrue(timeline.resetExpiriesByDate.isEmpty)
    }

    func testTimelinePreservesUsageAndKeepsOneMarkerOfEachKind() {
        let boundary = date(2026, 8, 13, hour: 18)
        let timeline = UsageTimeline(
            daily: [DailyPoint(date: "2026-07-31", tokens: 42_000, cost: 1.25)],
            resetCredits: RateLimitResetCredits(
                availableCount: 3,
                expiresAt: [
                    date(2026, 8, 6, hour: 1).timeIntervalSince1970,
                    date(2026, 8, 13, hour: 1).timeIntervalSince1970,
                    date(2026, 8, 13, hour: 18).timeIntervalSince1970,
                ]
            ),
            weeklyResetAt: boundary.timeIntervalSince1970,
            subscriptionEndsAt: boundary,
            now: date(2026, 7, 31),
            calendar: utcCalendar
        )

        let today = timeline.points.first { $0.date == "2026-07-31" }
        XCTAssertEqual(today?.tokens, 42_000)
        XCTAssertEqual(today?.cost, 1.25)
        XCTAssertEqual(timeline.weeklyResetKey, "2026-08-13")
        XCTAssertEqual(timeline.subscriptionEndKey, "2026-08-13")
        XCTAssertEqual(timeline.resetExpiriesByDate["2026-08-06"]?.count, 1)
        XCTAssertEqual(timeline.resetExpiriesByDate["2026-08-13"]?.count, 2)
    }

    func testResetExpiryUrgencyUsesAnExactTenDayWindow() {
        let now = date(2026, 7, 31)
        let inTenDays = now.addingTimeInterval(10 * 86_400).timeIntervalSince1970
        let justBeyondTenDays = now.addingTimeInterval(10 * 86_400 + 1).timeIntervalSince1970

        XCTAssertTrue(ResetExpiryUrgency.isDetailed(inTenDays, now: now))
        XCTAssertFalse(ResetExpiryUrgency.isDetailed(justBeyondTenDays, now: now))
        XCTAssertEqual(ResetExpiryUrgency.daysRemaining(inTenDays, now: now), 10)
        XCTAssertEqual(L.resetExpiryWithinDays(.en, days: 10), "Expires in 10d")
    }
}
