import Foundation
import XCTest
@testable import aibar

final class UsageTimelineTests: XCTestCase {
    func testHeatmapUsesStableAbsoluteTokenBands() {
        XCTAssertEqual(UsageHeatmapLevel.level(for: 0), .none)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 1), .low)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 99_999_999), .low)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 100_000_000), .moderate)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 499_999_999), .moderate)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 500_000_000), .elevated)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 999_999_999), .elevated)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 1_000_000_000), .high)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 4_999_999_999), .high)
        XCTAssertEqual(UsageHeatmapLevel.level(for: 5_000_000_000), .peak)
    }

    func testHeatmapLegendShowsEveryActiveColorBand() {
        XCTAssertEqual(
            UsageHeatmapLevel.visibleLegendLevels,
            [.low, .moderate, .elevated, .high, .peak]
        )
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
