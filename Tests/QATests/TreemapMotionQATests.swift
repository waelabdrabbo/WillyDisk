import XCTest
import SwiftUI
@testable import DiskCore
@testable import DiskUI

/// Independent verification of the treemap's motion.
///
/// The chart's promise is that a rebuilt layout is the same picture rearranged:
/// a box whose node stays on screen keeps its identity and moves to where the
/// new layout puts it, a box that arrives opens out of its own centre and only
/// becomes a target once it is really drawn, and a box that leaves fades out
/// beneath the rest. These tests drive `TreemapAnimator` directly, one frame at
/// a time, rather than looking at a screenshot of the settled chart.
final class TreemapMotionQATests: XCTestCase {

    // MARK: - Fixtures

    private func makeTile(
        _ key: String,
        _ rect: CGRect,
        depth: Int = 1,
        size: Int64 = 100,
        fill: ChartFill = .tone(ring: 1, step: 0),
        isNested: Bool = false
    ) -> TreemapTile {
        TreemapTile(
            key: key,
            node: nil,
            remainderCount: 0,
            depth: depth,
            rect: rect,
            fill: fill,
            size: size,
            isNested: isNested
        )
    }

    /// Runs `seconds` of frames at 60 Hz.
    private func run(_ animator: TreemapAnimator, seconds: Double) {
        for _ in 0..<Int((seconds * 60).rounded()) {
            animator.step(dt: 1.0 / 60)
        }
    }

    // MARK: - Approaching a new layout

    func testAFirstLayoutIsAdoptedNotAnimated() throws {
        let animator = TreemapAnimator()
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 100, height: 50))], animated: true)
        XCTAssertTrue(animator.isSettled, "a first appearance is adopted, not animated")
        let drawn = try XCTUnwrap(animator.tile(forKey: "/qa/a"))
        XCTAssertEqual(drawn.alpha, 1)
        XCTAssertEqual(drawn.rect, CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testAnEntranceStartsSmallAndHidden() throws {
        let animator = TreemapAnimator()
        let target = CGRect(x: 100, y: 100, width: 200, height: 80)
        animator.setTarget([makeTile("/qa/a", target)], animated: true, intro: true)

        let entering = try XCTUnwrap(animator.tile(forKey: "/qa/a"))
        XCTAssertEqual(entering.alpha, 0, "an arriving box starts invisible")
        XCTAssertLessThan(entering.rect.width, target.width)
        XCTAssertEqual(entering.rect.midX, target.midX, accuracy: 1e-9)
        XCTAssertEqual(entering.rect.midY, target.midY, accuracy: 1e-9)
        XCTAssertFalse(animator.isSettled)

        run(animator, seconds: 0.6)
        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.tile(forKey: "/qa/a")?.rect, target)
        XCTAssertEqual(animator.tile(forKey: "/qa/a")?.alpha, 1)
    }

    func testAChangedLayoutIsApproachedWithoutOvershoot() throws {
        let animator = TreemapAnimator()
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 100, height: 100))],
                           animated: false)
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 300, height: 100))],
                           animated: true)
        XCTAssertFalse(animator.isSettled)

        var previous = try XCTUnwrap(animator.tile(forKey: "/qa/a")).rect.width
        for _ in 0..<180 {
            animator.step(dt: 1.0 / 60)
            let width = try XCTUnwrap(animator.tile(forKey: "/qa/a")).rect.width
            XCTAssertGreaterThanOrEqual(width, previous - 1e-9, "the box never moves backwards")
            XCTAssertLessThanOrEqual(width, 300 + 1e-6, "the box approaches without overshoot")
            previous = width
        }
        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.tile(forKey: "/qa/a")?.rect.width ?? 0, 300, accuracy: 0.001)
    }

    // MARK: - Arriving and leaving boxes

    func testAnArrivingBoxIsNotHoverableBeforeItIsDrawn() throws {
        let animator = TreemapAnimator()
        let left = CGRect(x: 0, y: 0, width: 50, height: 100)
        let right = CGRect(x: 50, y: 0, width: 50, height: 100)
        animator.setTarget([makeTile("/qa/a", left)], animated: false)
        animator.setTarget([makeTile("/qa/a", left), makeTile("/qa/b", right)], animated: true)

        XCTAssertEqual(animator.tile(forKey: "/qa/b")?.alpha, 0)
        // The near edge of the new box is where the arriving one is not yet drawn.
        XCTAssertNil(animator.tile(at: CGPoint(x: 51, y: 50)),
                     "a box that has not opened cannot be hovered where it will land")

        run(animator, seconds: 0.3)
        XCTAssertEqual(animator.tile(at: CGPoint(x: 75, y: 50))?.tile.key, "/qa/b")
    }

    func testALeavingBoxFadesOutAndIsDropped() {
        let animator = TreemapAnimator()
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 50, height: 100)),
                            makeTile("/qa/b", CGRect(x: 50, y: 0, width: 50, height: 100))],
                           animated: false)
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 100, height: 100))],
                           animated: true)

        run(animator, seconds: 0.1)
        let fading = animator.tile(forKey: "/qa/b")
        XCTAssertNotNil(fading, "a dropped box is still drawn while it fades")
        XCTAssertLessThan(fading?.alpha ?? 1, 1)
        XCTAssertEqual(animator.tile(at: CGPoint(x: 75, y: 50))?.tile.key, "/qa/a",
                       "a fading box is not a target; the live box under the pointer is")

        run(animator, seconds: 3)
        XCTAssertNil(animator.tile(forKey: "/qa/b"), "the fade finishes and the box is released")
        XCTAssertTrue(animator.isSettled)
    }

    func testABoxThatReturnsWhileFadingIsDrawnOnce() {
        let a = makeTile("/qa/a", CGRect(x: 0, y: 0, width: 50, height: 100))
        let b = makeTile("/qa/b", CGRect(x: 50, y: 0, width: 50, height: 100))
        let animator = TreemapAnimator()
        animator.setTarget([a, b], animated: false)
        animator.setTarget([a], animated: true)
        run(animator, seconds: 0.1)
        animator.setTarget([a, b], animated: true)

        let keys = animator.drawn.map(\.tile.key)
        XCTAssertEqual(keys.count, Set(keys).count, "the returning box is drawn once")
        XCTAssertEqual(Set(keys), ["/qa/a", "/qa/b"])
    }

    // MARK: - A drill is a move

    func testDrillingMovesTheSameBoxOutOfItsFolder() {
        let one = makeTile("/qa/A/one", CGRect(x: 10, y: 10, width: 40, height: 40), depth: 2)
        let two = makeTile("/qa/A/two", CGRect(x: 52, y: 10, width: 38, height: 40), depth: 2)
        let folder = makeTile("/qa/A", CGRect(x: 0, y: 0, width: 100, height: 100))
        let animator = TreemapAnimator()
        animator.setTarget([folder, one, two], animated: false)

        animator.setTarget([
            makeTile("/qa/A/one", CGRect(x: 0, y: 0, width: 60, height: 100)),
            makeTile("/qa/A/two", CGRect(x: 60, y: 0, width: 40, height: 100)),
        ], animated: true)

        XCTAssertEqual(animator.tile(forKey: "/qa/A/one")?.tile.depth, 1)
        XCTAssertEqual(animator.tile(forKey: "/qa/A/two")?.tile.depth, 1)
        run(animator, seconds: 1)
        XCTAssertEqual(animator.tile(forKey: "/qa/A/one")?.rect,
                       CGRect(x: 0, y: 0, width: 60, height: 100),
                       "the same box is now the whole chart's first box")

        run(animator, seconds: 3)
        XCTAssertNil(animator.tile(forKey: "/qa/A"), "the folder the chart left has faded away")
    }

    // MARK: - Motion preferences

    func testReduceMotionAdoptsTheNewLayoutAtOnce() {
        let animator = TreemapAnimator()
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 100, height: 100))],
                           animated: false)
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 300, height: 100))],
                           animated: false, intro: true)

        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.tile(forKey: "/qa/a")?.rect.width, 300)
        XCTAssertEqual(animator.tile(forKey: "/qa/a")?.alpha, 1)
    }

    func testSettleFinishesAMove() {
        let animator = TreemapAnimator()
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 100, height: 100))],
                           animated: false)
        animator.setTarget([makeTile("/qa/a", CGRect(x: 0, y: 0, width: 300, height: 100))],
                           animated: true)
        animator.settle()

        XCTAssertTrue(animator.isSettled)
        XCTAssertEqual(animator.tile(forKey: "/qa/a")?.rect.width, 300)
    }

    // MARK: - Hit testing

    func testHitTestReturnsTheDeepestDrawnBox() throws {
        let animator = TreemapAnimator()
        animator.setTarget([
            makeTile("/qa/A", CGRect(x: 0, y: 0, width: 100, height: 100)),
            makeTile("/qa/A/one", CGRect(x: 10, y: 10, width: 30, height: 30), depth: 2),
        ], animated: false)

        XCTAssertEqual(animator.tile(at: CGPoint(x: 20, y: 20))?.tile.key, "/qa/A/one")
        XCTAssertEqual(animator.tile(at: CGPoint(x: 60, y: 60))?.tile.key, "/qa/A")
        XCTAssertNil(animator.tile(at: CGPoint(x: -1, y: -1)))
    }
}
