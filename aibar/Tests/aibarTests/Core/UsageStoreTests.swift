import XCTest
@testable import aibar

@MainActor
final class UsageStoreTests: XCTestCase {
    func testBackgroundRefreshRunsHourly() {
        XCTAssertEqual(UsageStore.refreshInterval, 60 * 60)
    }
}
