import XCTest
@testable import aibar

@MainActor
final class UsageStoreTests: XCTestCase {
    func testBackgroundRefreshRunsHourly() {
        XCTAssertEqual(UsageStore.refreshInterval, 60 * 60)
    }

    func testHourlyRefreshTargetsTheNextWallClockHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let current = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 14, minute: 37, second: 12
        )))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 15, minute: 0, second: 0
        )))

        XCTAssertEqual(
            UsageStore.nextHourlyRefreshDate(after: current, calendar: calendar),
            expected
        )
    }

    func testHourlyRefreshMovesPastAnExactHourBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let boundary = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 15, minute: 0, second: 0
        )))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 16, minute: 0, second: 0
        )))

        XCTAssertEqual(
            UsageStore.nextHourlyRefreshDate(after: boundary, calendar: calendar),
            expected
        )
    }
}
