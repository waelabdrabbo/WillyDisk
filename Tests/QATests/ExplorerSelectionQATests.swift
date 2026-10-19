import XCTest
@testable import DiskUI

final class ExplorerSelectionQATests: XCTestCase {
    private let a = URL(fileURLWithPath: "/tmp/a")
    private let b = URL(fileURLWithPath: "/tmp/b")
    private let c = URL(fileURLWithPath: "/tmp/c")
    private let d = URL(fileURLWithPath: "/tmp/d")
    private let e = URL(fileURLWithPath: "/tmp/e")

    private var order: [URL] { [a, b, c, d, e] }

    func testPlainClickReplacesSelection() {
        var selection = ExplorerSelection()
        selection.click(a, in: order)
        selection.click(c, in: order)

        XCTAssertEqual(selection.urls, [c])
        XCTAssertEqual(selection.anchor, c)
        XCTAssertEqual(selection.focused, c)
    }

    func testShiftClickExtendsFromTheAnchorInListOrder() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)
        selection.click(d, in: order, toggling: false, extending: true)

        XCTAssertEqual(selection.urls, [b, c, d])
        XCTAssertEqual(selection.focused, d)
        // The anchor stays put: a second Shift-click extends from the same row
        // rather than from the row the first range ended on.
        selection.click(e, in: order, extending: true)
        XCTAssertEqual(selection.urls, [b, c, d, e])
    }

    func testShiftClickBackwardsCoversTheSameRange() {
        var selection = ExplorerSelection()
        selection.click(d, in: order)
        selection.click(b, in: order, extending: true)

        XCTAssertEqual(selection.urls, [b, c, d])
        XCTAssertEqual(selection.focused, b)
    }

    func testCommandClickTogglesAndLeavesTheAnchorWhereItClicked() {
        var selection = ExplorerSelection()
        selection.click(a, in: order)
        selection.click(c, in: order, toggling: true)

        XCTAssertEqual(selection.urls, [a, c])
        XCTAssertEqual(selection.focused, c)
        XCTAssertEqual(selection.anchor, c)

        selection.click(a, in: order, toggling: true)
        XCTAssertEqual(selection.urls, [c])
    }

    func testArrowKeysMoveTheCursorAndClampAtTheEnds() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)

        XCTAssertEqual(selection.move(by: 1, in: order, extending: false), c)
        XCTAssertEqual(selection.urls, [c])
        XCTAssertEqual(selection.move(by: 10, in: order, extending: false), e)
        XCTAssertEqual(selection.move(by: -10, in: order, extending: false), a)
    }

    func testArrowKeysWithShiftGrowARangeFromTheAnchor() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)
        selection.move(by: 2, in: order, extending: true)

        XCTAssertEqual(selection.urls, [b, c, d])
        XCTAssertEqual(selection.focused, d)
        XCTAssertEqual(selection.anchor, b)

        selection.move(by: -1, in: order, extending: true)
        XCTAssertEqual(selection.urls, [b, c])
    }

    func testHomeAndEndJumpToTheEnds() {
        var selection = ExplorerSelection()
        selection.click(c, in: order)

        XCTAssertEqual(selection.jump(to: 0, in: order, extending: false), a)
        XCTAssertEqual(selection.urls, [a])
        XCTAssertEqual(selection.jump(to: order.count - 1, in: order, extending: false), e)
        XCTAssertEqual(selection.urls, [e])
    }

    func testMoveWithoutAFocusedRowStartsAtTheNearEnd() {
        var selection = ExplorerSelection()

        XCTAssertEqual(selection.move(by: 1, in: order, extending: false), a)
        selection.clear()
        XCTAssertEqual(selection.move(by: -1, in: order, extending: false), e)
    }

    func testSelectionSurvivesWhileEverySelectedURLIsStillAvailable() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)
        selection.click(d, in: order, extending: true)

        selection.prune(to: order)
        XCTAssertEqual(selection.urls, [b, c, d])
        XCTAssertEqual(selection.focused, d)
        XCTAssertEqual(selection.anchor, b)
    }

    func testPruneDropsRetiredRowsAndMovesTheCursorToASurvivor() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)
        selection.click(d, in: order, extending: true)

        selection.prune(to: [b, c])
        XCTAssertEqual(selection.urls, [b, c])
        // The cursor returns to the range's anchor rather than jumping to the
        // neighbour of the row that left the list.
        XCTAssertEqual(selection.focused, b)
        XCTAssertEqual(selection.anchor, b)
    }

    func testPruneWithoutTheAnchorOrCursorPicksTheFirstSurvivingRow() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)
        selection.click(e, in: order, extending: true)

        selection.prune(to: [a, c, d])
        XCTAssertEqual(selection.urls, [c, d])
        XCTAssertEqual(selection.focused, c)
        XCTAssertEqual(selection.anchor, c)
    }

    func testPruneClearsASelectionWithNothingLeft() {
        var selection = ExplorerSelection()
        selection.click(c, in: order)

        selection.prune(to: [a, b])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertNil(selection.anchor)
        XCTAssertNil(selection.focused)
    }

    func testShiftWinsOverCommandForAnExtendedClick() {
        var selection = ExplorerSelection()
        selection.click(a, in: order)
        selection.click(c, in: order, toggling: true, extending: true)

        XCTAssertEqual(selection.urls, [a, b, c])
        XCTAssertEqual(selection.anchor, a)
        XCTAssertEqual(selection.focused, c)
    }

    func testShiftClickWithAStaleAnchorSelectsOnlyTheClickedRow() {
        var selection = ExplorerSelection()
        selection.click(b, in: order)
        selection.prune(to: [a, c, d, e])

        selection.click(d, in: order, toggling: true, extending: true)
        XCTAssertEqual(selection.urls, [d])
        XCTAssertEqual(selection.anchor, d)
    }
}
