import XCTest
import Foundation
@testable import DiskUI

/// A fixed sheet size must not be larger than the screen it opens on.
final class SheetSizingQATests: XCTestCase {

    private let laptop = CGRect(x: 0, y: 0, width: 1280, height: 744)

    func testSettingsFitsTheVisibleFrameOfASmallLaptop() {
        let size = SheetSizing.fitted(width: 460, height: 760, visible: laptop)
        XCTAssertEqual(size.width, 460)
        XCTAssertEqual(size.height, 696, "760 minus one 24-point margin above and below")
        XCTAssertLessThan(size.height, laptop.height)
    }

    func testASheetThatAlreadyFitsIsUnchanged() {
        let size = SheetSizing.fitted(width: 900, height: 680, visible: laptop)
        XCTAssertEqual(size, CGSize(width: 900, height: 680))
    }

    func testATinyScreenStillGetsAUsableFrame() {
        let size = SheetSizing.fitted(width: 460, height: 760, visible: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(size, CGSize(width: 320, height: 320))
    }
}
