import XCTest
import SwiftUI
@testable import DiskCore
@testable import DiskUI

/// Independent verification of the treemap's layout.
///
/// The chart's promise is that a box's area is its share of the box that holds
/// it and that the shares of one group always add up to the whole: children are
/// drawn largest first, the rest are folded into one aggregate that stands for
/// exactly their bytes, and nothing is rescaled to fill the frame. These tests
/// check the geometry directly rather than what a screenshot happens to show.
final class TreemapLayoutQATests: XCTestCase {

    // MARK: - Fixtures

    private let rect = CGRect(x: 0, y: 0, width: 600, height: 400)

    private func makeNode(
        _ name: String,
        _ size: Int64,
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

    private func area(_ rect: CGRect) -> Double {
        Double(rect.width) * Double(rect.height)
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : area(intersection)
    }

    private func tiles(
        _ nodes: [ScanNode],
        maxChildren: Int = DS.Sunburst.maxChildrenPerNode,
        in rect: CGRect? = nil,
        maxTiles: Int = DS.Treemap.maxTiles
    ) -> [TreemapTile] {
        TreemapLayout.tiles(
            nodes: nodes,
            source: SnapshotTreemapSource(),
            maxChildren: maxChildren,
            in: rect ?? self.rect,
            maxTiles: maxTiles
        )
    }

    // MARK: - Squarification

    func testSquarifyTilesTheRectangleInProportion() {
        let areas: [Double] = [96_000, 72_000, 48_000, 12_000, 12_000]
        let rects = TreemapLayout.squarify(areas, in: rect)

        XCTAssertEqual(rects.count, areas.count)
        var covered: Double = 0
        for (tile, expected) in zip(rects, areas) {
            XCTAssertEqual(area(tile), expected, accuracy: 0.5)
            XCTAssertTrue(
                rect.insetBy(dx: -0.01, dy: -0.01).contains(tile),
                "\(tile) escapes \(rect)"
            )
            covered += area(tile)
        }
        XCTAssertEqual(covered, area(rect), accuracy: 1)
        for i in rects.indices {
            for j in rects.indices where i < j {
                XCTAssertEqual(overlapArea(rects[i], rects[j]), 0, accuracy: 0.01)
            }
        }
    }

    func testSquarifyKeepsBoxesCloserToSquareThanSliceAndDice() {
        // A slice-and-dice layout of this set would produce slivers many tens of
        // times longer than they are wide; squarifying keeps every box readable.
        let shares = (1...12).reversed().map { Double($0 * $0) }
        let scale = area(rect) / shares.reduce(0, +)
        let areas = shares.map { $0 * scale }
        let rects = TreemapLayout.squarify(areas, in: rect)
        XCTAssertEqual(rects.count, areas.count)
        for tile in rects {
            let ratio = max(tile.width / tile.height, tile.height / tile.width)
            XCTAssertLessThan(ratio, 6, "box \(tile) has aspect ratio \(ratio)")
        }
    }

    func testSquarifyHandlesDegenerateInput() {
        XCTAssertTrue(TreemapLayout.squarify([], in: rect).isEmpty)
        XCTAssertTrue(TreemapLayout.squarify([100], in: .zero).isEmpty)
    }

    // MARK: - Proportionality

    func testEveryBoxAreaIsItsShareOfItsParent() {
        let nodes = [
            makeNode("A", 600, path: "/qa/A"),
            makeNode("B", 300, path: "/qa/B"),
            makeNode("C", 100, path: "/qa/C"),
        ]
        let placed = tiles(nodes)
        let level = placed.filter { $0.depth == 1 }
        XCTAssertEqual(level.count, 3)

        let total = Double(600 + 300 + 100)
        for tile in level {
            XCTAssertEqual(
                area(tile.rect) / area(rect),
                Double(tile.size) / total,
                accuracy: 0.002,
                "\(tile.key) does not take its share of the chart"
            )
        }
        XCTAssertEqual(level.map(\.size), [600, 300, 100], "the largest box is drawn first")
    }

    // MARK: - Folding

    func testTheRemainderAccountsForEveryFoldedByte() {
        let nodes = (0..<20).map {
            makeNode("f\($0)", Int64(100 - $0), isDirectory: false, path: "/qa/f\($0)")
        }
        let placed = tiles(nodes, maxChildren: 5)
        let level = placed.filter { $0.depth == 1 }

        XCTAssertEqual(level.count, 6, "five boxes and one aggregate")
        let shown = level.filter { $0.node != nil }
        let remainder = level.first { $0.node == nil }
        XCTAssertEqual(shown.count, 5)
        XCTAssertEqual(remainder?.remainderCount, 15)
        XCTAssertEqual(remainder?.size, Int64((81...95).reduce(0, +)))
        XCTAssertEqual(remainder?.fill, ChartFill.aggregate)
        XCTAssertEqual(remainder?.key, "remainder:", "the aggregate uses the sunburst's ring-1 key")

        let covered = level.reduce(0.0) { $0 + area($1.rect) }
        XCTAssertEqual(covered, area(rect), accuracy: 1, "the boxes fill the chart with no rescaling")
    }

    func testAggregateUsesTheSameKeyAsTheSunburstsWedge() {
        let children = (0..<20).map {
            makeNode("f\($0)", Int64(100 - $0), isDirectory: false, path: "/qa/Folder/f\($0)")
        }
        let folder = makeNode("Folder", 1810, path: "/qa/Folder", children: children)
        let nodes = [folder, makeNode("Other", 1810, path: "/qa/Other")]

        let placed = tiles(nodes, maxChildren: 5)
        let nestedRemainder = placed.first { $0.depth == 2 && $0.node == nil }
        XCTAssertEqual(nestedRemainder?.key, "remainder:/qa/Folder")

        let segments = SunburstLayout.segments(roots: nodes, maxRings: 2, maxChildren: 5)
        let wedge = segments.first { $0.ring == 2 && $0.node == nil }
        XCTAssertEqual(wedge?.key, nestedRemainder?.key)
        XCTAssertEqual(wedge?.size, nestedRemainder?.size)
        XCTAssertEqual(wedge?.remainderCount, nestedRemainder?.remainderCount)
    }

    // MARK: - Nesting

    func testNestedBoxesStayInsideTheirFolder() {
        let children = [
            makeNode("k1", 300, isDirectory: false, path: "/qa/A/k1"),
            makeNode("k2", 200, isDirectory: false, path: "/qa/A/k2"),
        ]
        let folder = makeNode("A", 500, path: "/qa/A", children: children)
        let nodes = [folder, makeNode("B", 500, path: "/qa/B")]
        let placed = tiles(nodes)

        guard let parent = placed.first(where: { $0.key == "/qa/A" }) else {
            return XCTFail("the folder was not drawn")
        }
        let content = TreemapLayout.contentRect(of: parent.rect)
        let nested = placed.filter { $0.depth == 2 }
        XCTAssertEqual(nested.count, 2)
        for tile in nested {
            XCTAssertTrue(content.insetBy(dx: -0.01, dy: -0.01).contains(tile.rect),
                          "\(tile.key) escapes its folder")
        }
        XCTAssertTrue(parent.isNested, "a folder that draws its contents keeps a header")
        for tile in nested {
            XCTAssertGreaterThanOrEqual(tile.rect.minY,
                                        parent.rect.minY + DS.Treemap.headerHeight - 0.01,
                                        "content starts below the folder's name band")
        }
    }

    func testABoxTooSmallToHoldItsContentsStaysFlat() {
        let children = [
            makeNode("k1", 300, isDirectory: false, path: "/qa/A/k1"),
            makeNode("k2", 200, isDirectory: false, path: "/qa/A/k2"),
        ]
        let folder = makeNode("A", 500, path: "/qa/A", children: children)
        let nodes = [folder, makeNode("B", 500, path: "/qa/B")]

        let small = tiles(nodes, in: CGRect(x: 0, y: 0, width: 90, height: 60))
        XCTAssertTrue(small.filter { $0.depth == 2 }.isEmpty,
                      "a box below the nesting minimum draws no children")
        let flat = small.first { $0.key == "/qa/A" }
        XCTAssertEqual(flat?.size, 500, "the flat box still stands for its whole size")
        XCTAssertEqual(small.filter { $0.depth == 1 }.count, 2)
    }

    func testNestingStopsAtTheDepthCap() {
        var node = makeNode("leaf", 1_000, isDirectory: false, path: "/qa/L0/L1/L2/L3/L4/L5/L6/leaf")
        for level in stride(from: 6, through: 0, by: -1) {
            let path = (0...level).map { "L\($0)" }.joined(separator: "/")
            node = makeNode("L\(level)", 1_000, path: "/qa/\(path)", children: [node])
        }
        let placed = tiles([node], in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000))

        XCTAssertEqual(placed.map(\.depth).max(), DS.Treemap.maxDepth)
        XCTAssertFalse(placed.isEmpty)
    }

    // MARK: - Density

    func testTheChartDoesNotExceedItsTileBudget() {
        let nodes = (0..<40).map { folder in
            makeNode(
                "d\(folder)",
                1_000,
                path: "/qa/d\(folder)",
                children: (0..<10).map {
                    makeNode("f\($0)", 100, isDirectory: false, path: "/qa/d\(folder)/f\($0)")
                }
            )
        }
        let placed = tiles(nodes, maxTiles: 50)
        XCTAssertLessThanOrEqual(placed.count, 50)
        XCTAssertGreaterThan(placed.count, 0)
    }

    func testAnEmptyOrWeightlessChartDrawsNothing() {
        XCTAssertTrue(tiles([]).isEmpty)
        XCTAssertTrue(tiles([makeNode("zero", 0)]).isEmpty)
        XCTAssertTrue(tiles([makeNode("zero2", 0, isDirectory: false)]).isEmpty)
    }

    // MARK: - Hit testing

    func testHitTestReturnsTheDeepestBox() {
        let children = [
            makeNode("k1", 300, isDirectory: false, path: "/qa/A/k1"),
            makeNode("k2", 200, isDirectory: false, path: "/qa/A/k2"),
        ]
        let folder = makeNode("A", 500, path: "/qa/A", children: children)
        let nodes = [folder, makeNode("B", 500, path: "/qa/B")]
        let placed = tiles(nodes)

        guard let child = placed.first(where: { $0.depth == 2 }),
              let parent = placed.first(where: { $0.key == "/qa/A" }) else {
            return XCTFail("the fixture did not nest")
        }
        let insideChild = CGPoint(x: child.rect.midX, y: child.rect.midY)
        XCTAssertEqual(TreemapLayout.tile(at: insideChild, in: placed)?.key, child.key)

        // The band of the folder's own fill is the folder, not a child.
        let inPadding = CGPoint(x: parent.rect.minX + 1, y: parent.rect.minY + 1)
        XCTAssertEqual(TreemapLayout.tile(at: inPadding, in: placed)?.key, parent.key)

        XCTAssertNil(TreemapLayout.tile(at: CGPoint(x: -10, y: -10), in: placed))
    }

    // MARK: - Agreement with the sunburst

    func testSharedNodesKeepTheirFillInBothCharts() {
        let folderChildren = [
            makeNode("k1", 300, isDirectory: false, path: "/qa/A/k1"),
            makeNode("k2", 260, isDirectory: false, path: "/qa/A/k2"),
            makeNode("k3", 200, isDirectory: false, path: "/qa/A/k3"),
        ]
        let nodes = [
            makeNode("A", 760, path: "/qa/A", children: folderChildren),
            makeNode("B", 400, path: "/qa/B"),
            makeNode("C", 200, path: "/qa/C"),
        ]
        let placed = tiles(nodes, maxChildren: 12)
        let segments = SunburstLayout.segments(roots: nodes, maxRings: 3, maxChildren: 12)
        var fills: [String: ChartFill] = [:]
        for segment in segments {
            guard let node = segment.node else { continue }
            fills[node.url.path] = segment.fill
        }

        var compared = 0
        for tile in placed where tile.node != nil {
            guard let expected = fills[tile.key] else { continue }
            XCTAssertEqual(tile.fill, expected, "\(tile.key) changed colour between charts")
            compared += 1
        }
        XCTAssertGreaterThan(compared, 3, "the fixture must reach nodes both charts draw")
    }

    // MARK: - Off the main actor

    func testLayoutCanRunOffTheMainActor() async {
        let nodes = (0..<200).map {
            makeNode("f\($0)", Int64(1_000 - $0), isDirectory: false, path: "/qa/f\($0)")
        }
        let placed = await Task.detached(priority: .userInitiated) {
            TreemapLayout.tiles(
                nodes: nodes,
                source: SnapshotTreemapSource(),
                maxChildren: DS.Sunburst.maxChildrenPerNode,
                in: CGRect(x: 0, y: 0, width: 600, height: 400)
            )
        }.value
        XCTAssertFalse(placed.isEmpty)
        XCTAssertEqual(placed.filter { $0.depth == 1 }.count, 13, "twelve boxes and one aggregate")
    }

    func testLayoutIsDeterministic() {
        let nodes = (0..<30).map {
            makeNode("f\($0)", Int64((($0 * 37) % 91) + 10), isDirectory: false, path: "/qa/f\($0)")
        }
        let first = tiles(nodes, maxChildren: 8)
        let second = tiles(nodes, maxChildren: 8)
        XCTAssertEqual(first, second)
    }
}
