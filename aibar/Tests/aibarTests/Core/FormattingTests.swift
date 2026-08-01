import XCTest
@testable import aibar

final class FormattingTests: XCTestCase {
    func testTokenLabelsUseReadableUnits() {
        XCTAssertEqual(Formatting.tokenLabel(999), "999")
        XCTAssertEqual(Formatting.tokenLabel(1_000), "1K")
        XCTAssertEqual(Formatting.tokenLabel(1_250_000), "1.2M")
        XCTAssertEqual(Formatting.tokenLabel(2_000_000_000), "2.00B")
    }

    func testFourSignificantTokenLabelUsesAdaptiveUnits() {
        XCTAssertEqual(Formatting.fourSignificantTokenLabel(1_303_000_000), "1.303B")
        XCTAssertEqual(Formatting.fourSignificantTokenLabel(1_353_000), "1.353M")
        XCTAssertEqual(Formatting.fourSignificantTokenLabel(1_353_000 / 30), "45.10K")
        XCTAssertEqual(Formatting.fourSignificantTokenLabel(0), "0")
    }

    func testParsesISO8601TimestampsWithAndWithoutFractions() {
        XCTAssertNotNil(Formatting.parseISODate("2026-07-24T12:30:45Z"))
        XCTAssertNotNil(Formatting.parseISODate("2026-07-24T12:30:45.123Z"))
        XCTAssertNil(Formatting.parseISODate("not-a-date"))
    }

    func testEnglishResetLabels() {
        XCTAssertEqual(Formatting.resetLabel(nil, lang: .en), "No local record yet")
        XCTAssertEqual(Formatting.resetLabel(Date().addingTimeInterval(-60).timeIntervalSince1970, lang: .en), "Waiting for sync")
    }

    /// Asserts on bucket shape (minutes-only vs hours+minutes vs days+hours)
    /// rather than the exact digit: `resetLabel` re-derives "remaining time"
    /// from a fresh `Date()` internally, so pinning an exact minute here would
    /// make the test flaky against any scheduling jitter between when the
    /// test computes `resetsAt` and when the function reads "now".
    func testResetLabelPicksMinutesHoursOrDaysBucketByRemainingTime() {
        let minutesOnly = Formatting.resetLabel(Date().addingTimeInterval(5 * 60).timeIntervalSince1970, lang: .en)
        XCTAssertTrue(minutesOnly.hasPrefix("resets in "))
        XCTAssertTrue(minutesOnly.hasSuffix("m"))
        XCTAssertFalse(minutesOnly.contains("h"))

        let hoursAndMinutes = Formatting.resetLabel(Date().addingTimeInterval(90 * 60).timeIntervalSince1970, lang: .en)
        XCTAssertTrue(hoursAndMinutes.contains("h") && hoursAndMinutes.hasSuffix("m"))
        XCTAssertFalse(hoursAndMinutes.contains("d"))

        let daysAndHours = Formatting.resetLabel(Date().addingTimeInterval(25 * 3600).timeIntervalSince1970, lang: .en)
        XCTAssertTrue(daysAndHours.contains("d") && daysAndHours.hasSuffix("h"))
    }

    func testChineseResetLabels() {
        XCTAssertEqual(Formatting.resetLabel(nil, lang: .zh), "暂无本地记录")
        let label = Formatting.resetLabel(Date().addingTimeInterval(90 * 60).timeIntervalSince1970, lang: .zh)
        XCTAssertTrue(label.hasSuffix("后重置"))
        XCTAssertTrue(label.contains("h") && label.contains("m"))
    }

    func testHoursAndMinutesSplitsElapsedSecondsAndClampsNegatives() {
        XCTAssertEqual(Formatting.hoursAndMinutes(fromSeconds: 3_661).hours, 1)
        XCTAssertEqual(Formatting.hoursAndMinutes(fromSeconds: 3_661).minutes, 1)
        XCTAssertEqual(Formatting.hoursAndMinutes(fromSeconds: 59).hours, 0)
        XCTAssertEqual(Formatting.hoursAndMinutes(fromSeconds: 59).minutes, 0)
        XCTAssertEqual(Formatting.hoursAndMinutes(fromSeconds: -100).hours, 0)
        XCTAssertEqual(Formatting.hoursAndMinutes(fromSeconds: -100).minutes, 0)
    }

    func testCompactResetExpiryTimeUsesStableShape() {
        let utc = TimeZone(secondsFromGMT: 0)!
        // 2026-08-13 01:26:00 UTC
        let expiry = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: utc,
            year: 2026, month: 8, day: 13, hour: 1, minute: 26
        ).date!.timeIntervalSince1970

        XCTAssertEqual(Formatting.compactTimeLabel(expiry, timeZone: utc), "01:26")
    }

    func testMoneyLabelFormatsAsTwoDecimalUSD() {
        // The currency symbol/placement follows the run's locale (e.g. "$12.30"
        // vs "US$12.30"), so assert on the numeric content rather than the
        // full string.
        XCTAssertTrue(Formatting.moneyLabel(12.3).contains("12.30"))
        XCTAssertTrue(Formatting.moneyLabel(0).contains("0.00"))
        XCTAssertTrue(Formatting.moneyLabel(1_234.567).contains("1,234.57"))
    }

    func testIsoTimestampRoundTripsThroughParseISODate() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let roundTripped = Formatting.parseISODate(Formatting.isoTimestamp(from: date))
        XCTAssertEqual(roundTripped?.timeIntervalSince1970 ?? -1, date.timeIntervalSince1970, accuracy: 0.001)
    }
}
