import XCTest
import DiskCore
import Darwin
import Darwin.Mach

/// Independent QA verification of `FileScanEngine`.
///
/// These tests do NOT trust the engine's own `DiskCoreTests`. They cross-check the
/// real scanner against external ground truth (`find` / `du`) and probe the
/// non-negotiables: deep trees, permission failures, symlink loops, cancellation
/// responsiveness, and memory growth on a large scan.
final class ScanCorrectnessQATests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskQA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Runs a scan to completion, returning the summary + every event seen.
    private func finishScan(_ request: ScanRequest) async -> (ScanSummary?, [ScanEvent]) {
        let engine = FileScanEngine()
        var events: [ScanEvent] = []
        var summary: ScanSummary?
        for await event in engine.scan(request) {
            events.append(event)
            if case .finished(let s) = event { summary = s; return (summary, events) }
            if case .cancelled = event { return (summary, events) }
        }
        return (summary, events)
    }

    /// Synchronously runs a shell command and returns trimmed stdout (or nil on failure).
    private func sh(_ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Current process RSS in bytes (via `task_info`).
    private func currentRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    // MARK: - Ground-truth: known tree

    func testKnownTreeMatchesExpectedSizesAndCounts() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0x61, count: 10), to: root.appendingPathComponent("a.txt"))
        try write(Data(repeating: 0x62, count: 2_000), to: root.appendingPathComponent("b.jpg"))
        let sub = root.appendingPathComponent("sub")
        try makeDir(sub)
        try write(Data(repeating: 0x63, count: 500_000), to: sub.appendingPathComponent("c.mov"))
        try makeDir(root.appendingPathComponent("empty"))

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary, "scan should finish")

        XCTAssertEqual(s.fileCount, 3, "3 files expected")
        XCTAssertEqual(s.directoryCount, 3, "root + sub + empty")
        XCTAssertEqual(s.totalLogicalSize, 502_010, "10 + 2000 + 500000")
        XCTAssertTrue(events.contains { if case .finished = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .issue = $0 { return true }; return false },
                       "a fully readable tree should produce no issues")
    }

    /// The scanned location's own node is the one a results screen finds from
    /// `ScanSummary.root`, and it is found by path: a node's URL carries whether
    /// it is a directory, while the request's URL — which is what the summary
    /// reports as `root` — need not.
    func testTheRootNodeIsFoundFromTheSummaryRootByPath() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(Data(repeating: 0x61, count: 32), to: root.appendingPathComponent("a.txt"))
        try makeDir(root.appendingPathComponent("sub"))

        // A request URL built without the directory hint is what a caller that
        // received a path string hands the engine.
        let request = ScanRequest(root: URL(fileURLWithPath: root.path))
        let (summary, _) = await finishScan(request)
        let s = try XCTUnwrap(summary)

        let rootNode = s.largestDirectories.first {
            $0.url.standardizedFileURL.path == s.root.standardizedFileURL.path
        }
        let node = try XCTUnwrap(rootNode, "the scanned location's node must be in the summary")
        XCTAssertEqual(node.children.map(\.name).sorted(), ["a.txt", "sub"],
                       "the node is the scanned location itself, with its own entries")
        XCTAssertEqual(node.logicalSize, s.totalLogicalSize)
    }

    // MARK: - Cross-check against find / du

    func testMatchesFindAndDuGroundTruth() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // A mix of small and large files, nested dirs, and a zero-byte file.
        try write(Data(repeating: 0, count: 7), to: root.appendingPathComponent("small.txt"))
        try write(Data(), to: root.appendingPathComponent("zero.bin"))
        let d1 = root.appendingPathComponent("d1")
        let d2 = d1.appendingPathComponent("d2")
        try makeDir(d2)
        try write(Data(repeating: 0xAB, count: 1_048_576), to: d2.appendingPathComponent("big.bin"))
        try write(Data(repeating: 0xCD, count: 123_456), to: d1.appendingPathComponent("mid.dat"))

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        // Ground truth: file count and total logical size from `find`.
        let findLines = sh(["find", root.path, "-type", "f"])?.split(separator: "\n").count
        if let findFileCount = findLines {
            XCTAssertEqual(s.fileCount, findFileCount, "fileCount must match `find -type f`")
        } else {
            XCTFail("failed to run `find` for ground truth")
        }

        // Sum of st_size via find + stat.
        if let sizes = sh(["sh", "-c", "find \"\(root.path)\" -type f -exec stat -f %z {} \\+ | awk '{s+=$1} END {print s}'"]) {
            XCTAssertEqual(s.totalLogicalSize, Int64(sizes) ?? -1,
                           "totalLogicalSize must equal sum of st_size")
        }

        // Directory count from `find -type d`.
        let findDirLines = sh(["find", root.path, "-type", "d"])?.split(separator: "\n").count
        if let findDirCount = findDirLines {
            XCTAssertEqual(s.directoryCount, findDirCount, "directoryCount must match `find -type d`")
        } else {
            XCTFail("failed to run `find -type d` for ground truth")
        }

        // Allocated size must be a whole number of 512-byte blocks and no more than `du`'s
        // on-disk total (which additionally counts directory inode blocks).
        XCTAssertEqual(s.totalAllocatedSize % 512, 0, "allocated size is st_blocks*512")
        if let duKB = sh(["du", "-sk", root.path])?.split(separator: "\t").first.flatMap({ Int64($0) }) {
            XCTAssertLessThanOrEqual(s.totalAllocatedSize, duKB * 1024,
                                     "file allocated bytes must not exceed du's on-disk total")
        }
    }

    // MARK: - Deep tree (no stack overflow)

    func testDeepNestingDoesNotOverflow() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // 300 nested single-child directories + a file at the bottom.
        // (kept well under PATH_MAX; the traversal is iterative anyway)
        var path = root
        for _ in 0..<300 {
            path = path.appendingPathComponent("d", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try write(Data(repeating: 0, count: 42), to: path.appendingPathComponent("leaf.txt"))

        let (summary, _) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1)
        XCTAssertEqual(s.directoryCount, 301)   // root + 300 nested
        XCTAssertEqual(s.totalLogicalSize, 42)
    }

    // MARK: - Hidden-file handling

    func testHiddenFilesCountedByDefaultAndSkippable() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 10), to: root.appendingPathComponent("visible.txt"))
        try write(Data(repeating: 0, count: 20), to: root.appendingPathComponent(".hidden.txt"))

        // Default includeHidden == true
        let (defaultSummary, _) = await finishScan(ScanRequest(root: root))
        XCTAssertEqual(try XCTUnwrap(defaultSummary).fileCount, 2)
        XCTAssertEqual(try XCTUnwrap(defaultSummary).totalLogicalSize, 30)

        // includeHidden == false
        let (hiddenSummary, _) = await finishScan(ScanRequest(root: root, includeHidden: false))
        XCTAssertEqual(try XCTUnwrap(hiddenSummary).fileCount, 1)
        XCTAssertEqual(try XCTUnwrap(hiddenSummary).totalLogicalSize, 10)
    }

    // MARK: - Symlink safety (independent)

    func testSymlinkLoopDoesNotHangOrDoubleCount() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 100), to: root.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("self-link"),
            withDestinationURL: root
        )

        // Even with followSymlinks=true the (dev,ino) guard must break the cycle.
        let (followSummary, _) = await finishScan(ScanRequest(root: root, followSymlinks: true))
        XCTAssertEqual(try XCTUnwrap(followSummary).fileCount, 1, "loop must not double-count real.txt")
        XCTAssertEqual(try XCTUnwrap(followSummary).totalLogicalSize, 100)
    }

    func testBrokenSymlinkIsNonFatal() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data(repeating: 0, count: 5), to: root.appendingPathComponent("ok.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("does-not-exist")
        )

        // A dangling link is only observable when the scanner resolves targets.
        let (summary, events) = await finishScan(ScanRequest(root: root, followSymlinks: true))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1, "the dangling link is not a file")
        XCTAssertTrue(events.contains {
            if case .issue(.brokenSymlink, _, _) = $0 { return true }
            return false
        }, "a broken symlink should surface a classified non-fatal issue")
        XCTAssertTrue(events.contains { if case .finished = $0 { return true }; return false })
    }

    // MARK: - Permission denial (graceful)

    func testUnreadableDirectoryIsReportedNotCrashing() async throws {
        let root = try makeTempDir()

        try write(Data(repeating: 0, count: 11), to: root.appendingPathComponent("ok.txt"))
        let locked = root.appendingPathComponent("locked")
        try makeDir(locked)
        try write(Data(repeating: 0, count: 13), to: locked.appendingPathComponent("secret.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        let (summary, events) = await finishScan(ScanRequest(root: root))
        let s = try XCTUnwrap(summary)

        XCTAssertEqual(s.fileCount, 1, "readable file still counted")
        XCTAssertEqual(s.totalLogicalSize, 11)
        XCTAssertGreaterThanOrEqual(s.inaccessibleCount, 1)
        XCTAssertGreaterThanOrEqual(s.errorCount, 1)
        XCTAssertGreaterThanOrEqual(s.permissionDeniedCount, 1, "TCC/POSIX denial is classified for the banner")
        XCTAssertGreaterThanOrEqual(s.surfacedIssueCount, 1, "the detail is surfaced")
        XCTAssertTrue(events.contains {
            if case .issue(.permissionDenied, _, _) = $0 { return true }
            return false
        }, "the unreadable directory is surfaced as a permission-denied issue")
    }

    // MARK: - Cancellation responsiveness

    func testCancellationReturnsPromptly() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30_000 {
            try write(Data(repeating: UInt8(i % 251), count: 8),
                      to: root.appendingPathComponent(String(format: "f_%05d.txt", i)))
        }

        let engine = FileScanEngine()
        var iterator = engine.scan(ScanRequest(root: root)).makeAsyncIterator()

        guard case .started = await iterator.next() else {
            return XCTFail("expected .started")
        }

        let cancelStart = Date()
        await engine.cancel()

        var cancelledAt: Date? = nil
        var sawFinished = false
        while let event = await iterator.next() {
            if case .cancelled = event { cancelledAt = Date(); break }
            if case .finished = event { sawFinished = true; break }
        }

        XCTAssertNotNil(cancelledAt, "expected a .cancelled event")
        XCTAssertFalse(sawFinished, "must not finish after cancellation")
        if let cancelledAt {
            let latency = cancelledAt.timeIntervalSince(cancelStart)
            XCTAssertLessThan(latency, 2.0, "cancellation must be observed promptly, took \(latency)s")
        }
    }

    // MARK: - Non-blocking + memory bound

    func testScanReturnsImmediately() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10_000 {
            try write(Data(repeating: 0, count: 8),
                      to: root.appendingPathComponent(String(format: "f_%05d.txt", i)))
        }

        let engine = FileScanEngine()
        let start = Date()
        _ = engine.scan(ScanRequest(root: root))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "scan() must not block the caller")
        for await _ in engine.scan(ScanRequest(root: root)) {}   // drain so the task ends
    }

    func testLargeScanMemoryStaysBounded() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30_000 {
            try write(Data(repeating: UInt8(i % 251), count: 8),
                      to: root.appendingPathComponent(String(format: "f_%05d.txt", i)))
        }

        let baseline = currentRSS()
        let engine = FileScanEngine()
        var peak: UInt64 = baseline
        for await event in engine.scan(ScanRequest(root: root)) {
            peak = max(peak, currentRSS())
            if case .finished = event { break }
        }
        let delta = peak > baseline ? peak - baseline : 0
        // 30k small files must not balloon the process; leave generous headroom
        // so the assertion is meaningful without being flaky across machines.
        XCTAssertLessThan(delta, 300 * 1_048_576, "peak RSS growth \(delta) bytes exceeded 300 MiB")
        print("QA: 30k-file scan peak RSS growth = \(delta / 1_048_576) MiB (baseline \(baseline / 1_048_576) MiB)")
    }
}
