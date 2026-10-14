import XCTest
import Foundation
import Darwin
@testable import DiskCore

/// Engine tests for `FileScanEngine`.
///
/// These build synthetic trees in a temporary directory, run the real scanner,
/// and assert on sizes, counts, categories, traversal safety, cancellation, and
/// error handling.
final class FileScanEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Builds a flat directory of `count` small files named `file_00000.txt`…
    /// Returns the directory URL.
    private func makeFlatTree(fileCount: Int) throws -> URL {
        let root = try makeTempDir()
        for i in 0..<fileCount {
            let name = String(format: "file_%05d.txt", i)
            try write(Data(repeating: UInt8(i % 251), count: 8), to: root.appendingPathComponent(name))
        }
        return root
    }

    /// Runs a scan to completion and returns the finished summary (or nil) plus all events.
    private func finishScan(_ request: ScanRequest) async -> (ScanSummary?, [ScanEvent]) {
        let engine = FileScanEngine()
        var events: [ScanEvent] = []
        var summary: ScanSummary?
        for await event in engine.scan(request) {
            events.append(event)
            switch event {
            case .finished(let s):
                summary = s
                return (summary, events)
            case .cancelled:
                return (summary, events)
            default:
                break
            }
        }
        return (summary, events)
    }

    // MARK: - Sizes and counts

    func testSizesCountsAndLargestOnSyntheticTree() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0x61, count: 10), to: root.appendingPathComponent("a.txt"))   // 10  documents
        try write(Data(repeating: 0x62, count: 20), to: root.appendingPathComponent("b.bin"))   // 20  other
        let sub = root.appendingPathComponent("sub")
        try makeDir(sub)
        try write(Data(repeating: 0x63, count: 30), to: sub.appendingPathComponent("c.jpg"))    // 30  images
        try write(Data(repeating: 0x64, count: 40), to: sub.appendingPathComponent("d.mov"))    // 40  video
        let empty = root.appendingPathComponent("empty")
        try makeDir(empty)

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary, "scan should finish; events: \(events.count)")

        XCTAssertEqual(s.totalLogicalSize, 100)
        XCTAssertEqual(s.fileCount, 4)
        // root + sub + empty
        XCTAssertEqual(s.directoryCount, 3)

        // Category breakdown is by logical size of regular files only.
        XCTAssertEqual(s.categoryBreakdown[.documents], 10)
        XCTAssertEqual(s.categoryBreakdown[.images], 30)
        XCTAssertEqual(s.categoryBreakdown[.video], 40)
        XCTAssertEqual(s.categoryBreakdown[.other], 20)
        XCTAssertEqual(s.categoryBreakdown.values.reduce(0, +), 100)

        // Largest file is d.mov (40), then c.jpg (30), b.bin (20), a.txt (10).
        XCTAssertEqual(s.largestFiles.count, 4)
        XCTAssertEqual(s.largestFiles[0].name, "d.mov")
        XCTAssertEqual(s.largestFiles[0].logicalSize, 40)
        XCTAssertEqual(s.largestFiles.map(\.logicalSize), [40, 30, 20, 10])

        // The root directory is the largest directory and carries the full tree.
        let rootNode = try XCTUnwrap(s.largestDirectories.first)
        XCTAssertEqual(rootNode.name, root.lastPathComponent)
        XCTAssertEqual(rootNode.logicalSize, 100)
        XCTAssertEqual(rootNode.fileCount, 4)
        XCTAssertEqual(rootNode.directoryCount, 3)
    }

    func testChildrenSortedDescendingByLogicalSize() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 5), to: root.appendingPathComponent("small.txt"))
        try write(Data(repeating: 0, count: 500), to: root.appendingPathComponent("big.txt"))
        try write(Data(repeating: 0, count: 50), to: root.appendingPathComponent("mid.txt"))

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        let rootNode = try XCTUnwrap(s.largestDirectories.first)
        XCTAssertEqual(rootNode.children.map(\.logicalSize), [500, 50, 5])
    }

    func testZeroByteAndEmptyDirectory() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(), to: root.appendingPathComponent("zero.txt"))
        try makeDir(root.appendingPathComponent("empty"))

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1)
        XCTAssertEqual(s.totalLogicalSize, 0)
        XCTAssertEqual(s.directoryCount, 2)   // root + empty
        XCTAssertEqual(s.largestFiles.count, 1)
        XCTAssertEqual(s.largestFiles[0].logicalSize, 0)
    }

    func testAllocatedSizeUsesBlocksForLargeFile() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let big = Data(repeating: 0xAB, count: 1_048_576)  // 1 MiB
        try write(big, to: root.appendingPathComponent("big.bin"))

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        let file = try XCTUnwrap(s.largestFiles.first)
        XCTAssertEqual(file.logicalSize, 1_048_576)
        // st_blocks * 512 rounds up and is a multiple of 512; for a 1 MiB file
        // it must be at least the logical size on APFS/HFS+.
        XCTAssertGreaterThan(file.allocatedSize, 0)
        XCTAssertGreaterThanOrEqual(file.allocatedSize, file.logicalSize)
        XCTAssertEqual(file.allocatedSize % 512, 0)
    }

    // MARK: - Category mapping

    func testCategoryMapping() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let fixtures: [(String, Int)] = [
            ("photo.jpg", 1), ("movie.mp4", 2), ("song.mp3", 3), ("archive.zip", 4),
            ("main.swift", 5), ("report.pdf", 6), ("weird.zzz", 7),
        ]
        for (name, size) in fixtures {
            try write(Data(repeating: 0, count: size), to: root.appendingPathComponent(name))
        }

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.categoryBreakdown[.images], 1)
        XCTAssertEqual(s.categoryBreakdown[.video], 2)
        XCTAssertEqual(s.categoryBreakdown[.audio], 3)
        XCTAssertEqual(s.categoryBreakdown[.archives], 4)
        XCTAssertEqual(s.categoryBreakdown[.code], 5)
        XCTAssertEqual(s.categoryBreakdown[.documents], 6)
        XCTAssertEqual(s.categoryBreakdown[.other], 7)
    }

    // MARK: - Symlink safety

    func testSymlinkNotFollowedByDefault() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let external = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: external) }
        try write(Data(repeating: 0, count: 1000), to: external.appendingPathComponent("big.bin"))

        try write(Data(repeating: 0, count: 3), to: root.appendingPathComponent("inside.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: external
        )

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        // The symlink is a zero-sized leaf; the external contents are NOT counted.
        XCTAssertEqual(s.totalLogicalSize, 3)
        XCTAssertEqual(s.fileCount, 1)
    }

    func testSymlinkLoopTerminatesByDefault() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 5), to: root.appendingPathComponent("f.txt"))
        // A symlink pointing back at the root itself.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root
        )

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1)  // only f.txt; the loop is not followed
        XCTAssertEqual(s.totalLogicalSize, 5)
        XCTAssertTrue(events.contains { if case .finished = $0 { return true }; return false })
    }

    func testFollowSymlinkLoopTerminates() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 5), to: root.appendingPathComponent("f.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("loop"), withDestinationURL: root
        )

        // followSymlinks = true: the cycle must be detected via (dev, ino).
        let (summary, _) = await finishScan(ScanRequest(root: root, followSymlinks: true))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1)
        XCTAssertEqual(s.totalLogicalSize, 5)
    }

    /// A scan root that is itself a broken symbolic link must not vanish: it is a
    /// non-fatal issue, counted truthfully and represented in the result.
    func testBrokenSymlinkAtRootIsSurfaced() async throws {
        let container = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: container) }

        let link = container.appendingPathComponent("broken-root")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: container.appendingPathComponent("does-not-exist")
        )

        let (summary, events) = await finishScan(ScanRequest(root: link))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.errorCount, 1, "the broken root link is counted")
        XCTAssertEqual(s.surfacedIssueCount, 1, "the broken root link is surfaced")
        XCTAssertEqual(s.inaccessibleCount, 0, "a broken symlink is not an inaccessible directory")
        XCTAssertEqual(s.permissionDeniedCount, 0, "a broken symlink is not a permission denial")
        XCTAssertEqual(s.fileCount, 0)
        XCTAssertEqual(s.totalLogicalSize, 0)

        XCTAssertTrue(events.contains {
            if case .issue(let kind, let path, _) = $0 {
                return kind == .brokenSymlink && path == link.path
            }
            return false
        }, "the root issue carries the .brokenSymlink classification")

        let node = try XCTUnwrap(s.largestFiles.first, "the broken link is represented in the result")
        XCTAssertEqual(node.name, link.lastPathComponent)
        XCTAssertTrue(node.isSymlink)
        XCTAssertNotNil(node.errorMessage)
    }

    /// A root that is a symlink to a directory is followed, and the target's
    /// contents are scanned under the root path.
    func testSymlinkRootToDirectoryIsFollowedWhenRequested() async throws {
        let container = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: container) }

        let real = container.appendingPathComponent("real", isDirectory: true)
        try makeDir(real)
        try write(Data(repeating: 0, count: 42), to: real.appendingPathComponent("payload.bin"))

        let link = container.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let (summary, _) = await finishScan(ScanRequest(root: link, followSymlinks: true))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1)
        XCTAssertEqual(s.totalLogicalSize, 42)
        XCTAssertEqual(s.errorCount, 0)
    }

    /// Without following, a valid symlink root is still represented as a
    /// zero-sized leaf rather than disappearing from the result.
    func testSymlinkRootNotFollowedByDefaultIsRepresented() async throws {
        let container = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: container) }

        let real = container.appendingPathComponent("real", isDirectory: true)
        try makeDir(real)
        try write(Data(repeating: 0, count: 42), to: real.appendingPathComponent("payload.bin"))

        let link = container.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let (summary, _) = await finishScan(ScanRequest(root: link))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 0, "the target's contents are neither followed nor counted")
        XCTAssertEqual(s.totalLogicalSize, 0)
        XCTAssertEqual(s.errorCount, 0)
        let node = try XCTUnwrap(s.largestFiles.first, "the link is still represented")
        XCTAssertEqual(node.name, link.lastPathComponent)
        XCTAssertTrue(node.isSymlink)
    }

    // MARK: - Permission denied (non-fatal)

    func testPermissionDeniedIsNonFatal() async throws {
        let root = try makeTempDir()

        try write(Data(repeating: 0, count: 7), to: root.appendingPathComponent("ok.txt"))
        let locked = root.appendingPathComponent("locked")
        try makeDir(locked)
        try write(Data(repeating: 0, count: 9), to: locked.appendingPathComponent("secret.txt"))

        // Make the directory unreadable, then restore permissions for cleanup.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        // The readable file is still counted; the locked directory is reported as inaccessible.
        XCTAssertEqual(s.fileCount, 1)
        XCTAssertEqual(s.totalLogicalSize, 7)
        XCTAssertGreaterThanOrEqual(s.inaccessibleCount, 1)
        XCTAssertGreaterThanOrEqual(s.errorCount, 1)
        XCTAssertGreaterThanOrEqual(s.permissionDeniedCount, 1, "permission denials are counted for the banner")
        XCTAssertGreaterThanOrEqual(s.surfacedIssueCount, 1, "the denial detail is surfaced")
        XCTAssertTrue(events.contains { if case .issue = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .finished = $0 { return true }; return false })
    }

    // MARK: - Permission aggregation

    /// Counts the surfaced issue events (`.issue`) in a run.
    private func issueCount(_ collector: EventCollector) -> Int {
        collector.count { if case .issue = $0 { return true }; return false }
    }

    private func issueCount(_ events: [ScanEvent]) -> Int {
        events.reduce(into: 0) { count, event in
            if case .issue = event { count += 1 }
        }
    }

    /// One inaccessible directory must produce exactly one issue, no matter how
    /// many unreadable entries live inside it — no per-child error spray.
    func testPerChildPermissionDenialsAggregateToOneIssuePerDirectory() async throws {
        let root = "/virtual-root-\(UUID().uuidString)"
        let restricted = root + "/restricted"
        let children = (0..<25).map { "child_\(String(format: "%02d", $0)).txt" }

        var fs = VirtualFS()
        fs.directories[root] = ["ok.txt", "restricted"]
        fs.fileSizes[root + "/ok.txt"] = 7
        fs.directories[restricted] = children
        for child in children { fs.fileSizes[restricted + "/" + child] = 10 }
        // The directory lists fine, but metadata for every child is denied.
        fs.directoriesWithDeniedChildren = [restricted]

        let collector = await runScanner(ScanRequest(root: URL(fileURLWithPath: root)), access: fs.access())

        let s = try XCTUnwrap(collector.finished)
        XCTAssertEqual(issueCount(collector), 1, "one denied directory → exactly one issue")
        XCTAssertEqual(s.inaccessibleCount, 1, "distinct inaccessible directories")
        XCTAssertEqual(s.errorCount, 1, "aggregated issue counted once")
        XCTAssertEqual(s.permissionDeniedCount, 1, "the denial is counted for the banner")
        XCTAssertEqual(s.surfacedIssueCount, 1)
        XCTAssertEqual(s.fileCount, 1, "only the readable file is counted")
        XCTAssertEqual(s.totalLogicalSize, 7)
    }

    /// Surfaced detail is bounded, but the summary counts stay truthful/uncapped.
    func testSurfacedIssuesAreCappedWhileCountsStayAccurate() async throws {
        let root = try makeTempDir()
        let lockedDirs = (0..<60).map { root.appendingPathComponent(String(format: "locked_%02d", $0)) }
        for dir in lockedDirs {
            try makeDir(dir)
            try write(Data(repeating: 0, count: 3), to: dir.appendingPathComponent("secret.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        }
        defer {
            for dir in lockedDirs {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            }
            try? FileManager.default.removeItem(at: root)
        }

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(issueCount(events), 50, "surfaced issues are capped")
        XCTAssertEqual(s.inaccessibleCount, 60, "count reflects every inaccessible directory")
        XCTAssertEqual(s.errorCount, 60, "errorCount stays truthful, not capped")
        XCTAssertEqual(s.permissionDeniedCount, 60, "every locked directory is a permission denial")
        XCTAssertEqual(s.surfacedIssueCount, 50, "surfaced count reflects the cap, not the total")
    }

    /// A real unreadable directory holding many children yields one issue.
    func testUnreadableDirectoryWithManyChildrenYieldsExactlyOneIssue() async throws {
        let root = try makeTempDir()
        let locked = root.appendingPathComponent("locked")
        try makeDir(locked)
        for i in 0..<20 {
            try write(Data(repeating: 0, count: 2), to: locked.appendingPathComponent("child_\(i).txt"))
        }
        try write(Data(repeating: 0, count: 5), to: root.appendingPathComponent("ok.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(issueCount(events), 1, "one directory → one issue")
        XCTAssertEqual(s.inaccessibleCount, 1)
        XCTAssertEqual(s.errorCount, 1)
        XCTAssertEqual(s.permissionDeniedCount, 1)
        XCTAssertEqual(s.surfacedIssueCount, 1)
        XCTAssertEqual(s.fileCount, 1)
        XCTAssertEqual(s.totalLogicalSize, 5)
    }

    /// Permission denial is classified apart from I/O and missing-entry failures.
    func testErrorClassificationDistinguishesPermissionDenial() {
        XCTAssertEqual(ScanErrorClassifier.kind(errno: EACCES), .permissionDenied)
        XCTAssertEqual(ScanErrorClassifier.kind(errno: EPERM), .permissionDenied)
        XCTAssertEqual(ScanErrorClassifier.kind(errno: EIO), .io)
        XCTAssertEqual(ScanErrorClassifier.kind(errno: ENOENT), .other)

        // Foundation wraps TCC/POSIX denials as Cocoa 257 over an NSPOSIXErrorDomain error.
        let cocoaDenied = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )
        XCTAssertEqual(ScanErrorClassifier.kind(for: cocoaDenied), .permissionDenied)
        XCTAssertEqual(
            ScanErrorClassifier.kind(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))),
            .permissionDenied
        )
        XCTAssertEqual(
            ScanErrorClassifier.kind(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))),
            .io
        )
    }

    /// Non-permission failures are still surfaced and never counted as inaccessible.
    func testNonPermissionChildFailuresAreReportedNotInaccessible() async throws {
        let root = "/virtual-root-\(UUID().uuidString)"
        var fs = VirtualFS()
        // `ghost.txt` is listed but has no metadata → the entry reports ENOENT.
        fs.directories[root] = ["ghost.txt", "ok.txt"]
        fs.fileSizes[root + "/ok.txt"] = 4

        let collector = await runScanner(ScanRequest(root: URL(fileURLWithPath: root)), access: fs.access())

        let s = try XCTUnwrap(collector.finished)
        XCTAssertEqual(issueCount(collector), 1, "a missing entry still reports once")
        XCTAssertEqual(s.errorCount, 1)
        XCTAssertEqual(s.inaccessibleCount, 0, "a missing entry is not an inaccessible directory")
        XCTAssertEqual(s.permissionDeniedCount, 0, "a missing entry is not a permission denial")
    }

    /// A broken symlink is an error but not an inaccessible directory.
    func testBrokenSymlinkIsAnErrorNotInaccessible() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 5), to: root.appendingPathComponent("ok.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("does-not-exist")
        )

        let (summary, events) = await finishScan(ScanRequest(root: root, followSymlinks: true))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(issueCount(events), 1)
        XCTAssertEqual(s.errorCount, 1)
        XCTAssertEqual(s.inaccessibleCount, 0)
        XCTAssertEqual(s.permissionDeniedCount, 0, "a broken symlink is not a permission denial")
        XCTAssertTrue(events.contains {
            if case .issue(let kind, _, _) = $0 { return kind == .brokenSymlink }
            return false
        }, "the surfaced issue carries the .brokenSymlink classification")
    }

    // MARK: - Duplicate subtree de-duplication

    /// A directory reachable under two paths that share one device and inode —
    /// the shape macOS firmlinks create — is walked exactly once, and its content
    /// is counted once. This is what keeps a whole-volume scan from reporting the
    /// same tree twice.
    func testDirectoryReachableByTwoPathsIsWalkedOnce() async throws {
        let root = "/virtual-firmlink-\(UUID().uuidString)"
        let shared = root + "/shared"
        let alias = root + "/alias"

        var fs = VirtualFS()
        fs.directories[root] = ["shared", "alias", "top.txt"]
        fs.fileSizes[root + "/top.txt"] = 5
        fs.directories[shared] = ["payload.bin"]
        fs.fileSizes[shared + "/payload.bin"] = 1_000
        // The alias lists the same content and shares the directory's identity.
        fs.directories[alias] = ["payload.bin"]
        fs.fileSizes[alias + "/payload.bin"] = 1_000
        fs.inodeAliases[alias] = shared

        for concurrency in [1, 4] {
            let collector = await runScanner(
                ScanRequest(root: URL(fileURLWithPath: root)),
                access: fs.access(),
                concurrency: concurrency
            )
            let s = try XCTUnwrap(collector.finished)
            XCTAssertEqual(s.fileCount, 2, "the shared payload is counted once (concurrency \(concurrency))")
            XCTAssertEqual(s.totalLogicalSize, 1_005, "totals are not inflated by the second path")
            XCTAssertEqual(s.directoryCount, 2, "root plus the single walked directory")

            let walked = s.largestDirectories.filter { $0.name == "shared" || $0.name == "alias" }
            XCTAssertEqual(walked.count, 1, "only one of the two paths is walked")
            XCTAssertEqual(walked.first?.logicalSize, 1_000)
        }
    }

    // MARK: - Parallel traversal

    /// The parallel scan must produce exactly the same tree and totals as a
    /// serial one — concurrency is an implementation detail, never a source of
    /// double counting or lost work.
    func testParallelScanMatchesSerialScan() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for d in 0..<40 {
            let dir = root.appendingPathComponent(String(format: "dir_%02d", d), isDirectory: true)
            try makeDir(dir)
            for f in 0..<8 {
                try write(
                    Data(repeating: UInt8(f % 251), count: 10 * (f + 1) + d),
                    to: dir.appendingPathComponent(String(format: "f_%02d.dat", f))
                )
            }
            let nested = dir.appendingPathComponent("nested", isDirectory: true)
            try makeDir(nested)
            try write(Data(repeating: 0x7A, count: 100 + d), to: nested.appendingPathComponent("deep.bin"))
        }

        let serialRun = await runScanner(ScanRequest(root: root), concurrency: 1)
        let parallelRun = await runScanner(ScanRequest(root: root), concurrency: 8)
        let serial = try XCTUnwrap(serialRun.finished)
        let parallel = try XCTUnwrap(parallelRun.finished)

        XCTAssertEqual(serial.totalLogicalSize, parallel.totalLogicalSize)
        XCTAssertEqual(serial.totalAllocatedSize, parallel.totalAllocatedSize)
        XCTAssertEqual(serial.fileCount, parallel.fileCount)
        XCTAssertEqual(serial.directoryCount, parallel.directoryCount)
        XCTAssertEqual(serial.categoryBreakdown, parallel.categoryBreakdown)
        XCTAssertEqual(serial.errorCount, parallel.errorCount)
        XCTAssertEqual(serial.inaccessibleCount, parallel.inaccessibleCount)
        XCTAssertGreaterThan(serial.fileCount, 300, "the fixture exercises a real tree")

        let serialRoot = try XCTUnwrap(serial.largestDirectories.first)
        let parallelRoot = try XCTUnwrap(parallel.largestDirectories.first)
        XCTAssertEqual(treeSignature(serialRoot), treeSignature(parallelRoot),
                       "the parallel tree is identical to the serial tree")

        let serialFiles = serial.largestFiles.map { "\($0.name):\($0.logicalSize)" }.sorted()
        let parallelFiles = parallel.largestFiles.map { "\($0.name):\($0.logicalSize)" }.sorted()
        XCTAssertEqual(serialFiles, parallelFiles)
    }

    /// A wide tree must terminate with far more workers than cores in play: a
    /// bounded pool that a full set of waiters could stall would hang here.
    func testConcurrentScanOfWideTreeTerminates() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for d in 0..<150 {
            let dir = root.appendingPathComponent(String(format: "wide_%03d", d), isDirectory: true)
            try makeDir(dir)
            for f in 0..<4 {
                try write(Data(repeating: 0x11, count: 7), to: dir.appendingPathComponent("f\(f).txt"))
            }
        }

        let collector = await runScanner(ScanRequest(root: root), concurrency: 16)
        let s = try XCTUnwrap(collector.finished)
        XCTAssertEqual(s.fileCount, 600)
        XCTAssertEqual(s.directoryCount, 151)
        XCTAssertEqual(s.totalLogicalSize, 600 * 7)
    }

    /// The root node's subtree totals must equal the summary's totals: they are
    /// computed independently (node by summing children, summary by counting
    /// entries), so agreement is the check that neither lost nor duplicated work.
    func testRootNodeTotalsMatchSummaryTotals() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for d in 0..<12 {
            let dir = root.appendingPathComponent("d\(d)", isDirectory: true)
            try makeDir(dir)
            for f in 0..<5 {
                try write(Data(repeating: 0x22, count: 3 + f), to: dir.appendingPathComponent("f\(f).txt"))
            }
        }

        let collector = await runScanner(ScanRequest(root: root), concurrency: 6)
        let s = try XCTUnwrap(collector.finished)
        let rootNode = try XCTUnwrap(s.largestDirectories.first)
        XCTAssertEqual(rootNode.logicalSize, s.totalLogicalSize)
        XCTAssertEqual(rootNode.allocatedSize, s.totalAllocatedSize)
        XCTAssertEqual(rootNode.fileCount, s.fileCount)
        XCTAssertEqual(rootNode.directoryCount, s.directoryCount)
    }

    // MARK: - Cancellation

    func testCancellationProducesCancelledEvent() async throws {
        let root = try makeFlatTree(fileCount: 20_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = FileScanEngine()
        let stream = engine.scan(ScanRequest(root: root))
        // Cancel before consuming, so the outcome does not depend on how fast the
        // machine happens to walk the tree.
        await engine.cancel()

        var sawCancelled = false
        var sawFinished = false
        for await event in stream {
            switch event {
            case .cancelled: sawCancelled = true
            case .finished: sawFinished = true
            default: break
            }
            if sawCancelled || sawFinished { break }
        }

        XCTAssertTrue(sawCancelled, "Expected .cancelled; finished=\(sawFinished)")
        XCTAssertFalse(sawFinished, "Scan should not finish after cancellation")
    }

    /// Cancelling a scan that is already running stops it promptly, reports a
    /// partial result, and never also reports a finished one.
    func testCancellationMidScanStopsPromptly() async throws {
        let root = try makeFlatTree(fileCount: 20_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = FileScanEngine(concurrency: 8)
        var iterator = engine.scan(ScanRequest(root: root)).makeAsyncIterator()

        let first = await iterator.next()
        guard case .started = first else {
            XCTFail("Expected .started, got \(String(describing: first))")
            return
        }

        await engine.cancel()

        var sawCancelled = false
        var sawFinished = false
        while let event = await iterator.next() {
            switch event {
            case .cancelled(let partial):
                sawCancelled = true
                XCTAssertNotNil(partial, "cancellation reports the partial result")
            case .finished:
                sawFinished = true
            default:
                break
            }
            if sawCancelled || sawFinished { break }
        }

        XCTAssertTrue(sawCancelled, "Expected .cancelled; finished=\(sawFinished)")
        XCTAssertFalse(sawFinished, "a cancelled scan does not also finish")
    }

    // MARK: - Off-main-thread / non-blocking

    func testScanReturnsWithoutBlocking() async throws {
        let root = try makeFlatTree(fileCount: 20_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = FileScanEngine()
        let start = Date()
        _ = engine.scan(ScanRequest(root: root))
        let elapsed = Date().timeIntervalSince(start)

        // scan() must return almost immediately (work is deferred to a detached task).
        XCTAssertLessThan(elapsed, 0.5)

        // Drain to completion so the detached task doesn't outlive the test.
        for await _ in engine.scan(ScanRequest(root: root)) {}
    }
}

/// An in-memory filesystem model for exercising the scanner deterministically.
///
/// It lets a test make a directory *listable* while denying `lstat` on its
/// children — the shape that produces a per-entry error spray on real volumes
/// (protected/TCC entries) and cannot be reproduced with POSIX modes, because
/// `FileManager.contentsOfDirectory` itself requires search permission.
private struct VirtualFS {
    var directories: [String: [String]] = [:]
    var fileSizes: [String: Int64] = [:]
    var unlistableDirectories: Set<String> = []
    var directoriesWithDeniedChildren: Set<String> = []
    /// Maps a path onto the path whose identity it shares, modelling a directory
    /// that is reachable under two names with one device and inode (a firmlink or
    /// a directory hard link).
    var inodeAliases: [String: String] = [:]

    private let device: dev_t = 7

    mutating func addDirectory(_ path: String, children: [String]) {
        directories[path] = children
    }

    mutating func addFile(_ path: String, size: Int64) {
        fileSizes[path] = size
    }

    func access() -> FileSystemAccess {
        let snapshot = self
        return FileSystemAccess(
            lstat: { snapshot.stat(for: $0) },
            statFollowing: { snapshot.stat(for: $0) },
            makeDirectoryReader: { VirtualDirectoryReader(filesystem: snapshot) },
            resolvedPath: { $0 }
        )
    }

    fileprivate func stat(for path: String) -> FileStat {
        let identityPath = inodeAliases[path] ?? path
        if let size = fileSizes[path] {
            return FileStat(
                error: 0, mode: 0o100644, size: size,
                blocks: (size + 511) / 512, dev: device, ino: Self.inode(for: identityPath)
            )
        }
        if directories[path] != nil {
            return FileStat(error: 0, mode: 0o040755, dev: device, ino: Self.inode(for: identityPath))
        }
        return FileStat(error: ENOENT)
    }

    fileprivate static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func inode(for path: String) -> ino_t {
        ino_t(truncatingIfNeeded: UInt64(bitPattern: Int64(path.hashValue)))
    }
}

/// The test double for `DirectoryReader`: it models the shapes a real bulk read
/// produces, including a directory that lists while denying metadata for its
/// children (an entry comes back carrying an error instead of attributes).
private struct VirtualDirectoryReader: DirectoryReading {
    let filesystem: VirtualFS

    func read(path: String) throws -> [DirectoryEntry] {
        if filesystem.unlistableDirectories.contains(path) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        guard let children = filesystem.directories[path] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        let deniesChildren = filesystem.directoriesWithDeniedChildren.contains(path)
        return children.map { name in
            if deniesChildren {
                return DirectoryEntry(name: name, stat: FileStat(error: EPERM))
            }
            let childPath = VirtualFS.join(path, name)
            return DirectoryEntry(name: name, stat: filesystem.stat(for: childPath))
        }
    }
}
