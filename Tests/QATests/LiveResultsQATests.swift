import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The two questions the results screen asks the whole tree: a search for a name,
/// and a ranking by size. Both must follow the disk, not the scan.
final class LiveResultsQATests: XCTestCase {

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("LiveResultsQA-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> String {
            root.appendingPathComponent(relative).path
        }

        func write(_ bytes: Int, to relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0, count: bytes).write(to: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeTree(_ fixture: Fixture) async throws -> (LiveTree, LiveTreeUpdater) {
        var summary: ScanSummary?
        for await event in FileScanEngine().scan(ScanRequest(root: fixture.root)) {
            if case .finished(let finished) = event { summary = finished }
            if case .cancelled = event { XCTFail("the fixture scan was cancelled") }
        }
        let tree = try XCTUnwrap(LiveTree(scanning: XCTUnwrap(summary)))
        return (tree, LiveTreeUpdater(tree: tree, policy: LiveTreePolicy()))
    }

    // MARK: - Search

    func testSearchFindsAFileCreatedAfterTheScan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "Documents/report.txt")

        let (tree, updater) = try await makeTree(fixture)
        let before = try XCTUnwrap(ScanSearch.results(for: "report", in: tree))
        XCTAssertEqual(before.matches.map(\.name), ["report.txt"])

        try fixture.write(200, to: "Documents/new-report.txt")
        await updater.apply(changedFolders: [fixture.path("Documents")])

        let after = try XCTUnwrap(ScanSearch.results(for: "report", in: tree))
        XCTAssertEqual(after.matches.map(\.name).sorted(), ["new-report.txt", "report.txt"])
        XCTAssertEqual(after.matches.first?.name, "new-report.txt", "largest first")
    }

    func testSearchDoesNotFindAFileThatWasDeleted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "Documents/report.txt")
        try fixture.write(100, to: "Documents/notes.txt")

        let (tree, updater) = try await makeTree(fixture)
        try FileManager.default.removeItem(atPath: fixture.path("Documents/report.txt"))
        await updater.apply(changedFolders: [fixture.path("Documents")])

        let results = try XCTUnwrap(ScanSearch.results(for: "report", in: tree))
        XCTAssertTrue(results.matches.isEmpty)
    }

    func testAPathQueryUsesTheTreesOwnPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "Photos/2024/img.bin")
        try fixture.write(100, to: "Photos/2023/img.bin")

        let (tree, _) = try await makeTree(fixture)
        let results = try XCTUnwrap(ScanSearch.results(for: "Photos/2024", in: tree))
        // The folder's own path matches the query as well as the file inside it.
        XCTAssertEqual(results.matches.map(\.name).sorted(), ["2024", "img.bin"])
        XCTAssertTrue(
            results.matches.contains { $0.url.path == fixture.path("Photos/2024/img.bin") },
            "the match carries the tree's own path"
        )
    }

    func testSearchStopsAtTheVisitedLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for step in 0..<20 {
            try fixture.write(10, to: "Folder/file-\(step).bin")
        }

        let (tree, _) = try await makeTree(fixture)
        let results = try XCTUnwrap(ScanSearch.results(for: "file", in: tree, maxVisitedNodes: 5))
        XCTAssertTrue(results.stoppedAtLimit)
        XCTAssertLessThanOrEqual(results.visitedCount, 5)
    }

    func testSearchIsNilWhenCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "a.bin")

        let (tree, _) = try await makeTree(fixture)
        let results = ScanSearch.results(for: "a", in: tree, isCancelled: { true })
        XCTAssertNil(results)
    }

    // MARK: - Ranking

    func testTheRankingFollowsTheTree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "small.bin")
        try fixture.write(5_000, to: "big.bin")
        try fixture.write(200, to: "Folder/a.bin")
        try fixture.write(10_000, to: "Folder/inside.bin")

        let (tree, updater) = try await makeTree(fixture)
        var top = try XCTUnwrap(LiveTreeRanking.topEntries(in: tree))
        // A ranking covers the whole tree, like the scan's own largest files.
        XCTAssertEqual(top.files.map(\.name), ["inside.bin", "big.bin", "a.bin", "small.bin"])
        XCTAssertEqual(top.directories.map(\.name), ["Folder"])

        // The disk moves: the small file becomes the largest, and a folder
        // arrives with more than the one that was biggest.
        try fixture.write(20_000, to: "small.bin")
        try fixture.write(30_000, to: "Archive/deep.bin")
        await updater.apply(changedFolders: [fixture.root.path])

        top = try XCTUnwrap(LiveTreeRanking.topEntries(in: tree))
        XCTAssertEqual(top.files.map(\.name), ["deep.bin", "small.bin", "inside.bin", "big.bin", "a.bin"])
        XCTAssertEqual(top.directories.map(\.name), ["Archive", "Folder"])
        XCTAssertEqual(top.directories.first?.logicalSize, 30_000)
    }

    func testTheRankingLeavesOutEntriesWithoutBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "file.bin")
        try FileManager.default.createSymbolicLink(
            atPath: fixture.path("link"),
            withDestinationPath: fixture.path("file.bin")
        )

        let (tree, _) = try await makeTree(fixture)
        let top = try XCTUnwrap(LiveTreeRanking.topEntries(in: tree))
        XCTAssertEqual(top.files.map(\.name), ["file.bin"], "a link the scan did not follow has no bytes to rank")
    }

    func testTheRankingIsBoundedAndOrdered() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        for step in 0..<50 {
            try fixture.write(10 + step * 10, to: "file-\(step).bin")
        }

        let (tree, _) = try await makeTree(fixture)
        let top = try XCTUnwrap(LiveTreeRanking.topEntries(in: tree, limit: 10))
        XCTAssertEqual(top.files.count, 10)
        XCTAssertEqual(top.files.first?.name, "file-49.bin")
        XCTAssertEqual(top.files.map(\.logicalSize), top.files.map(\.logicalSize).sorted(by: >))
    }

    func testTheRankingIsNilWhenCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "a.bin")

        let (tree, _) = try await makeTree(fixture)
        XCTAssertNil(LiveTreeRanking.topEntries(in: tree, isCancelled: { true }))
    }
}
