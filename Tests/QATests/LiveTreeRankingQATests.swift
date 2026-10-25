import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The live ranking answers the same question the scan's ranked lists did, over
/// the tree as it stands now.
final class LiveTreeRankingQATests: XCTestCase {

    private let rootURL = URL(fileURLWithPath: "/scan", isDirectory: true)

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

    private func makeTree() throws -> LiveTree {
        let root = folder(
            "/scan",
            [
                file("/scan/a.bin", size: 10),
                folder("/scan/A", [file("/scan/A/b.bin", size: 30)]),
                folder("/scan/B", [file("/scan/B/c.bin", size: 20)]),
            ]
        )
        var categories: [FileCategory: Int64] = [:]
        root.children.forEach { child in
            if child.isDirectory {
                child.children.forEach { categories[$0.category, default: 0] += $0.logicalSize }
            } else {
                categories[child.category, default: 0] += child.logicalSize
            }
        }
        let summary = ScanSummary(
            root: rootURL,
            totalLogicalSize: root.logicalSize,
            totalAllocatedSize: root.allocatedSize,
            fileCount: root.fileCount,
            directoryCount: root.directoryCount,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: categories,
            largestFiles: [],
            largestDirectories: [root],
            rootChildren: []
        )
        return try XCTUnwrap(LiveTree(scanning: summary))
    }

    func testTheRankingNamesTheLargestEntriesBelowTheRoot() throws {
        let tree = try makeTree()
        let top = try XCTUnwrap(LiveTreeRanking.topEntries(in: tree, limit: 2))
        XCTAssertEqual(top.files.map(\.name), ["b.bin", "c.bin"])
        XCTAssertEqual(top.directories.map(\.name), ["A", "B"], "the scanned root is not one of its own folders")
    }

    func testTheRankingHonoursItsLimitAndStopsWhenCancelled() throws {
        let tree = try makeTree()
        let top = try XCTUnwrap(LiveTreeRanking.topEntries(in: tree, limit: 1))
        XCTAssertEqual(top.files.map(\.name), ["b.bin"])
        XCTAssertEqual(top.directories.map(\.name), ["A"])
        XCTAssertNil(
            LiveTreeRanking.topEntries(in: tree, isCancelled: { true }),
            "a cancelled ranking reports nothing rather than a partial answer"
        )
    }
}
