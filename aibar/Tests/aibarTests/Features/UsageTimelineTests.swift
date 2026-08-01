import Foundation
import XCTest
@testable import aibar

final class UsageTimelineTests: XCTestCase {
    func testHeatmapIntensityIsDrivenByTokensAndMonotonicallyIncreases() {
        let maximum = 900_000_000
        let empty = UsageHeatmapIntensity.ratio(tokens: 0, maximum: maximum)
        let small = UsageHeatmapIntensity.ratio(tokens: 9_000_000, maximum: maximum)
        let medium = UsageHeatmapIntensity.ratio(tokens: 225_000_000, maximum: maximum)
        let peak = UsageHeatmapIntensity.ratio(tokens: maximum, maximum: maximum)

        XCTAssertEqual(empty, 0)
        XCTAssertLessThan(empty, small)
        XCTAssertLessThan(small, medium)
        XCTAssertLessThan(medium, peak)
        XCTAssertEqual(peak, 1)
    }

    func testHeatmapIntensityClampsValuesAboveMaximum() {
        XCTAssertEqual(UsageHeatmapIntensity.ratio(tokens: 200, maximum: 100), 1)
        XCTAssertEqual(UsageHeatmapIntensity.ratio(tokens: 100, maximum: 0), 0)
    }

    func testUsageMilestonesUseInclusiveOneFiveAndTenBillionThresholds() {
        XCTAssertEqual(UsageMilestone.level(for: 999_999_999), .none)
        XCTAssertEqual(UsageMilestone.level(for: 1_000_000_000), .billion)
        XCTAssertEqual(UsageMilestone.level(for: 4_999_999_999), .billion)
        XCTAssertEqual(UsageMilestone.level(for: 5_000_000_000), .fiveBillion)
        XCTAssertEqual(UsageMilestone.level(for: 9_999_999_999), .fiveBillion)
        XCTAssertEqual(UsageMilestone.level(for: 10_000_000_000), .tenBillion)
    }

    func testConsecutiveMilestonesShareOneFrameUsingTheStrongestTier() {
        let week: [DailyPoint?] = [
            nil,
            DailyPoint(date: "2026-07-27", tokens: 1_200_000_000, cost: 0),
            DailyPoint(date: "2026-07-28", tokens: 5_400_000_000, cost: 0),
            DailyPoint(date: "2026-07-29", tokens: 10_730_000_000, cost: 0),
            DailyPoint(date: "2026-07-30", tokens: 0, cost: 0),
            DailyPoint(date: "2026-07-31", tokens: 1_100_000_000, cost: 0),
            nil,
        ]

        XCTAssertEqual(
            UsageMilestoneGrouping.runs(in: week),
            [
                UsageMilestoneRun(startRow: 1, endRow: 3, milestone: .tenBillion),
                UsageMilestoneRun(startRow: 5, endRow: 5, milestone: .billion),
            ]
        )
    }

    func testCompactResetLegendCopyRetainsTheTenDayBoundary() {
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

    func testTimelineEndsAtFurthestResetExpiryAndLooksBackNinetyDays() {
        let expiry = date(2026, 8, 13, hour: 1).timeIntervalSince1970
        let timeline = UsageTimeline(
            daily: [],
            resetCredits: RateLimitResetCredits(availableCount: 1, expiresAt: [expiry]),
            now: date(2026, 7, 31),
            calendar: utcCalendar
        )

        XCTAssertEqual(timeline.points.count, 90)
        XCTAssertEqual(timeline.points.first?.date, "2026-05-16")
        XCTAssertEqual(timeline.points.last?.date, "2026-08-13")
        XCTAssertEqual(timeline.todayKey, "2026-07-31")
        XCTAssertEqual(timeline.resetExpiriesByDate["2026-08-13"], [expiry])
    }

    func testTimelineEndsTodayWhenThereIsNoDatedReset() {
        let timeline = UsageTimeline(
            daily: [],
            resetCredits: RateLimitResetCredits(availableCount: 2, expiresAt: []),
            now: date(2026, 7, 31),
            calendar: utcCalendar
        )

        XCTAssertEqual(timeline.points.count, 90)
        XCTAssertEqual(timeline.points.last?.date, "2026-07-31")
    }

    func testTimelinePreservesUsageAndGroupsResetsOnTheSameDay() {
        let first = date(2026, 8, 13, hour: 1).timeIntervalSince1970
        let second = date(2026, 8, 13, hour: 18).timeIntervalSince1970
        let timeline = UsageTimeline(
            daily: [DailyPoint(date: "2026-07-31", tokens: 42_000, cost: 1.25)],
            resetCredits: RateLimitResetCredits(availableCount: 2, expiresAt: [second, first]),
            now: date(2026, 7, 31),
            calendar: utcCalendar
        )

        let today = timeline.points.first { $0.date == "2026-07-31" }
        XCTAssertEqual(today?.tokens, 42_000)
        XCTAssertEqual(today?.cost, 1.25)
        XCTAssertEqual(timeline.resetExpiriesByDate["2026-08-13"], [first, second])
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
