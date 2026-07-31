import Foundation
import XCTest
@testable import aibar

final class CodexAppServerUsageTests: XCTestCase {
    func testLiveAccountWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AIBAR_LIVE_CODEX_USAGE_TEST"] == "1" else {
            throw XCTSkip("Set AIBAR_LIVE_CODEX_USAGE_TEST=1 to exercise the signed-in Codex account")
        }
        let result = await CodexAppServerUsage.fetchResetCredits()
        XCTAssertNotNil(result)
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
}
