import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies the cleanup heuristics against a live tree: what they include, what
/// they refuse to include, and the limits they disclose.
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

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        let group = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })

        XCTAssertEqual(group.matchCount, 1)
        XCTAssertEqual(group.candidates.map(\.name), ["big-old.bin"])
    }

    func testAFolderIsNeverOfferedAsALargeOldFile() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let recent = now.addingTimeInterval(-10 * 24 * 3600)
        let root = directory("/scan", children: [
            directory("/scan/archive", modified: old, children: [
                file("/scan/archive/recent.bin", size: 5_000 * megabyte, modified: recent),
            ]),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        let group = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })
        XCTAssertTrue(
            group.candidates.isEmpty,
            "a folder's size is its children's; only files are offered as large and old"
        )
    }

    // MARK: - Caches

    func testACacheFolderIsOfferedWholeAndItsContentsAreNotListedTwice() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let cacheFile = file("/scan/Library/Caches/com.example/blob.bin",
                             size: 700 * megabyte, modified: old)
        let caches = directory("/scan/Library/Caches", children: [cacheFile])
        let library = directory("/scan/Library", children: [caches])
        let document = file("/scan/Documents/big.bin", size: 600 * megabyte, modified: old)
        let root = directory("/scan", children: [library, document])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        let cacheGroup = try XCTUnwrap(report.groups.first { $0.rule == .caches })
        let largeGroup = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })

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
        let sub = directory("/Users/me/Library/Caches/com.example", children: [appCache])
        let root = directory("/Users/me/Library/Caches", children: [sub])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        XCTAssertTrue(try XCTUnwrap(report.groups.first { $0.rule == .caches }).candidates.isEmpty)
    }

    func testDerivedDataIsRecognisedAsACache() throws {
        let derived = directory("/scan/Library/Developer/Xcode/DerivedData", children: [
            file("/scan/Library/Developer/Xcode/DerivedData/blob.bin",
                 size: 2_000 * megabyte, modified: now),
        ])
        let xcode = directory("/scan/Library/Developer/Xcode", children: [derived])
        let developer = directory("/scan/Library/Developer", children: [xcode])
        let library = directory("/scan/Library", children: [developer])

        let report = try XCTUnwrap(
            CleanupAnalysis.analyze(in: tree(directory("/scan", children: [library])), now: now)
        )
        let cacheGroup = try XCTUnwrap(report.groups.first { $0.rule == .caches })
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

        let report = try XCTUnwrap(
            CleanupAnalysis.analyze(in: tree(directory("/scan", children: [downloads, documents])), now: now)
        )
        let group = try XCTUnwrap(report.groups.first { $0.rule == .downloads })

        XCTAssertEqual(group.matchCount, 1)
        XCTAssertEqual(group.candidates.map(\.name), ["old.zip"])
    }

    // MARK: - Duplicate candidates

    func testSameSizeFilesAtLeastOneMegabyteBecomeDuplicateCandidates() throws {
        let root = directory("/scan", children: [
            file("/scan/a.bin", size: 2 * megabyte, modified: now),
            file("/scan/b.bin", size: 2 * megabyte, modified: now),
            file("/scan/single.bin", size: 3 * megabyte, modified: now),
            file("/scan/small-a.bin", size: megabyte - 1, modified: now),
            file("/scan/small-b.bin", size: megabyte - 1, modified: now),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        XCTAssertEqual(report.duplicateGroupCount, 1)
        let group = try XCTUnwrap(report.duplicateGroups.first)
        XCTAssertEqual(group.logicalSize, 2 * megabyte)
        XCTAssertEqual(group.candidates.map(\.name), ["a.bin", "b.bin"])
        XCTAssertEqual(group.matchCount, 2)
        XCTAssertFalse(group.isTruncated)
    }

    func testARepeatedSizeBelowTheDuplicateMinimumIsNotACandidate() throws {
        let root = directory("/scan", children: [
            file("/scan/small-a.bin", size: megabyte - 1, modified: now),
            file("/scan/small-b.bin", size: megabyte - 1, modified: now),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        XCTAssertTrue(report.duplicateGroups.isEmpty)
        XCTAssertEqual(report.duplicateGroupCount, 0)
    }

    func testDuplicateGroupCapCountsEveryFileAndReportsTruncation() throws {
        let root = directory("/scan", children: (0..<4).map {
            file("/scan/\($0).bin", size: 4 * megabyte, modified: now)
        })
        let policy = CleanupPolicy(maxDuplicateFilesPerGroup: 2)

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), policy: policy, now: now))
        let group = try XCTUnwrap(report.duplicateGroups.first)

        XCTAssertEqual(group.matchCount, 4)
        XCTAssertEqual(group.candidates.count, 2)
        XCTAssertTrue(group.isTruncated)
        XCTAssertEqual(report.duplicateCandidateCount, 4)
        XCTAssertEqual(report.duplicateFileCount, 4)
    }

    func testDuplicateGroupCapKeepsTheLargestSizesAndCountsEveryGroup() throws {
        let root = directory("/scan", children: [
            file("/scan/small-a.bin", size: 5 * megabyte, modified: now),
            file("/scan/small-b.bin", size: 5 * megabyte, modified: now),
            file("/scan/large-a.bin", size: 10 * megabyte, modified: now),
            file("/scan/large-b.bin", size: 10 * megabyte, modified: now),
        ])
        let policy = CleanupPolicy(maxDuplicateGroups: 1)

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), policy: policy, now: now))

        XCTAssertEqual(report.duplicateGroupCount, 2)
        XCTAssertEqual(report.duplicateGroups.count, 1)
        XCTAssertEqual(report.duplicateGroups.first?.logicalSize, 10 * megabyte)
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

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), policy: policy, now: now))
        let group = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })

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
            CleanupAnalysis.analyze(in: tree(directory("/scan", children: children)), policy: policy, now: now)
        )

        XCTAssertTrue(report.stoppedAtLimit)
        XCTAssertLessThanOrEqual(report.visitedCount, policy.maxVisitedNodes + 1)
    }

    func testCancellingStopsTheWalk() throws {
        let root = directory("/scan", children: [file("/scan/a.bin", size: 1, modified: now)])
        let live = try tree(root)
        XCTAssertNil(CleanupAnalysis.analyze(in: live, now: now, isCancelled: { true }))
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
            logicalSize: 0,
            allocatedSize: 0,
            fileCount: 0,
            directoryCount: 0,
            modifiedAt: old,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(directory("/scan", children: [link])), now: now))
        XCTAssertTrue(report.isEmpty)
    }

    func testThresholdsAreStatedByThePolicy() {
        let policy = CleanupPolicy.standard
        XCTAssertGreaterThan(policy.largeFileMinimum, 0)
        XCTAssertGreaterThan(policy.largeFileAge, 0)
        XCTAssertGreaterThan(policy.downloadAge, 0)
        XCTAssertGreaterThan(policy.maxCandidatesPerGroup, 0)
        XCTAssertGreaterThan(policy.duplicateMinimum, 0)
        XCTAssertGreaterThan(policy.maxDuplicateGroups, 0)
        XCTAssertGreaterThan(policy.maxDuplicateFilesPerGroup, 1)
        XCTAssertEqual(policy.maxVisitedNodes, 10_000_000,
                       "the cleanup walk is the only pass that has to see every entry")
    }

    // MARK: - Local bytes

    func testAnEvictedFileIsNotALargeOldCandidate() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            file("/scan/evicted.bin", size: 600 * megabyte, allocated: 0, modified: old),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        XCTAssertTrue(report.isEmpty, "moving an item with no local bytes frees nothing")
    }

    func testAFileMustFreeTheThresholdToBeOffered() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            file("/scan/sparse.bin", size: 600 * megabyte, allocated: 400 * megabyte, modified: old),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        let group = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })

        XCTAssertEqual(group.matchCount, 0, "it is at least 500 MB logically, but not on disk")
    }

    func testAnOfferedFileReportsTheBytesItWouldFree() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            file("/scan/thin.bin", size: 600 * megabyte, allocated: 550 * megabyte, modified: old),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))
        let group = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })

        XCTAssertEqual(group.candidates.first?.logicalSize, 600 * megabyte)
        XCTAssertEqual(group.candidates.first?.allocatedSize, 550 * megabyte)
        XCTAssertEqual(group.totalAllocatedSize, 550 * megabyte)
        XCTAssertEqual(group.totalLogicalSize, 600 * megabyte)
    }

    // MARK: - The walk

    func testTheWalkVisitsTheLargestFoldersFirst() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            directory("/scan/a-big", children: [
                file("/scan/a-big/big.bin", size: 600 * megabyte, modified: old),
            ]),
            directory("/scan/z-small", children: [
                file("/scan/z-small/small.bin", size: 10 * megabyte, modified: old),
            ]),
        ])
        let policy = CleanupPolicy(maxVisitedNodes: 2)

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), policy: policy, now: now))
        let group = try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld })

        XCTAssertTrue(report.stoppedAtLimit)
        XCTAssertEqual(group.candidates.map(\.name), ["big.bin"],
                       "the node cap must cut the small end of the tree, not the first name")
    }

    // MARK: - Duplicate counts

    func testTheDuplicateFileCountIsExactBeforeTheGroupCap() throws {
        let root = directory("/scan", children: [
            file("/scan/a.bin", size: 10 * megabyte, modified: now),
            file("/scan/b.bin", size: 10 * megabyte, modified: now),
            file("/scan/c.bin", size: 10 * megabyte, modified: now),
            file("/scan/d.bin", size: 5 * megabyte, modified: now),
            file("/scan/e.bin", size: 5 * megabyte, modified: now),
        ])
        let policy = CleanupPolicy(maxDuplicateGroups: 1)

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), policy: policy, now: now))

        XCTAssertEqual(report.duplicateGroupCount, 2)
        XCTAssertEqual(report.duplicateGroups.count, 1)
        XCTAssertEqual(report.duplicateFileCount, 5,
                       "every file in a shared size counts, including the capped group")
        XCTAssertEqual(report.duplicateCandidateCount, 3,
                       "the shown group holds three paths")
    }

    func testEvictedFilesAreNotDuplicateCandidates() throws {
        let root = directory("/scan", children: [
            file("/scan/a.bin", size: 2 * megabyte, allocated: 0, modified: now),
            file("/scan/b.bin", size: 2 * megabyte, allocated: 0, modified: now),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        XCTAssertTrue(report.duplicateGroups.isEmpty, "reading one would download it")
        XCTAssertEqual(report.duplicateGroupCount, 0)
        XCTAssertEqual(report.duplicateFileCount, 0)
    }

    // MARK: - The rebuildable rules

    func testDeviceSupportIsOfferedWholeAndItsSubtreeIsNotWalked() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let deviceSupport = directory("/scan/Library/Developer/Xcode/iOS DeviceSupport", children: [
            directory("/scan/Library/Developer/Xcode/iOS DeviceSupport/17.0", children: [
                file("/scan/Library/Developer/Xcode/iOS DeviceSupport/17.0/device.bin",
                     size: 700 * megabyte, modified: old),
            ]),
        ])
        let xcode = directory("/scan/Library/Developer/Xcode", children: [deviceSupport])
        let developer = directory("/scan/Library/Developer", children: [xcode])
        let root = directory("/scan", children: [directory("/scan/Library", children: [developer])])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        let group = try XCTUnwrap(report.groups.first { $0.rule == .developerSupport })
        XCTAssertEqual(group.candidates.map(\.name), ["iOS DeviceSupport"])
        XCTAssertEqual(group.tier, .rebuildable)
        XCTAssertTrue(
            try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld }).candidates.isEmpty,
            "the folder is one finding; its large old file is not listed again"
        )
    }

    func testSimulatorDevicesAreOfferedWhole() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let devices = directory("/scan/Library/Developer/CoreSimulator/Devices", children: [
            directory("/scan/Library/Developer/CoreSimulator/Devices/SIM", children: [
                file("/scan/Library/Developer/CoreSimulator/Devices/SIM/data.bin",
                     size: 700 * megabyte, modified: old),
            ]),
        ])
        let coreSimulator = directory("/scan/Library/Developer/CoreSimulator", children: [devices])
        let root = directory("/scan", children: [
            directory("/scan/Library", children: [
                directory("/scan/Library/Developer", children: [coreSimulator]),
            ]),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        let group = try XCTUnwrap(report.groups.first { $0.rule == .simulators })
        XCTAssertEqual(group.candidates.map(\.name), ["Devices"])
        XCTAssertEqual(group.tier, .rebuildable)
    }

    func testLibraryLogsAreOfferedWhole() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let logs = directory("/scan/Library/Logs", children: [
            file("/scan/Library/Logs/app.log", size: 700 * megabyte, modified: old),
        ])
        let root = directory("/scan", children: [directory("/scan/Library", children: [logs])])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        let group = try XCTUnwrap(report.groups.first { $0.rule == .logs })
        XCTAssertEqual(group.candidates.map(\.name), ["Logs"])
        XCTAssertEqual(group.tier, .rebuildable)
        XCTAssertTrue(
            try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld }).candidates.isEmpty
        )
    }

    func testAFolderNamedLogsOutsideALibraryIsNotALogFolder() throws {
        let old = now.addingTimeInterval(-400 * 24 * 3600)
        let root = directory("/scan", children: [
            directory("/scan/Logs", children: [
                file("/scan/Logs/app.log", size: 700 * megabyte, modified: old),
            ]),
        ])

        let report = try XCTUnwrap(CleanupAnalysis.analyze(in: tree(root), now: now))

        XCTAssertTrue(try XCTUnwrap(report.groups.first { $0.rule == .logs }).candidates.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(report.groups.first { $0.rule == .largeAndOld }).candidates.map(\.name),
            ["app.log"],
            "an ordinary folder named Logs is walked like any other"
        )
    }

    func testRulesDeclareTheirTiersInDisplayOrder() {
        let rules = CleanupRule.allCases
        XCTAssertEqual(rules.map(\.tier), [
            .rebuildable, .rebuildable, .rebuildable, .rebuildable, .personal, .personal,
        ])
        XCTAssertEqual(rules.map(\.displayOrder), Array(rules.indices))
    }

    // MARK: - Fixtures

    /// The live tree a fixture root describes. A folder's size and counts are its
    /// children's, which is what the arena requires of every subtree.
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

    private func directory(
        _ path: String,
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
            logicalSize: children.reduce(0) { $0 + $1.logicalSize },
            allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            directoryCount: 1 + children.reduce(0) { $0 + $1.directoryCount },
            modifiedAt: modified,
            isAccessible: true,
            errorMessage: nil,
            children: children
        )
    }

    private func file(_ path: String, size: Int64, allocated: Int64? = nil, modified: Date?) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: false,
            isSymlink: false,
            category: .other,
            logicalSize: size,
            allocatedSize: allocated ?? size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: modified,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }
}
