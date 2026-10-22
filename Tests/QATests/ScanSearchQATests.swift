import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies the whole-scan search finds names anywhere in the tree, stays
/// bounded, and never presents a partial walk as a complete answer.
final class ScanSearchQATests: XCTestCase {

    private let megabyte: Int64 = 1_000_000

    func testFindsANameDeepInTheTree() throws {
        let root = directory("/scan", children: [
            directory("/scan/Photos", children: [
                directory("/scan/Photos/2024", children: [
                    file("/scan/Photos/2024/holiday.jpg", size: 300 * megabyte, category: .images),
                ]),
            ]),
            file("/scan/readme.txt", size: 1, category: .documents),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "holiday", searching: root.children)
        )

        XCTAssertEqual(result.matches.map(\.url.lastPathComponent), ["holiday.jpg"])
        XCTAssertEqual(result.matchCount, 1)
        XCTAssertFalse(result.isTruncated)
        XCTAssertFalse(result.stoppedAtLimit)
    }

    func testMatchesFoldersAsWellAsFiles() throws {
        let root = directory("/scan", children: [
            directory("/scan/Projects", children: [
                file("/scan/Projects/notes.md", size: 12_000, category: .documents),
            ]),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "projects", searching: root.children)
        )

        XCTAssertEqual(result.matches.map(\.name), ["Projects"])
        XCTAssertEqual(result.matchCount, 1)
    }

    func testMatchingIgnoresCaseAndDiacritics() throws {
        let root = directory("/scan", children: [
            file("/scan/Café.jpg", size: 2 * megabyte, category: .images),
            file("/scan/other.png", size: megabyte, category: .images),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "CAFE", searching: root.children)
        )

        XCTAssertEqual(result.matches.map(\.name), ["Café.jpg"])
    }

    func testKeepsTheLargestMatchesAndCountsEveryOne() throws {
        let root = directory("/scan", children: [
            file("/scan/a.bin", size: 3 * megabyte, category: .other),
            file("/scan/b.bin", size: 2 * megabyte, category: .other),
            file("/scan/c.bin", size: megabyte, category: .other),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: ".bin", searching: root.children, limit: 2)
        )

        XCTAssertEqual(result.matches.map(\.name), ["a.bin", "b.bin"])
        XCTAssertEqual(result.matchCount, 3)
        XCTAssertTrue(result.isTruncated)
    }

    func testEqualSizesAreOrderedByPath() throws {
        let root = directory("/scan", children: [
            file("/scan/b/same.bin", size: megabyte, category: .other),
            file("/scan/a/same.bin", size: megabyte, category: .other),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "same", searching: root.children)
        )

        XCTAssertEqual(result.matches.map(\.url.path), [
            "/scan/a/same.bin",
            "/scan/b/same.bin",
        ])
    }

    func testStoppingAtTheNodeCapIsDisclosed() throws {
        let children = (0..<6).map {
            file("/scan/\($0).jpg", size: 1, category: .images)
        }
        let root = directory("/scan", children: children)

        let result = try XCTUnwrap(
            ScanSearch.results(for: "jpg", searching: root.children, maxVisitedNodes: 2)
        )

        XCTAssertTrue(result.stoppedAtLimit)
        XCTAssertEqual(result.visitedCount, 2)
    }

    func testCancellingStopsTheWalk() {
        let root = directory("/scan", children: [
            file("/scan/a.jpg", size: 1, category: .images),
        ])

        XCTAssertNil(ScanSearch.results(
            for: "a",
            searching: root.children,
            isCancelled: { true }
        ))
    }

    func testAnEmptyQueryFindsNothing() throws {
        let root = directory("/scan", children: [
            file("/scan/a.jpg", size: 1, category: .images),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "   ", searching: root.children)
        )

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.matchCount, 0)
        XCTAssertEqual(result.visitedCount, 0)
    }

    func testTheScannedRootIsNotOneOfItsOwnResults() throws {
        let root = directory("/scan", children: [
            file("/scan/readme.txt", size: 1, category: .documents),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "scan", searching: root.children)
        )

        XCTAssertTrue(result.matches.isEmpty)
    }

    func testAnEntryWithNoBytesIsStillFoundByName() throws {
        let root = directory("/scan", children: [
            file("/scan/empty.log", size: 0, category: .other),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "empty", searching: root.children)
        )

        XCTAssertEqual(result.matches.map(\.name), ["empty.log"])
    }

    func testABareWordDoesNotMatchPaths() throws {
        let root = directory("/scan", children: [
            directory("/scan/photos", children: [
                file("/scan/photos/holiday.jpg", size: 2 * megabyte, category: .images),
            ]),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "photos", searching: root.children)
        )

        // The folder matches by name; the file under it does not, because a bare
        // word is not a path query.
        XCTAssertEqual(result.matches.map(\.name), ["photos"])
    }

    func testAQueryWithASeparatorMatchesPaths() throws {
        let root = directory("/scan", children: [
            directory("/scan/Photos", children: [
                directory("/scan/Photos/2024", children: [
                    file("/scan/Photos/2024/holiday.jpg", size: 2 * megabyte, category: .images),
                ]),
                directory("/scan/Photos/2023", children: [
                    file("/scan/Photos/2023/winter.jpg", size: megabyte, category: .images),
                ]),
            ]),
        ])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "photos/2024", searching: root.children)
        )

        XCTAssertEqual(Set(result.matches.map(\.name)), ["2024", "holiday.jpg"])
    }

    func testASymbolicLinkIsNamedButNotFollowed() throws {
        let link = ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: "/scan/current"),
            name: "current",
            isDirectory: true,
            isSymlink: true,
            category: .other,
            logicalSize: 10,
            allocatedSize: 0,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: [file("/scan/current/hidden-match.txt", size: 10, category: .other)]
        )
        let root = directory("/scan", children: [link])

        let result = try XCTUnwrap(
            ScanSearch.results(for: "current", searching: root.children)
        )

        XCTAssertEqual(result.matches.map(\.name), ["current"])

        let child = try XCTUnwrap(
            ScanSearch.results(for: "hidden-match", searching: root.children)
        )
        XCTAssertTrue(child.matches.isEmpty)
    }

    func testASearchOutranksTheModeItWasTypedIn() {
        // The query covers the scan, so Categories gives its category list up for
        // the matches the way every other mode does.
        XCTAssertEqual(
            ExplorerListSource.resolve(isSearchActive: true, mode: .categories),
            .searchMatches
        )
        XCTAssertEqual(
            ExplorerListSource.resolve(isSearchActive: true, mode: .topFiles),
            .searchMatches
        )
        XCTAssertEqual(
            ExplorerListSource.resolve(isSearchActive: false, mode: .categories),
            .categoryFiles
        )
        XCTAssertEqual(
            ExplorerListSource.resolve(isSearchActive: false, mode: .folder),
            .nodeList
        )
        XCTAssertEqual(
            ExplorerListSource.resolve(isSearchActive: false, mode: .topFolders),
            .nodeList
        )
    }

    // MARK: - Fixtures

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
            fileCount: children.filter { !$0.isDirectory }.count,
            directoryCount: 1,
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
