import XCTest
@testable import aibar

final class PricingServiceTests: XCTestCase {
    func testColdStartPricesReturnFallbackWithoutNetwork() async {
        let service = PricingService()

        let result = await service.cachedOrFallbackPrices()

        XCTAssertEqual(result.status, "fallback")
        XCTAssertEqual(result.models["gpt-5.6-sol"]?.input, 5)
        XCTAssertEqual(result.models.count, PricingService.modelPages.count)
    }

    func testGPT56FallbackRatesUseCurrentAPIPricingAndCacheWritePremium() {
        let sol = PricingService.fallbackPrices["gpt-5.6-sol"]
        XCTAssertEqual(sol?.input, 5)
        XCTAssertEqual(sol?.cachedInput, 0.5)
        XCTAssertEqual(sol?.output, 30)
        XCTAssertEqual(sol?.cacheWrite, 6.25)
        XCTAssertEqual(sol?.longContextThreshold, 272_000)
        XCTAssertEqual(sol?.longInputMultiplier, 2)
        XCTAssertEqual(sol?.longCachedInputMultiplier, 2)
        XCTAssertEqual(sol?.longCacheWriteMultiplier, 2)
        XCTAssertEqual(sol?.longOutputMultiplier, 1.5)

        let terra = PricingService.fallbackPrices["gpt-5.6-terra"]
        XCTAssertEqual(terra?.input, 2)
        XCTAssertEqual(terra?.cachedInput, 0.2)
        XCTAssertEqual(terra?.output, 12)
        XCTAssertEqual(terra?.cacheWrite, 2.5)

        let luna = PricingService.fallbackPrices["gpt-5.6-luna"]
        XCTAssertEqual(luna?.input, 0.2)
        XCTAssertEqual(luna?.cachedInput, 0.02)
        XCTAssertEqual(luna?.output, 1.2)
        XCTAssertEqual(luna?.cacheWrite, 0.25)

        XCTAssertNil(PricingService.fallbackPrices["gpt-5.4-mini"]?.longContextThreshold)
    }
}
