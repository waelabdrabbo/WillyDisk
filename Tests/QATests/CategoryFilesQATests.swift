import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies that opening a category lists the right files from the scan's tree.
final class CategoryFilesQATests: XCTestCase {

    private let megabyte: Int64 = 1_000_000

    func testOnlyTheCategorysFilesAreListedLargestFirst() throws {
        let root = directory("/scan", children: [
            file("/scan/Photos/big.jpg", size: 300 * megabyte, category: .images),
            file("/scan/Photos/small.png", size: 40 * megabyte, category: .images),
            file("/scan/Documents/report.pdf", size: 500 * megabyte, category: .documents),
        ])

        let result = try XCTUnwrap(CategoryFileIndex.largest(filesOf: .images, in: tree(root)))

        XCTAssertEqual(result.files.map(\.name), ["big.jpg", "small.png"])
        XCTAssertEqual(result.matchCount, 2)
        XCTAssertEqual(result.totalLogicalSize, 340 * megabyte)
        XCTAssertFalse(result.isTruncated)
    }

    func testEveryMatchIsCountedEvenWhenTheListIsCapped() throws {
        let root = directory("/scan", children: [
            file("/scan/a.bin", size: 3 * megabyte, category: .images),
            file("/scan/b.bin", size: 2 * megabyte, category: .images),
            file("/scan/c.bin", size: 1 * megabyte, category: .images),
        ])

        let result = try XCTUnwrap(
            CategoryFileIndex.largest(filesOf: .images, in: tree(root), limit: 2)
        )

        XCTAssertEqual(result.files.map(\.name), ["a.bin", "b.bin"])
        XCTAssertEqual(result.matchCount, 3)
        XCTAssertEqual(result.totalLogicalSize, 6 * megabyte)
        XCTAssertTrue(result.isTruncated)
    }

    func testStoppingAtTheNodeCapIsDisclosed() throws {
        let children = (0..<6).map {
            file("/scan/\($0).jpg", size: 1, category: .images)
        }
        let root = directory("/scan", children: children)

        let result = try XCTUnwrap(
            CategoryFileIndex.largest(filesOf: .images, in: tree(root), maxVisitedNodes: 2)
        )

        XCTAssertTrue(result.stoppedAtLimit)
        XCTAssertLessThanOrEqual(result.visitedCount, 3)
    }

    func testCancellingStopsTheWalk() throws {
        let root = directory("/scan", children: [
            file("/scan/a.jpg", size: 1, category: .images),
        ])
        let live = try tree(root)

        XCTAssertNil(CategoryFileIndex.largest(
            filesOf: .images,
            in: live,
            isCancelled: { true }
        ))
    }

    func testSymlinksAreNeverListed() throws {
        let link = ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: "/scan/link.jpg"),
            name: "link.jpg",
            isDirectory: false,
            isSymlink: true,
            category: .images,
            logicalSize: 900 * megabyte,
            allocatedSize: 0,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
        let root = directory("/scan", children: [link])

        let result = try XCTUnwrap(CategoryFileIndex.largest(filesOf: .images, in: tree(root)))
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.matchCount, 0)
    }

    func testACategoryWithNoFilesReportsNothing() throws {
        let root = directory("/scan", children: [
            file("/scan/report.pdf", size: 10, category: .documents),
        ])

        let result = try XCTUnwrap(CategoryFileIndex.largest(filesOf: .images, in: tree(root)))
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.matchCount, 0)
        XCTAssertEqual(result.totalLogicalSize, 0)
    }

    // MARK: - Fixtures

    /// The live tree a fixture root describes; a folder's counts are its
    /// children's, as the arena requires.
    private func tree(
        _ root: ScanNode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LiveTree {
        var categories: [FileCategory: Int64] = [:]
        func visit(_ node: ScanNode) {
            if !node.isDirectory, node.fileCount > 0 {
                categories[node.category, default: 0] += node.logicalSize
            }
            node.children.forEach(visit)
        }
        visit(root)
        let summary = ScanSummary(
            root: root.url,
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
        return try XCTUnwrap(LiveTree(scanning: summary), file: file, line: line)
    }

    private func directory(_ path: String, children: [ScanNode]) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path, isDirectory: true),
            name: (path as NSString).lastPathComponent,
            isDirectory: true,
            isSymlink: false,
            category: .other,
            logicalSize: children.reduce(0) { $0 + $1.logicalSize },
            allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            directoryCount: 1 + children.reduce(0) { $0 + $1.directoryCount },
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: children
        )
    }

    private func file(_ path: String, size: Int64, category: FileCategory) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: false,
            isSymlink: false,
            category: category,
            logicalSize: size,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }
}
