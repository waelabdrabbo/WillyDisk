import XCTest
import SwiftUI
@testable import DiskCore
@testable import DiskUI

/// Independent verification of the sunburst's motion.
///
/// The chart's promise is that a rebuilt layout is the same picture rearranged,
/// not a new one: a wedge whose node stays on screen keeps its identity and
/// moves to where the new layout puts it, a wedge that arrives opens outwards
/// only once it is really visible, and a wedge that leaves fades out beneath the
/// rest. These tests drive `SunburstAnimator` directly, one frame at a time, so
/// they can assert what the drawing code is handed on every frame rather than
/// what a screenshot of the settled chart happens to show.
final class SunburstMotionQATests: XCTestCase {

    // MARK: - Fixtures

    private func makeNode(
        _ name: String,
        size: Int64,
        isDirectory: Bool = true,
        path: String? = nil,
        children: [ScanNode] = []
    ) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path ?? "/qa/\(name)"),
            name: name,
            isDirectory: isDirectory,
            isSymlink: false,
            category: .other,
            logicalSize: size,
            allocatedSize: size,
            fileCount: isDirectory ? children.filter { !$0.isDirectory }.count : 1,
            directoryCount: isDirectory ? children.filter(\.isDirectory).count : 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: children
        )
    }

    private func segments(_ roots: [ScanNode]) -> [SunburstSegment] {
        SunburstLayout.segments(roots: roots, maxRings: 3, maxChildren: 12)
    }

    /// Runs `seconds` of frames at 60 Hz.
    private func run(_ animator: SunburstAnimator, seconds: Double) {
        for _ in 0..<Int((seconds * 60).rounded()) {
            animator.step(dt: 1.0 / 60)
        }
    }

    // MARK: - Geometry

    func testFractionalDepthAgreesWithWholeRings() {
        let geometry = SunburstGeometry(side: 400, ringCount: 3)
        for ring in 1...3 {
            let byRing = geometry.radii(ring: ring)
            let byDepth = geometry.radii(depth: Double(ring))
            XCTAssertEqual(byDepth.inner, byRing.inner, accuracy: 1e-9)
            XCTAssertEqual(byDepth.outer, byRing.outer, accuracy: 1e-9)
        }
        XCTAssertEqual(geometry.radii(ring: 3).outer, geometry.outerRadius, accuracy: 1e-9,
                       "the outermost ring reaches the rim")

        // A wedge between rings is drawn between their bands, which is what the
        // eye reads as a move rather than a cut.
        let between = geometry.radii(depth: 1.5)
        XCTAssertGreaterThan(between.inner, geometry.radii(ring: 1).inner)
        XCTAssertLessThan(between.outer, geometry.radii(ring: 2).outer)

        // A wedge with no reveal is closed onto its inner edge.
        let hidden = geometry.radii(depth: 1, revealed: 0)
        XCTAssertEqual(hidden.outer, hidden.inner, accuracy: 1e-9)
    }

    // MARK: - Approaching a new layout

    func testAChangedLayoutIsApproachedWithoutOvershoot() throws {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let b = makeNode("b", size: 40, isDirectory: false, path: "/qa/b")
        let first = segments([a, b])

        let animator = SunburstAnimator()
        animator.setTarget(first, animated: false)
        XCTAssertTrue(animator.isSettled, "a first appearance is adopted, not animated")
        let before = try XCTUnwrap(animator.wedge(forKey: "/qa/a"))
        XCTAssertEqual(before.end, 0.6 * 2 * .pi, accuracy: 1e-9)

        let grown = makeNode("a", size: 80, isDirectory: false, path: "/qa/a")
        let shrunk = makeNode("b", size: 20, isDirectory: false, path: "/qa/b")
        animator.setTarget(segments([grown, shrunk]), animated: true)
        XCTAssertFalse(animator.isSettled)

        let target = 0.8 * 2 * .pi
        var previous = before.end
        for _ in 0..<180 {
            animator.step(dt: 1.0 / 60)
            let end = animator.wedge(forKey: "/qa/a")?.end ?? 0
            XCTAssertGreaterThanOrEqual(end, previous - 1e-9, "the wedge never moves backwards")
            XCTAssertLessThanOrEqual(end, target + 1e-6, "the wedge approaches without overshoot")
            previous = end
        }

        XCTAssertTrue(animator.isSettled, "the motion hands the frames back once it is done")
        XCTAssertEqual(animator.wedge(forKey: "/qa/a")?.end ?? 0, target, accuracy: 1e-3)
    }

    // MARK: - Arriving and leaving wedges

    func testAnEnteringWedgeIsNotDrawnOrHoverableBeforeItOpens() throws {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let b = makeNode("b", size: 40, isDirectory: false, path: "/qa/b")

        let animator = SunburstAnimator()
        animator.setTarget(segments([a]), animated: false)

        let withB = segments([a, b])
        animator.setTarget(withB, animated: true)
        let entering = animator.wedge(forKey: "/qa/b")
        XCTAssertEqual(entering?.alpha ?? 1, 0, "an arriving wedge starts invisible")
        XCTAssertLessThan(entering?.grow ?? 0, 0, "it waits its turn before opening")

        let geometry = SunburstGeometry(side: 400, ringSpan: animator.ringSpan)
        let segment = try XCTUnwrap(withB.first { $0.key == "/qa/b" })
        let band = geometry.radii(depth: Double(segment.ring))
        let radius = (band.inner + band.outer) / 2
        let angle = (segment.start + segment.end) / 2
        let point = CGPoint(x: geometry.center.x + sin(angle) * radius,
                            y: geometry.center.y - cos(angle) * radius)

        XCTAssertNotEqual(geometry.wedge(at: point, in: animator.drawn)?.key, "/qa/b",
                          "a wedge that has not opened cannot be hovered")

        run(animator, seconds: 0.3)
        XCTAssertEqual(geometry.wedge(at: point, in: animator.drawn)?.key, "/qa/b",
                       "once it has opened, the pointer finds it where it is drawn")
    }

    func testALeavingWedgeFadesOutAndIsDropped() {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let b = makeNode("b", size: 40, isDirectory: false, path: "/qa/b")

        let animator = SunburstAnimator()
        animator.setTarget(segments([a, b]), animated: false)
        animator.setTarget(segments([a]), animated: true)

        run(animator, seconds: 0.15)
        let fading = animator.wedge(forKey: "/qa/b")
        XCTAssertNotNil(fading, "a dropped wedge is still drawn while it fades")
        XCTAssertLessThan(fading?.alpha ?? 1, 1)

        run(animator, seconds: 3)
        XCTAssertNil(animator.wedge(forKey: "/qa/b"), "the fade finishes and the wedge is released")
        XCTAssertTrue(animator.isSettled)
    }

    /// A wedge that comes back before its fade has finished is one wedge, not a
    /// fading ghost and a live copy of the same thing.
    func testAWedgeThatReturnsWhileFadingIsDrawnOnce() {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let b = makeNode("b", size: 40, isDirectory: false, path: "/qa/b")

        let animator = SunburstAnimator()
        animator.setTarget(segments([a, b]), animated: false)
        animator.setTarget(segments([a]), animated: true)
        run(animator, seconds: 0.1)
        animator.setTarget(segments([a, b]), animated: true)

        let keys = animator.drawn.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "the returning wedge is drawn once")
        XCTAssertEqual(Set(keys), ["/qa/a", "/qa/b"])

        run(animator, seconds: 3)
        let settled = animator.drawn.map(\.key)
        XCTAssertEqual(settled.count, Set(settled).count)
        XCTAssertEqual(Set(settled), ["/qa/a", "/qa/b"])
    }

    // MARK: - A drill is a move

    /// Drilling into a folder keeps the identity of everything the new chart
    /// still draws: the folder's children were on ring 2 and are now on ring 1,
    /// so the picture slides inwards instead of being replaced.
    func testDrillingMovesTheSameWedgeToTheInnerRing() {
        let one = makeNode("one", size: 60, isDirectory: false, path: "/qa/A/one")
        let two = makeNode("two", size: 40, isDirectory: false, path: "/qa/A/two")
        let a = makeNode("A", size: 100, path: "/qa/A", children: [one, two])

        let animator = SunburstAnimator()
        animator.setTarget(segments([a]), animated: false)
        XCTAssertEqual(animator.wedge(forKey: "/qa/A/one")?.depth ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(animator.ringSpan, 2, accuracy: 1e-9)

        let focused = segments(a.children)
        animator.setTarget(focused, animated: true)

        run(animator, seconds: 1.0 / 60)
        let moving = animator.wedge(forKey: "/qa/A/one")
        XCTAssertLessThan(moving?.depth ?? 0, 2, "it has started moving inwards")
        XCTAssertGreaterThan(moving?.depth ?? 0, 1, "it has not arrived yet")
        XCTAssertLessThan(animator.ringSpan, 2, "the disc re-divides into one ring")

        run(animator, seconds: 3)
        XCTAssertEqual(animator.wedge(forKey: "/qa/A/one")?.depth ?? 0, 1, accuracy: 1e-3,
                       "the wedge arrives on the inner ring")
        XCTAssertEqual(animator.ringSpan, 1, accuracy: 1e-3)
        XCTAssertEqual(animator.wedge(forKey: "/qa/A/one")?.end ?? 0,
                       0.6 * 2 * .pi, accuracy: 1e-3)
        XCTAssertNil(animator.wedge(forKey: "/qa/A"), "the folder itself fades into the plate")
    }

    // MARK: - The entrance

    /// A chart asked to replay its entrance starts hidden and opens as the wave:
    /// nothing is drawn on the first frame, and every wedge has waited its turn
    /// before it is whole.
    func testAnEntranceStartsHiddenAndOpensAsAWave() {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let b = makeNode("b", size: 40, isDirectory: false, path: "/qa/b")

        let animator = SunburstAnimator()
        animator.setTarget(segments([a, b]), animated: true, intro: true)

        XCTAssertFalse(animator.isSettled, "an entrance is motion, not a still")
        XCTAssertEqual(animator.drawn.count, 2)
        XCTAssertTrue(animator.drawn.allSatisfy { $0.alpha == 0 }, "the first frame is empty")
        XCTAssertTrue(animator.drawn.allSatisfy { $0.grow <= 0 }, "every wedge waits its turn")

        run(animator, seconds: 1.0 / 60)
        XCTAssertFalse(animator.isSettled, "one frame is not the whole entrance")

        run(animator, seconds: 3)
        XCTAssertTrue(animator.isSettled)
        XCTAssertTrue(animator.drawn.allSatisfy { $0.alpha > 0.99 && $0.grow >= 1 },
                      "the entrance finishes with every wedge whole")
    }

    func testAnEntranceIsSkippedWhenMotionIsOff() {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let animator = SunburstAnimator()
        animator.setTarget(segments([a]), animated: false, intro: true)

        XCTAssertTrue(animator.isSettled, "Reduce Motion shows the chart at once")
        let wedge = animator.wedge(forKey: "/qa/a")
        XCTAssertEqual(wedge?.alpha ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(wedge?.grow ?? 0, 1, accuracy: 1e-9)
    }

    // MARK: - The category ring's entrance

    /// The ring has one band, so its entrance is the reveal alone: it opens from
    /// 12 o'clock, the slices further round following their neighbours, and it
    /// is whole by the end and never past it.
    func testTheRingOpensClockwiseFromTwelveOClock() {
        XCTAssertEqual(CategoryRingEntrance.reveal(elapsed: 0, start: 0), 0, accuracy: 1e-9,
                       "nothing is drawn on the first frame")
        XCTAssertEqual(CategoryRingEntrance.reveal(elapsed: CategoryRingEntrance.duration, start: 0),
                       1, accuracy: 1e-9)
        XCTAssertEqual(CategoryRingEntrance.reveal(elapsed: CategoryRingEntrance.duration, start: 2 * .pi),
                       1, accuracy: 1e-9, "the last slice is whole by the end")

        let half = CategoryRingEntrance.duration * 0.5
        XCTAssertGreaterThan(
            CategoryRingEntrance.reveal(elapsed: half, start: 0),
            CategoryRingEntrance.reveal(elapsed: half, start: .pi),
            "a slice further round opens later than one at 12 o'clock"
        )

        for step in 0...20 {
            let elapsed = CategoryRingEntrance.duration * Double(step) / 20
            let value = CategoryRingEntrance.reveal(elapsed: elapsed, start: .pi)
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: - Reduce Motion

    func testAdoptingALayoutAtOnceFinishesEveryWedge() {
        let a = makeNode("a", size: 60, isDirectory: false, path: "/qa/a")
        let b = makeNode("b", size: 40, isDirectory: false, path: "/qa/b")

        let animator = SunburstAnimator()
        animator.setTarget(segments([a, b]), animated: false)
        let changed = segments([makeNode("a", size: 20, isDirectory: false, path: "/qa/a"), b])
        animator.setTarget(changed, animated: false)

        XCTAssertTrue(animator.isSettled)
        for segment in changed {
            let wedge = animator.wedge(forKey: segment.key)
            XCTAssertEqual(wedge?.start ?? -1, segment.start, accuracy: 1e-9)
            XCTAssertEqual(wedge?.end ?? -1, segment.end, accuracy: 1e-9)
            XCTAssertEqual(wedge?.depth ?? -1, Double(segment.ring), accuracy: 1e-9)
            XCTAssertEqual(wedge?.alpha ?? 0, 1, accuracy: 1e-9)
        }
    }
}
