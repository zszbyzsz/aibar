import XCTest
@testable import aibar

final class NotchGeometryTests: XCTestCase {
    // A 14" MacBook Pro's built-in display, with the notch rect
    // `NotchGeometry.rect(on:fallbackSize:)` derives for it.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notch = CGRect(x: 661, y: 940, width: 190, height: 42)
    private let rowHeight: CGFloat = 32

    func testPhysicalNotchUsesTheExactGapBetweenAuxiliaryAreas() {
        let rect = NotchGeometry.physicalRect(
            screenFrame: screen,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 661, height: 32),
            auxiliaryTopRightArea: CGRect(x: 851, y: 950, width: 661, height: 32)
        )

        XCTAssertEqual(rect, CGRect(x: 661, y: 950, width: 190, height: 32))
    }

    func testPhysicalNotchWidthAdaptsAcrossMacBookGeometries() throws {
        let cases: [(screen: CGRect, left: CGRect, right: CGRect, expectedWidth: CGFloat)] = [
            (
                CGRect(x: 0, y: 0, width: 1470, height: 956),
                CGRect(x: 0, y: 924, width: 647, height: 32),
                CGRect(x: 823, y: 924, width: 647, height: 32),
                176
            ),
            (
                CGRect(x: 0, y: 0, width: 1728, height: 1117),
                CGRect(x: 0, y: 1083, width: 762, height: 34),
                CGRect(x: 966, y: 1083, width: 762, height: 34),
                204
            ),
        ]

        for item in cases {
            let rect = try XCTUnwrap(NotchGeometry.physicalRect(
                screenFrame: item.screen,
                safeAreaTop: item.left.height,
                auxiliaryTopLeftArea: item.left,
                auxiliaryTopRightArea: item.right
            ))
            XCTAssertEqual(rect.width, item.expectedWidth, accuracy: 0.001)
        }
    }

    func testHoverRectDoesNotLetFallbackOverrideARealNotchWidth() {
        let physical = CGRect(x: 647, y: 924, width: 176, height: 32)
        let hover = NotchGeometry.hoverRect(
            physicalRect: physical,
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            fallbackSize: CGSize(width: 190, height: 34)
        )

        XCTAssertEqual(hover, CGRect(x: 647, y: 914, width: 176, height: 42))
    }

    func testHoverRectFallsBackOnlyWhenNoPhysicalNotchExists() {
        let hover = NotchGeometry.hoverRect(
            physicalRect: nil,
            screenFrame: CGRect(x: 100, y: 200, width: 1280, height: 800),
            fallbackSize: CGSize(width: 190, height: 34)
        )

        XCTAssertEqual(hover, CGRect(x: 645, y: 966, width: 190, height: 34))
    }

    func testPhysicalNotchHandlesANonZeroScreenOrigin() {
        let rect = NotchGeometry.physicalRect(
            screenFrame: CGRect(x: -1728, y: 982, width: 1728, height: 1117),
            safeAreaTop: 34,
            auxiliaryTopLeftArea: CGRect(x: -1728, y: 2065, width: 762, height: 34),
            auxiliaryTopRightArea: CGRect(x: -762, y: 2065, width: 762, height: 34)
        )

        XCTAssertEqual(rect, CGRect(x: -966, y: 2065, width: 204, height: 34))
    }

    func testMissingOrInvalidAuxiliaryAreasDoNotInventAPhysicalNotch() {
        XCTAssertNil(NotchGeometry.physicalRect(
            screenFrame: screen,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        ))
        XCTAssertNil(NotchGeometry.physicalRect(
            screenFrame: screen,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 800, height: 32),
            auxiliaryTopRightArea: CGRect(x: 700, y: 950, width: 812, height: 32)
        ))
    }

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

    func testCameraBridgeUsesOnlyTheMenuBarThickness() {
        XCTAssertEqual(
            NotchGeometry.cameraBridgeFrame(
                notch: notch,
                screenFrame: screen,
                physicalHeight: 22
            ),
            CGRect(x: 661, y: 960, width: 190, height: 22)
        )
    }
}
