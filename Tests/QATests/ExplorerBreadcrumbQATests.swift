import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The explorer's breadcrumb against the live tree: a folder opened three levels
/// down must stay open while the tree changes around it.
final class ExplorerBreadcrumbQATests: XCTestCase {

    private let rootURL = URL(fileURLWithPath: "/scan", isDirectory: true)

    // MARK: - Fixtures

    private func file(_ path: String, size: Int64) -> ScanNode {
        ScanNode(
            id: UUID(), url: URL(fileURLWithPath: path), name: (path as NSString).lastPathComponent,
            isDirectory: false, isSymlink: false, category: .documents,
            logicalSize: size, allocatedSize: size, fileCount: 1, directoryCount: 0,
            modifiedAt: nil, isAccessible: true, errorMessage: nil, children: []
        )
    }

    private func folder(_ path: String, _ children: [ScanNode]) -> ScanNode {
        ScanNode(
            id: UUID(), url: URL(fileURLWithPath: path, isDirectory: true),
            name: (path as NSString).lastPathComponent,
            isDirectory: true, isSymlink: false, category: .other,
            logicalSize: children.reduce(0) { $0 + $1.logicalSize },
            allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            directoryCount: 1 + children.reduce(0) { $0 + $1.directoryCount },
            modifiedAt: nil, isAccessible: true, errorMessage: nil, children: children
        )
    }

    /// /scan/A/B/C with a file in each level.
    private func fixture() -> ScanNode {
        folder(
            "/scan",
            [
                folder("/scan/A", [
                    file("/scan/A/a.bin", size: 10),
                    folder("/scan/A/B", [
                        file("/scan/A/B/b.bin", size: 20),
                        folder("/scan/A/B/C", [file("/scan/A/B/C/c.bin", size: 30)]),
                    ]),
                ]),
                file("/scan/root.bin", size: 5),
            ]
        )
    }

    private func makeTree(_ root: ScanNode? = nil) throws -> LiveTree {
        let measured = root ?? fixture()
        var categories: [FileCategory: Int64] = [:]
        func visit(_ node: ScanNode) {
            if !node.isDirectory, node.fileCount > 0 {
                categories[node.category, default: 0] += node.logicalSize
            }
            node.children.forEach(visit)
        }
        visit(measured)
        let summary = ScanSummary(
            root: rootURL,
            totalLogicalSize: measured.logicalSize,
            totalAllocatedSize: measured.allocatedSize,
            fileCount: measured.fileCount,
            directoryCount: measured.directoryCount,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: categories,
            largestFiles: [],
            largestDirectories: [measured],
            rootChildren: []
        )
        return try XCTUnwrap(LiveTree(scanning: summary))
    }

    // MARK: - The chain

    func testAChainThreeLevelsDeepResolvesFromTheLiveTree() throws {
        let tree = try makeTree()
        let target = rootURL.appendingPathComponent("A/B/C", isDirectory: true)
        let chain = try XCTUnwrap(ExplorerPath.chain(to: target, rootPath: rootURL.path, in: tree))
        XCTAssertEqual(chain.map(\.name), ["A", "B", "C"])
    }

    func testAChainOutsideTheRootResolvesToNothing() throws {
        let tree = try makeTree()
        XCTAssertNil(
            ExplorerPath.chain(to: URL(fileURLWithPath: "/elsewhere/x", isDirectory: true), rootPath: rootURL.path, in: tree)
        )
    }

    func testTheRootItselfIsAnEmptyChain() throws {
        let tree = try makeTree()
        XCTAssertEqual(ExplorerPath.chain(to: rootURL, rootPath: rootURL.path, in: tree)?.count, 0)
    }

    // MARK: - The prune

    func testAThreeLevelBreadcrumbSurvivesAPruneAgainstTheLiveTree() throws {
        let tree = try makeTree()
        let chain = try XCTUnwrap(
            ExplorerPath.chain(
                to: rootURL.appendingPathComponent("A/B/C", isDirectory: true),
                rootPath: rootURL.path,
                in: tree
            )
        )
        let rootChildren = try XCTUnwrap(tree.scanNodes(forChildrenOf: LiveTree.rootID))

        // A materialized node carries no children, which is exactly what the old
        // prune walked: it would have kept only the first crumb.
        let pruned = ExplorerBreadcrumb.pruned(chain, rootNodes: rootChildren, tree: tree)
        XCTAssertEqual(pruned.map(\.name), ["A", "B", "C"])
    }

    func testAPruneStopsAtTheFolderThatIsGone() throws {
        let tree = try makeTree()
        let target = rootURL.appendingPathComponent("A/B/C", isDirectory: true)
        let chain = try XCTUnwrap(ExplorerPath.chain(to: target, rootPath: rootURL.path, in: tree))
        let rootChildren = try XCTUnwrap(tree.scanNodes(forChildrenOf: LiveTree.rootID))

        let deepest = try XCTUnwrap(tree.id(atPath: target.path))
        tree.apply([.remove(id: deepest)])
        XCTAssertEqual(
            ExplorerBreadcrumb.pruned(chain, rootNodes: rootChildren, tree: tree).map(\.name),
            ["A", "B"]
        )

        let middle = try XCTUnwrap(tree.id(atPath: rootURL.appendingPathComponent("A/B").path))
        tree.apply([.remove(id: middle)])
        XCTAssertEqual(
            ExplorerBreadcrumb.pruned(chain, rootNodes: rootChildren, tree: tree).map(\.name),
            ["A"]
        )
    }

    // MARK: - The snapshot path still works

    func testAPruneWithoutATreeWalksTheSnapshotsChildren() throws {
        let root = fixture()
        let target = rootURL.appendingPathComponent("A/B/C", isDirectory: true)
        let chain = try XCTUnwrap(ExplorerPath.chain(to: target, from: root))
        XCTAssertEqual(chain.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(
            ExplorerBreadcrumb.pruned(chain, rootNodes: root.children).map(\.name),
            ["A", "B", "C"]
        )
    }
}
