import Foundation
import XCTest
@testable import aibar

final class CodexAppServerUsageTests: XCTestCase {
    func testLiveAccountWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AIBAR_LIVE_CODEX_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set AIBAR_LIVE_CODEX_USAGE_TEST=1 to exercise the signed-in Codex account")
        }
        let result = await CodexAppServerUsage.fetchAccountMetadata()
        let usage = try XCTUnwrap(result?.tokenUsage)
        let payload = UsageScanner().scan(
            prices: PricingService.fallbackPrices,
            priceStatus: "fallback",
            accountUsage: usage
        )

        for point in payload.daily {
            XCTAssertEqual(point.tokens, usage.dailyTokens[point.date] ?? 0)
        }
        XCTAssertEqual(payload.models.reduce(0) { $0 + $1.tokens }, payload.monthTokens)
        XCTAssertEqual(
            payload.models.reduce(0) { $0 + $1.apiEquivalentCost },
            payload.monthCost,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            payload.daily.suffix(30).reduce(0) { $0 + $1.cost },
            payload.monthCost,
            accuracy: 0.000_001
        )
        for project in payload.topProjects {
            XCTAssertEqual(project.models.reduce(0) { $0 + $1.tokens }, project.tokens)
            XCTAssertEqual(
                project.models.reduce(0) { $0 + $1.apiEquivalentCost },
                project.apiEquivalentCost,
                accuracy: 0.000_001
            )
        }
    }

    func testParsesAvailableCountAndAllAvailableExpiries() throws {
        let data = Data(#"{"id":2,"result":{"rateLimitResetCredits":{"availableCount":3,"credits":[{"status":"available","expiresAt":1786555607},{"status":"redeemed","expiresAt":100},{"status":"available","expiresAt":1786000000}]}}}"#.utf8)

        let result = CodexAppServerUsage.parseResetCreditsResponse(data)

        XCTAssertEqual(result?.availableCount, 3)
        XCTAssertEqual(result?.expiresAt, [1_786_000_000, 1_786_555_607])
    }

    func testSupportsCountOnlyResponse() throws {
        let data = Data(#"{"id":2,"result":{"rateLimitResetCredits":{"availableCount":2,"credits":null}}}"#.utf8)

        let result = CodexAppServerUsage.parseResetCreditsResponse(data)

        XCTAssertEqual(result, RateLimitResetCredits(availableCount: 2, expiresAt: []))
    }

    func testReturnsNilWhenBackendDoesNotExposeResetCredits() throws {
        let data = Data(#"{"id":2,"result":{"rateLimits":{}}}"#.utf8)
        XCTAssertNil(CodexAppServerUsage.parseResetCreditsResponse(data))
    }

    func testIgnoresAnotherRPCResponse() throws {
        let data = Data(#"{"id":99,"result":{"rateLimitResetCredits":{"availableCount":1}}}"#.utf8)
        XCTAssertNil(CodexAppServerUsage.parseResetCreditsResponse(data))
    }

    func testParsesOfficialDailyTokenUsage() throws {
        let data = Data(#"{"id":3,"result":{"summary":{"lifetimeTokens":1234567890,"peakDailyTokens":857700000},"dailyUsageBuckets":[{"startDate":"2026-07-17","tokens":857700000},{"startDate":"2026-07-18","tokens":42}]}}"#.utf8)

        let result = CodexAppServerUsage.parseAccountUsageResponse(data)

        XCTAssertEqual(result?.dailyTokens["2026-07-17"], 857_700_000)
        XCTAssertEqual(result?.dailyTokens["2026-07-18"], 42)
        XCTAssertEqual(result?.lifetimeTokens, 1_234_567_890)
        XCTAssertEqual(result?.peakDailyTokens, 857_700_000)
    }

    func testOfficialUsageParserCombinesDuplicateBucketsAndClampsNegatives() throws {
        let data = Data(#"{"id":3,"result":{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-07-17","tokens":10},{"startDate":"2026-07-17","tokens":7},{"startDate":"2026-07-18","tokens":-5}]}}"#.utf8)

        let result = CodexAppServerUsage.parseAccountUsageResponse(data)

        XCTAssertEqual(result?.dailyTokens, ["2026-07-17": 17, "2026-07-18": 0])
    }
}
