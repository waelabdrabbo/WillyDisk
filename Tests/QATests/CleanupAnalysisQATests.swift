import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies the cleanup heuristics: what they include, what they refuse to
/// include, and the limits they disclose.
final class CleanupAnalysisQATests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let megabyte: Int64 = 1_000_000

    // MARK: - Large and old

    func testLargeOldFilesOnly() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let recent = now.addingTimeInterval(-10 * 24 * 3600)
        let root = directory("/scan", children: [
            file("/scan/big-old.bin", size: 600 * megabyte, modified: old),
            file("/scan/big-new.bin", size: 600 * megabyte, modified: recent),
            file("/scan/small-old.bin", size: 100 * megabyte, modified: old),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: root, now: now))
        let group = try XCTUnwrap(report.groups.first { $0.kind == .largeAndOld })

        XCTAssertEqual(group.matchCount, 1)
        XCTAssertEqual(group.candidates.map(\.name), ["big-old.bin"])
    }

    func testAFolderIsNeverOfferedAsALargeOldFile() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            directory("/scan/archive", size: 5_000 * megabyte, modified: old, children: []),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: root, now: now))
        XCTAssertTrue(try XCTUnwrap(report.groups.first { $0.kind == .largeAndOld }).candidates.isEmpty)
    }

    // MARK: - Caches

    func testACacheFolderIsOfferedWholeAndItsContentsAreNotListedTwice() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let cacheFile = file("/scan/Library/Caches/com.example/blob.bin",
                             size: 700 * megabyte, modified: old)
        let caches = directory("/scan/Library/Caches",
                               size: 700 * megabyte, children: [cacheFile])
        let library = directory("/scan/Library", size: 700 * megabyte, children: [caches])
        let document = file("/scan/Documents/big.bin", size: 600 * megabyte, modified: old)
        let root = directory("/scan", children: [library, document])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: root, now: now))
        let cacheGroup = try XCTUnwrap(report.groups.first { $0.kind == .caches })
        let largeGroup = try XCTUnwrap(report.groups.first { $0.kind == .largeAndOld })

        XCTAssertEqual(cacheGroup.candidates.map(\.name), ["Caches"])
        XCTAssertEqual(cacheGroup.candidates.first?.isDirectory, true)
        XCTAssertEqual(cacheGroup.candidates.first?.logicalSize, 700 * megabyte)
        XCTAssertEqual(largeGroup.candidates.map(\.name), ["big.bin"],
                       "the cache's file must not be listed again as large and old")
    }

    func testTheScanRootIsNeverSuggestedEvenWhenItIsACache() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let appCache = file("/Users/me/Library/Caches/com.example/blob.bin",
                            size: 700 * megabyte, modified: old)
        let sub = directory("/Users/me/Library/Caches/com.example",
                            size: 700 * megabyte, children: [appCache])
        let root = directory("/Users/me/Library/Caches", size: 700 * megabyte,
                             children: [sub])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: root, now: now))
        XCTAssertTrue(try XCTUnwrap(report.groups.first { $0.kind == .caches }).candidates.isEmpty)
    }

    func testDerivedDataIsRecognisedAsACache() throws {
        let derived = directory("/scan/Library/Developer/Xcode/DerivedData",
                                size: 2_000 * megabyte,
                                children: [])
        let xcode = directory("/scan/Library/Developer/Xcode", size: 2_000 * megabyte,
                              children: [derived])
        let developer = directory("/scan/Library/Developer", size: 2_000 * megabyte,
                                  children: [xcode])
        let library = directory("/scan/Library", size: 2_000 * megabyte, children: [developer])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: directory("/scan", children: [library]), now: now))
        let cacheGroup = try XCTUnwrap(report.groups.first { $0.kind == .caches })
        XCTAssertEqual(cacheGroup.candidates.map(\.name), ["DerivedData"])
    }

    // MARK: - Downloads

    func testOldFilesInADownloadsFolderOnly() throws {
        let old = now.addingTimeInterval(-200 * 24 * 3600)
        let recent = now.addingTimeInterval(-2 * 24 * 3600)
        let downloads = directory("/scan/Downloads", children: [
            file("/scan/Downloads/old.zip", size: 200 * megabyte, modified: old),
            file("/scan/Downloads/new.zip", size: 200 * megabyte, modified: recent),
        ])
        let documents = directory("/scan/Documents", children: [
            file("/scan/Documents/old.pdf", size: 200 * megabyte, modified: old),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: directory("/scan", children: [downloads, documents]), now: now))
        let group = try XCTUnwrap(report.groups.first { $0.kind == .downloads })

        XCTAssertEqual(group.matchCount, 1)
        XCTAssertEqual(group.candidates.map(\.name), ["old.zip"])
    }

    // MARK: - Limits and honesty

    func testTheCapKeepsTheLargestButCountsEveryMatch() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            file("/scan/a.bin", size: 600 * megabyte, modified: old),
            file("/scan/b.bin", size: 700 * megabyte, modified: old),
            file("/scan/c.bin", size: 800 * megabyte, modified: old),
        ])
        let policy = CleanupPolicy(maxCandidatesPerGroup: 2)

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: root, policy: policy, now: now))
        let group = try XCTUnwrap(report.groups.first { $0.kind == .largeAndOld })

        XCTAssertEqual(group.matchCount, 3)
        XCTAssertEqual(group.candidates.map(\.name), ["c.bin", "b.bin"])
        XCTAssertTrue(group.isTruncated)
        XCTAssertEqual(group.totalLogicalSize, 2_100 * megabyte,
                       "the total covers every match, not just the shown two")
    }

    func testStoppingAtTheNodeCapIsDisclosed() throws {
        let children = (0..<5).map { file("/scan/\($0).bin", size: 1, modified: now) }
        let policy = CleanupPolicy(maxVisitedNodes: 2)

        let report = try XCTUnwrap(
            CleanupAnalysis.analyze(root: directory("/scan", children: children), policy: policy, now: now)
        )

        XCTAssertTrue(report.stoppedAtLimit)
        XCTAssertLessThanOrEqual(report.visitedCount, policy.maxVisitedNodes + 1)
    }

    func testCancellingStopsTheWalk() {
        let root = directory("/scan", children: [file("/scan/a.bin", size: 1, modified: now)])
        XCTAssertNil(CleanupAnalysis.analyze(root: root, now: now, isCancelled: { true }))
    }

    func testSymlinksAreNeverCandidates() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let link = ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: "/scan/link.bin"),
            name: "link.bin",
            isDirectory: false,
            isSymlink: true,
            category: .other,
            logicalSize: 900 * megabyte,
            allocatedSize: 0,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: old,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )

        let report = try XCTUnwrap(CleanupAnalysis.analyze(root: directory("/scan", children: [link]), now: now))
        XCTAssertTrue(report.isEmpty)
    }

    func testThresholdsAreStatedByThePolicy() {
        let policy = CleanupPolicy.standard
        XCTAssertGreaterThan(policy.largeFileMinimum, 0)
        XCTAssertGreaterThan(policy.largeFileAge, 0)
        XCTAssertGreaterThan(policy.downloadAge, 0)
        XCTAssertGreaterThan(policy.maxCandidatesPerGroup, 0)
        XCTAssertGreaterThan(policy.maxVisitedNodes, 0)
    }

    // MARK: - Fixtures

    private func directory(
        _ path: String,
        size: Int64 = 0,
        modified: Date? = nil,
        children: [ScanNode]
    ) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path, isDirectory: true),
            name: (path as NSString).lastPathComponent,
            isDirectory: true,
            isSymlink: false,
            category: .other,
            logicalSize: size,
            allocatedSize: size,
            fileCount: children.filter { !$0.isDirectory }.count,
            directoryCount: 1,
            modifiedAt: modified,
            isAccessible: true,
            errorMessage: nil,
            children: children
        )
    }

    private func file(_ path: String, size: Int64, modified: Date?) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: false,
            isSymlink: false,
            category: .other,
            logicalSize: size,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: modified,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }
}
