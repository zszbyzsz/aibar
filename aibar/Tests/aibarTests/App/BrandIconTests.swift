import XCTest
@testable import aibar

final class BrandIconTests: XCTestCase {
    func testMenuBarImageUsesNativeTemplateRendering() {
        let image = BrandIcon.menuBarImage()

        XCTAssertEqual(image.size, BrandIcon.menuBarSize)
        XCTAssertTrue(image.isTemplate)
        XCTAssertTrue(image.isValid)
    }
}
