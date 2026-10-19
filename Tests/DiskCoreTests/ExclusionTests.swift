import XCTest
import Foundation
@testable import DiskCore

/// Scanner tests for request exclusions.
///
/// Excluded entries are not measured, so the only honest report is that they
/// were left out: no size is invented for them, and the totals never include
/// bytes the walk did not visit.
final class ExclusionTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskExclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ byteCount: Int, to url: URL) throws {
        try Data(repeating: 0x61, count: byteCount).write(to: url)
    }

    private func finish(_ request: ScanRequest) async -> ScanSummary? {
        let collector = await runScanner(request)
        return collector.finished
    }

    func testNestedDirectoryAndFileExclusionsArePrunedAndCounted() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(10, to: root.appendingPathComponent("keep.txt"))
        let keptDir = root.appendingPathComponent("Kept")
        try FileManager.default.createDirectory(at: keptDir, withIntermediateDirectories: true)
        try write(20, to: keptDir.appendingPathComponent("inner.txt"))

        let excludedDir = root.appendingPathComponent("Excluded")
        try FileManager.default.createDirectory(at: excludedDir, withIntermediateDirectories: true)
        try write(100, to: excludedDir.appendingPathComponent("big.bin"))
        let nested = excludedDir.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(200, to: nested.appendingPathComponent("deeper.bin"))

        let excludedFile = root.appendingPathComponent("skip.txt")
        try write(50, to: excludedFile)

        let request = ScanRequest(
            root: root,
            excludedPaths: [excludedDir, excludedFile]
        )
        let finished = await finish(request)
        let summary = try XCTUnwrap(finished)

        XCTAssertEqual(summary.totalLogicalSize, 30)
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(summary.directoryCount, 2)
        XCTAssertEqual(summary.accounting.excludedItemCount, 2)
    }

    func testExcludingTheScanRootOrItsAncestorIsIgnored() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(10, to: root.appendingPathComponent("keep.txt"))

        let rootFinished = await finish(ScanRequest(root: root, excludedPaths: [root]))
        let whenRoot = try XCTUnwrap(rootFinished)
        XCTAssertEqual(whenRoot.totalLogicalSize, 10)
        XCTAssertEqual(whenRoot.accounting.excludedItemCount, 0)

        let ancestor = root.deletingLastPathComponent()
        let ancestorFinished = await finish(ScanRequest(root: root, excludedPaths: [ancestor]))
        let whenAncestor = try XCTUnwrap(ancestorFinished)
        XCTAssertEqual(whenAncestor.totalLogicalSize, 10)
        XCTAssertEqual(whenAncestor.accounting.excludedItemCount, 0)
    }

    func testFollowingASymlinkIntoAnExcludedDirectoryDoesNotCountItAgain() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try write(100, to: real.appendingPathComponent("payload.bin"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Link"),
            withDestinationURL: real
        )

        let request = ScanRequest(
            root: root,
            followSymlinks: true,
            excludedPaths: [real]
        )
        let finished = await finish(request)
        let summary = try XCTUnwrap(finished)

        XCTAssertEqual(summary.totalLogicalSize, 0)
        XCTAssertEqual(summary.fileCount, 0)
        XCTAssertEqual(summary.directoryCount, 1)
        XCTAssertEqual(summary.accounting.excludedItemCount, 2)
    }
}
