import XCTest
@testable import aibar

final class TraeCNUsageScannerTests: XCTestCase {
    func testScanReturnsExplicitNoDataPayloadRatherThanFabricatedNumbers() {
        let payload = TraeCNUsageScanner.scan(lang: .en)

        XCTAssertEqual(payload.plan, "Trae CN")
        XCTAssertNotNil(payload.error)
        XCTAssertEqual(payload.monthTokens, 0)
        XCTAssertEqual(payload.monthCost, 0)
        XCTAssertTrue(payload.models.isEmpty)
        XCTAssertTrue(payload.topProjects.isEmpty)
    }

    func testScanFillsExactlyThirtyDaysEndingToday() {
        let payload = TraeCNUsageScanner.scan(lang: .zh)

        XCTAssertEqual(payload.daily.count, 30)
        XCTAssertTrue(payload.daily.allSatisfy { $0.tokens == 0 && $0.cost == 0 })
        XCTAssertEqual(payload.daily.last?.date, UsageAggregation.isoDateOnly(Date()))
    }

    func testScanErrorMessageMatchesRequestedLanguage() {
        XCTAssertEqual(TraeCNUsageScanner.scan(lang: .en).error, L.traeCNNoData(.en))
        XCTAssertEqual(TraeCNUsageScanner.scan(lang: .zh).error, L.traeCNNoData(.zh))
        XCTAssertNotEqual(TraeCNUsageScanner.scan(lang: .en).error, TraeCNUsageScanner.scan(lang: .zh).error)
    }
}
