import XCTest
import Foundation
@testable import DiskCore

/// Engine tests for the non-terminal `.partial` snapshot stream.
///
/// A snapshot reports only work the scan has already completed: it grows
/// monotonically, is consistent with the terminal `.finished` summary, is
/// throttled rather than per-entry, and never terminates the stream.
final class ProgressiveSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskSnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds `directoryCount` subdirectories under a fresh root, each holding
    /// `filesPerDirectory` files of distinct sizes (1, 2, 3, …). Returns the root
    /// plus the ground-truth totals the finished scan must report.
    private func makeNestedTree(
        directoryCount: Int,
        filesPerDirectory: Int
    ) throws -> (root: URL, bytes: Int64, files: Int, directories: Int) {
        let root = try makeTempDir()
        var bytes: Int64 = 0
        for d in 0..<directoryCount {
            let dir = root.appendingPathComponent(String(format: "dir_%03d", d), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<filesPerDirectory {
                let size = 1 + (d * filesPerDirectory + f)
                try Data(repeating: 0x41, count: size)
                    .write(to: dir.appendingPathComponent(String(format: "f_%03d.txt", f)))
                bytes += Int64(size)
            }
        }
        return (root, bytes, directoryCount * filesPerDirectory, directoryCount + 1)
    }

    /// A flat directory of `fileCount` files of `fileSize` bytes each.
    private func makeFlatTree(fileCount: Int, fileSize: Int) throws -> URL {
        let root = try makeTempDir()
        let data = Data(repeating: 0x42, count: fileSize)
        for i in 0..<fileCount {
            try data.write(to: root.appendingPathComponent(String(format: "file_%05d.txt", i)))
        }
        return root
    }

    /// Runs the traversal on the calling task and returns the raw event list.
    private func scanEvents(
        _ request: ScanRequest,
        cadence: FileScanner.SnapshotCadence = .production
    ) async -> [ScanEvent] {
        await runScanner(request, cadence: cadence).events
    }

    /// Runs a scan through the public engine and collects every event.
    private func runEngine(_ request: ScanRequest) async -> [ScanEvent] {
        let engine = FileScanEngine()
        var events: [ScanEvent] = []
        for await event in engine.scan(request) {
            events.append(event)
            if case .finished = event { return events }
            if case .cancelled = event { return events }
        }
        return events
    }

    private func snapshots(in events: [ScanEvent]) -> [ScanSummary] {
        events.compactMap {
            if case .partial(let summary) = $0 { return summary }
            return nil
        }
    }

    private func finishedSummary(in events: [ScanEvent]) -> ScanSummary? {
        for event in events {
            if case .finished(let summary) = event { return summary }
        }
        return nil
    }

    private func terminalIndex(in events: [ScanEvent]) -> Int? {
        events.firstIndex {
            if case .finished = $0 { return true }
            if case .cancelled = $0 { return true }
            return false
        }
    }

    private func count(of kind: (ScanEvent) -> Bool, in events: [ScanEvent]) -> Int {
        events.reduce(into: 0) { total, event in if kind(event) { total += 1 } }
    }

    // MARK: - Non-terminality

    /// Snapshots appear while work completes, and the stream still ends with
    /// exactly one `.finished` — nothing follows the terminal event.
    func testSnapshotsAreNonTerminalAndTheScanEndsWithExactlyOneFinished() async throws {
        let tree = try makeNestedTree(directoryCount: 4, filesPerDirectory: 3)
        defer { try? FileManager.default.removeItem(at: tree.root) }

        let events = await scanEvents(ScanRequest(root: tree.root), cadence: .everyWorkUnit)

        let partials = snapshots(in: events)
        XCTAssertGreaterThanOrEqual(partials.count, 2, "a scan emits snapshots as work completes")

        XCTAssertEqual(count(of: { if case .finished = $0 { return true }; return false }, in: events), 1,
                       "a completed scan emits exactly one .finished")
        XCTAssertEqual(count(of: { if case .cancelled = $0 { return true }; return false }, in: events), 0,
                       "a completed scan never reports cancellation")

        let terminal = try XCTUnwrap(terminalIndex(in: events), "the scan must terminate")
        XCTAssertEqual(terminal, events.count - 1, "no snapshot follows the terminal event")
        guard case .finished = events[terminal] else {
            return XCTFail("the terminal event for a completed scan is .finished")
        }
    }

    // MARK: - Truthful, monotonic totals

    /// Every snapshot reports completed work only: quantities grow monotonically,
    /// never exceed the finished summary, and add up exactly.
    func testSnapshotTotalsGrowMonotonicallyAndMatchTheFinalSummary() async throws {
        let tree = try makeNestedTree(directoryCount: 5, filesPerDirectory: 4)
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let request = ScanRequest(root: tree.root)

        let events = await scanEvents(request, cadence: .everyWorkUnit)
        let partials = snapshots(in: events)
        let final = try XCTUnwrap(finishedSummary(in: events))

        XCTAssertGreaterThanOrEqual(partials.count, 3, "progress is reported more than once")
        XCTAssertGreaterThan(
            try XCTUnwrap(partials.last).totalLogicalSize,
            try XCTUnwrap(partials.first).totalLogicalSize,
            "the reported total actually grows during the scan"
        )

        // Ground truth from the filesystem, independent of the engine's own math.
        XCTAssertEqual(final.totalLogicalSize, tree.bytes)
        XCTAssertEqual(final.fileCount, tree.files)
        XCTAssertEqual(final.directoryCount, tree.directories)
        XCTAssertEqual(final.categoryBreakdown.values.reduce(0, +), tree.bytes,
                       "the category breakdown accounts for every counted byte")

        var previous: ScanSummary?
        for snapshot in partials {
            XCTAssertEqual(snapshot.root, request.root, "every snapshot describes the same root")
            XCTAssertEqual(snapshot.startedAt, final.startedAt,
                           "startedAt is the scan start; finishedAt is the snapshot time")

            // Nothing is projected: a snapshot can never exceed the finished result.
            XCTAssertLessThanOrEqual(snapshot.totalLogicalSize, final.totalLogicalSize)
            XCTAssertLessThanOrEqual(snapshot.totalAllocatedSize, final.totalAllocatedSize)
            XCTAssertLessThanOrEqual(snapshot.fileCount, final.fileCount)
            XCTAssertLessThanOrEqual(snapshot.directoryCount, final.directoryCount)
            XCTAssertLessThanOrEqual(snapshot.errorCount, final.errorCount)

            // Categories account for exactly the bytes counted so far.
            XCTAssertEqual(snapshot.categoryBreakdown.values.reduce(0, +), snapshot.totalLogicalSize)

            if let previous {
                XCTAssertGreaterThanOrEqual(snapshot.totalLogicalSize, previous.totalLogicalSize)
                XCTAssertGreaterThanOrEqual(snapshot.totalAllocatedSize, previous.totalAllocatedSize)
                XCTAssertGreaterThanOrEqual(snapshot.fileCount, previous.fileCount)
                XCTAssertGreaterThanOrEqual(snapshot.directoryCount, previous.directoryCount)
                XCTAssertGreaterThanOrEqual(snapshot.errorCount, previous.errorCount)
                XCTAssertGreaterThanOrEqual(snapshot.inaccessibleCount, previous.inaccessibleCount)
                XCTAssertGreaterThanOrEqual(snapshot.finishedAt, previous.finishedAt,
                                            "snapshots are ordered in time")
                for category in FileCategory.allCases {
                    XCTAssertGreaterThanOrEqual(
                        snapshot.categoryBreakdown[category] ?? 0,
                        previous.categoryBreakdown[category] ?? 0,
                        "category totals never shrink"
                    )
                }
                XCTAssertGreaterThanOrEqual(snapshot.largestFiles.count, previous.largestFiles.count)
                XCTAssertGreaterThanOrEqual(snapshot.largestDirectories.count, previous.largestDirectories.count)
                let shared = min(snapshot.largestFiles.count, previous.largestFiles.count)
                for i in 0..<shared {
                    XCTAssertGreaterThanOrEqual(snapshot.largestFiles[i].logicalSize,
                                                previous.largestFiles[i].logicalSize,
                                                "the k-th largest file never shrinks")
                }
            }
            previous = snapshot
        }
    }

    // MARK: - Cadence

    /// Snapshots are throttled by accumulated work, not emitted per entry.
    func testSnapshotsAreThrottledNotEmittedPerFile() async throws {
        let tree = try makeNestedTree(directoryCount: 3, filesPerDirectory: 2)
        defer { try? FileManager.default.removeItem(at: tree.root) }
        let request = ScanRequest(root: tree.root)

        let belowThreshold = await scanEvents(
            request,
            cadence: FileScanner.SnapshotCadence(interval: 0, workThreshold: 4096)
        )
        XCTAssertEqual(snapshots(in: belowThreshold).count, 0,
                       "a small scan emits no snapshot churn")

        let eager = await scanEvents(request, cadence: .everyWorkUnit)
        XCTAssertGreaterThanOrEqual(snapshots(in: eager).count, 2,
                                    "snapshots appear once the cadence allows")
    }

    /// A real scan of a large directory reports progress a bounded number of
    /// times — far below one snapshot per file.
    func testLargeScanEmitsBoundedNumberOfSnapshots() async throws {
        let root = try makeFlatTree(fileCount: 20_000, fileSize: 8)
        defer { try? FileManager.default.removeItem(at: root) }

        let events = await runEngine(ScanRequest(root: root))
        let final = try XCTUnwrap(finishedSummary(in: events))
        let partials = snapshots(in: events)

        XCTAssertEqual(final.fileCount, 20_000)
        XCTAssertGreaterThanOrEqual(partials.count, 1, "a large scan reports progress before it finishes")
        XCTAssertLessThan(partials.count, 500, "snapshots are throttled, not per file")
        for snapshot in partials {
            XCTAssertLessThanOrEqual(snapshot.fileCount, final.fileCount)
        }
    }

    // MARK: - Cancellation

    /// Cancelling mid-scan still yields exactly one terminal `.cancelled`, never
    /// a `.finished`, and the snapshot stream never follows it.
    func testCancellationMidScanStillEndsWithExactlyOneTerminalEvent() async throws {
        let root = try makeFlatTree(fileCount: 20_000, fileSize: 8)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = FileScanEngine()
        var iterator = engine.scan(ScanRequest(root: root)).makeAsyncIterator()

        let first = await iterator.next()
        guard case .started = first else {
            return XCTFail("expected .started, got \(String(describing: first))")
        }

        await engine.cancel()

        var cancelledCount = 0
        var finishedCount = 0
        var snapshotsAfterTerminal = 0
        var cancelledFileCount: Int?
        var sawTerminal = false
        while let event = await iterator.next() {
            switch event {
            case .partial(let snapshot):
                if sawTerminal { snapshotsAfterTerminal += 1 }
                XCTAssertLessThanOrEqual(snapshot.fileCount, 20_000, "a snapshot never over-counts")
            case .cancelled(let partial):
                cancelledCount += 1
                cancelledFileCount = partial?.fileCount ?? 0
                sawTerminal = true
            case .finished:
                finishedCount += 1
                sawTerminal = true
            default:
                break
            }
        }

        XCTAssertEqual(cancelledCount, 1, "cancellation is a single terminal event")
        XCTAssertEqual(finishedCount, 0, "a cancelled scan does not also finish")
        XCTAssertEqual(snapshotsAfterTerminal, 0, "nothing follows the terminal event")
        XCTAssertNotNil(cancelledFileCount, "cancellation reports the partial result")
    }
}
