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

    // MARK: - The live tree

    func testALiveSearchFindsTheSameNamesAsTheScansOwnTree() throws {
        let root = directory("/scan", children: [
            directory("/scan/Photos", children: [
                directory("/scan/Photos/2024", children: [
                    file("/scan/Photos/2024/holiday.jpg", size: 300 * megabyte, category: .images),
                ]),
                file("/scan/Photos/holiday-2023.jpg", size: 100 * megabyte, category: .images),
            ]),
            file("/scan/readme.txt", size: 1, category: .documents),
        ])
        let tree = try makeTree(root)

        let fromScan = try XCTUnwrap(ScanSearch.results(for: "HOLIDAY", searching: root.children))
        let fromTree = try XCTUnwrap(ScanSearch.results(for: "HOLIDAY", in: tree))

        XCTAssertEqual(Set(fromTree.matches.map(\.url.path)), Set(fromScan.matches.map(\.url.path)))
        XCTAssertEqual(fromTree.matchCount, fromScan.matchCount)
        XCTAssertEqual(fromTree.visitedCount, fromScan.visitedCount)
    }

    func testALivePathQueryMatchesTheFullPath() throws {
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
        let tree = try makeTree(root)

        let fromScan = try XCTUnwrap(
            ScanSearch.results(for: "Photos/2024", searching: root.children)
        )
        let fromTree = try XCTUnwrap(ScanSearch.results(for: "Photos/2024", in: tree))

        XCTAssertEqual(Set(fromTree.matches.map(\.url.path)), Set(fromScan.matches.map(\.url.path)))
        XCTAssertEqual(fromTree.matches.map(\.name).sorted(), ["2024", "holiday.jpg"])
        XCTAssertEqual(fromTree.matchCount, 2)
    }

    func testALiveSearchIsCaseAndDiacriticInsensitive() throws {
        let root = directory("/scan", children: [
            file("/scan/Café.jpg", size: 2 * megabyte, category: .images),
            file("/scan/library.json", size: megabyte, category: .documents),
            file("/scan/other.png", size: megabyte, category: .images),
        ])
        let tree = try makeTree(root)

        let accented = try XCTUnwrap(ScanSearch.results(for: "CAFE", in: tree))
        XCTAssertEqual(accented.matches.map(\.name), ["Café.jpg"])

        let ascii = try XCTUnwrap(ScanSearch.results(for: "LIBRARY", in: tree))
        XCTAssertEqual(ascii.matches.map(\.name), ["library.json"])
    }

    func testALiveSearchKeepsTheLargestMatchesAndCountsEveryOne() throws {
        let root = directory("/scan", children: [
            file("/scan/a.jpg", size: 3 * megabyte, category: .images),
            file("/scan/b.jpg", size: 2 * megabyte, category: .images),
            file("/scan/c.jpg", size: megabyte, category: .images),
            file("/scan/d.jpg", size: 4 * megabyte, category: .images),
        ])
        let tree = try makeTree(root)

        let result = try XCTUnwrap(ScanSearch.results(for: "jpg", in: tree, limit: 2))
        XCTAssertEqual(result.matches.map(\.name), ["d.jpg", "a.jpg"])
        XCTAssertEqual(result.matchCount, 4)
        XCTAssertTrue(result.isTruncated)
        XCTAssertEqual(result.visitedCount, 4)
    }

    func testALiveSearchStopsAtItsNodeCapAndSaysSo() throws {
        let root = directory("/scan", children: [
            file("/scan/a.jpg", size: 1, category: .images),
            file("/scan/b.jpg", size: 1, category: .images),
            file("/scan/c.jpg", size: 1, category: .images),
        ])
        let tree = try makeTree(root)

        let result = try XCTUnwrap(
            ScanSearch.results(for: "jpg", in: tree, maxVisitedNodes: 2)
        )
        XCTAssertTrue(result.stoppedAtLimit)
        XCTAssertEqual(result.visitedCount, 2)
        XCTAssertEqual(result.matchCount, 2)
    }

    func testALiveSearchCanBeCancelled() throws {
        let root = directory("/scan", children: [
            file("/scan/a.jpg", size: 1, category: .images),
        ])
        let tree = try makeTree(root)
        XCTAssertNil(ScanSearch.results(for: "a", in: tree, isCancelled: { true }))
    }

    func testTheFastComparisonAgreesWithTheUnicodeOneOnEveryName() throws {
        // ASCII folding answers most names; the Unicode comparison answers the
        // rest and is the reference this walk is held to.
        let names = [
            "library.json", "LIBRARY", "Librarian.md", "Café.jpg", "cafe.txt",
            "naïve-library", "über", "İstanbul", "ﬁle.txt", "a", "A", "b",
        ]
        let root = directory("/scan", children: names.enumerated().map { index, name in
            file("/scan/\(name)", size: Int64(index + 1) * 1_000, category: .other)
        })
        let tree = try makeTree(root)

        for query in ["library", "CAFE", "naive", "istanbul", "i", "file", "ÜBER"] {
            let expected = Set(names.filter {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            })
            let result = try XCTUnwrap(ScanSearch.results(for: query, in: tree))
            XCTAssertEqual(Set(result.matches.map(\.name)), expected, "matches for “\(query)”")
            XCTAssertEqual(result.matchCount, expected.count)
        }
    }

    func testALimitedLiveSearchAgreesWithTheScansOwnTree() throws {
        // Enough entries that the list is trimmed, with repeating sizes so equal
        // sizes fall back to the path order both walks use.
        let root = directory("/scan", children: (0..<60).map { index in
            file("/scan/entry-\(index).bin", size: Int64((index * 37) % 11), category: .other)
        })
        let tree = try makeTree(root)

        let fromScan = try XCTUnwrap(
            ScanSearch.results(for: "entry", searching: root.children, limit: 5)
        )
        let fromTree = try XCTUnwrap(ScanSearch.results(for: "entry", in: tree, limit: 5))

        XCTAssertEqual(fromTree.matches.map(\.url.path), fromScan.matches.map(\.url.path))
        XCTAssertEqual(fromTree.matchCount, fromScan.matchCount)
        XCTAssertTrue(fromTree.isTruncated)
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

    /// The same fixture as a tree the screen reads, so a test can check the two
    /// walks answer alike. The fixture's folders do not carry their subtree's
    /// counts, and a tree refuses a summary that disagrees with it, so the tree is
    /// built from the same nodes measured whole.
    private func makeTree(_ root: ScanNode) throws -> LiveTree {
        let measuredRoot = measured(root)
        var categories: [FileCategory: Int64] = [:]
        func addCategories(_ node: ScanNode) {
            if node.isDirectory {
                node.children.forEach(addCategories)
            } else {
                categories[node.category, default: 0] += node.logicalSize
            }
        }
        addCategories(measuredRoot)

        return try XCTUnwrap(LiveTree(scanning: ScanSummary(
            root: measuredRoot.url,
            totalLogicalSize: measuredRoot.logicalSize,
            totalAllocatedSize: measuredRoot.allocatedSize,
            fileCount: measuredRoot.fileCount,
            directoryCount: measuredRoot.directoryCount,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: categories,
            largestFiles: [],
            largestDirectories: [measuredRoot],
            rootChildren: []
        )))
    }

    private func measured(_ node: ScanNode) -> ScanNode {
        guard node.isDirectory else { return node }
        let children = node.children.map(measured)
        return ScanNode(
            id: node.id,
            url: node.url,
            name: node.name,
            isDirectory: true,
            isSymlink: node.isSymlink,
            category: node.category,
            logicalSize: children.reduce(0) { $0 + $1.logicalSize },
            allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            directoryCount: 1 + children.reduce(0) { $0 + $1.directoryCount },
            modifiedAt: node.modifiedAt,
            isAccessible: node.isAccessible,
            errorMessage: node.errorMessage,
            children: children
        )
    }
}
