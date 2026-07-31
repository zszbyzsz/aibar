import XCTest
@testable import aibar

final class NotchGeometryTests: XCTestCase {
    // A 14" MacBook Pro's built-in display, with the notch rect
    // `NotchGeometry.rect(on:fallbackSize:)` derives for it.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGRect(x: 661, y: 940, width: 190, height: 42)
    private let rowHeight: CGFloat = 32

    private func limit() -> CGFloat {
        NotchGeometry.availableHeightBelow(
            notch: notch, screenFrame: screen, gap: 6, minimum: rowHeight
        )
    }

    func testAvailableHeightMeasuresTheSpaceBelowTheNotchNotAboveIt() {
        // 940 (notch bottom) - 0 (screen bottom) - 6 (gap) - 20 (margin).
        XCTAssertEqual(limit(), 914, accuracy: 0.001)
    }

    func testTallStacksAreNotClampedDownToASingleRow() {
        // The regression this guards: deriving the limit from the sliver above
        // the notch instead of the space below pinned every clamp to exactly
        // one row, so the capsule stack could never grow and hovering it
        // appeared to do nothing at all.
        for rowCount in [2, 3, 6, 10] {
            let wanted = CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * 4
            XCTAssertEqual(min(wanted, limit()), wanted, accuracy: 0.001,
                           "a \(rowCount)-row stack should not be clamped")
        }
    }

    func testStillClampsAStackTallerThanTheScreen() {
        XCTAssertEqual(min(CGFloat(5_000), limit()), 914, accuracy: 0.001)
    }

    func testNeverReturnsLessThanOneRowEvenOnAnAbsurdlyShortScreen() {
        let tiny = NotchGeometry.availableHeightBelow(
            notch: CGRect(x: 0, y: 10, width: 190, height: 42),
            screenFrame: CGRect(x: 0, y: 0, width: 400, height: 52),
            gap: 6, minimum: rowHeight
        )
        XCTAssertEqual(tiny, rowHeight, accuracy: 0.001)
    }

    func testHandlesAnExternalDisplayWhoseOriginIsNotZero() {
        // A screen sitting above the main display has a non-zero minY; the
        // available height is still measured within that screen, not from the
        // global coordinate origin.
        let external = CGRect(x: 0, y: 982, width: 1512, height: 982)
        let externalNotch = CGRect(x: 661, y: 982 + 940, width: 190, height: 42)
        XCTAssertEqual(
            NotchGeometry.availableHeightBelow(
                notch: externalNotch, screenFrame: external, gap: 6, minimum: rowHeight
            ),
            914, accuracy: 0.001
        )
    }
}
