import XCTest
@testable import aibar

final class PricingServiceTests: XCTestCase {
    func testGPT56FallbackRatesUseCurrentAPIPricingAndCacheWritePremium() {
        let sol = PricingService.fallbackPrices["gpt-5.6-sol"]
        XCTAssertEqual(sol?.input, 5)
        XCTAssertEqual(sol?.cachedInput, 0.5)
        XCTAssertEqual(sol?.output, 30)
        XCTAssertEqual(sol?.cacheWrite, 6.25)

        let terra = PricingService.fallbackPrices["gpt-5.6-terra"]
        XCTAssertEqual(terra?.input, 2.5)
        XCTAssertEqual(terra?.cachedInput, 0.25)
        XCTAssertEqual(terra?.output, 15)
        XCTAssertEqual(terra?.cacheWrite, 3.125)

        let luna = PricingService.fallbackPrices["gpt-5.6-luna"]
        XCTAssertEqual(luna?.input, 1)
        XCTAssertEqual(luna?.cachedInput, 0.1)
        XCTAssertEqual(luna?.output, 6)
        XCTAssertEqual(luna?.cacheWrite, 1.25)
    }
}
