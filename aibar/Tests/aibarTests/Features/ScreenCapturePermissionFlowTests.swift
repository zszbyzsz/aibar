import XCTest
@testable import aibar

final class ScreenCapturePermissionFlowTests: XCTestCase {
    func testFirstMissingPermissionUsesOnlyTheSystemRequest() {
        var flow = ScreenCapturePermissionFlow()
        var requestCount = 0
        let requestAccess = {
            requestCount += 1
            return false
        }

        XCTAssertEqual(
            flow.nextAction(hasAccess: false, requestAccess: requestAccess),
            .awaitPermission
        )
        XCTAssertEqual(
            flow.nextAction(hasAccess: false, requestAccess: requestAccess),
            .showSettings
        )
        XCTAssertEqual(requestCount, 2)
    }

    func testExistingPermissionCapturesWithoutRequestingAgain() {
        var flow = ScreenCapturePermissionFlow()
        var requestCount = 0
        let requestAccess = {
            requestCount += 1
            return false
        }

        XCTAssertEqual(flow.nextAction(hasAccess: true, requestAccess: requestAccess), .capture)
        XCTAssertEqual(flow.nextAction(hasAccess: true, requestAccess: requestAccess), .capture)
        XCTAssertEqual(requestCount, 0)
    }

    func testGrantTakesEffectAfterAnEarlierDenial() {
        var flow = ScreenCapturePermissionFlow()

        XCTAssertEqual(
            flow.nextAction(hasAccess: false, requestAccess: { false }),
            .awaitPermission
        )
        XCTAssertEqual(
            flow.nextAction(hasAccess: false, requestAccess: { true }),
            .capture
        )
    }
}
