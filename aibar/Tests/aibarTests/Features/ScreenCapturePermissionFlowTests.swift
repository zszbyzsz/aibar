import XCTest
@testable import aibar

final class ScreenCapturePermissionFlowTests: XCTestCase {
    func testFirstMissingPermissionUsesOnlyTheSystemRequest() {
        var flow = ScreenCapturePermissionFlow()

        XCTAssertEqual(flow.nextAction(hasAccess: false), .requestAccess)
        XCTAssertEqual(flow.nextAction(hasAccess: false), .showSettings)
    }

    func testExistingPermissionCapturesWithoutRequestingAgain() {
        var flow = ScreenCapturePermissionFlow()

        XCTAssertEqual(flow.nextAction(hasAccess: true), .capture)
        XCTAssertEqual(flow.nextAction(hasAccess: true), .capture)
    }

    func testGrantTakesEffectAfterAnEarlierDenial() {
        var flow = ScreenCapturePermissionFlow()

        XCTAssertEqual(flow.nextAction(hasAccess: false), .requestAccess)
        XCTAssertEqual(flow.nextAction(hasAccess: true), .capture)
    }
}
