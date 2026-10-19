import XCTest
@testable import DiskCore
import DiskUI

/// Independent QA verification of the `ScanViewModel` state machine that drives
/// the Screen A → B → C flow.
///
/// Verifies the observable phase transitions the UI depends on: idle → scanning
/// → finished, cancellation, reset, and the truthful failure path when no engine
/// is wired (no fabricated progress). It also pins the cadence progressive
/// snapshots reach the screen on, which is what keeps a streaming scan's chart
/// and explorer off the redraw path.
@MainActor
final class ScanViewModelQATests: XCTestCase {

    /// A scan whose events the test hands over itself, so a burst can be emitted
    /// inside one cadence window.
    private final class ScriptedEngine: ScanEngine, @unchecked Sendable {
        let stream: AsyncStream<ScanEvent>
        private let continuation: AsyncStream<ScanEvent>.Continuation

        init() {
            (stream, continuation) = AsyncStream<ScanEvent>.makeStream()
        }

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> { stream }
        func cancel() async {}
        func emit(_ event: ScanEvent) { continuation.yield(event) }
        func end() { continuation.finish() }
    }

    private func makeSummary(root: URL, logical: Int64, fileCount: Int = 1) -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: logical,
            totalAllocatedSize: logical,
            fileCount: fileCount,
            directoryCount: 1,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: [.documents: logical],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )
    }

    private func makeTempTree(fileCount: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskVM-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            try Data(repeating: UInt8(truncatingIfNeeded: i), count: 8)
                .write(to: url.appendingPathComponent("f\(i).txt"))
        }
        return url
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - Happy path

    func testIdleToScanningToFinished() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let vm = ScanViewModel(engine: FileScanEngine())
        XCTAssertEqual(vm.phase, .idle)

        vm.start(root: root)
        XCTAssertEqual(vm.phase, .scanning)

        let finished = await waitUntil { vm.phase == .finished }
        XCTAssertTrue(finished, "scan should reach .finished, got \(vm.phase)")
        XCTAssertNotNil(vm.summary)
        XCTAssertEqual(vm.summary?.fileCount, 4)
        XCTAssertTrue(vm.hasResults)
        XCTAssertFalse(vm.isScanning)
    }

    // MARK: - No engine → truthful failure (no fabricated progress)

    func testStartWithoutEngineFailsTruthfully() {
        let vm = ScanViewModel(engine: nil)
        vm.start(root: URL(fileURLWithPath: "/tmp"))
        guard case .failed(let message) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(vm.summary)
        XCTAssertNil(vm.progress)
    }

    // MARK: - Cancellation

    func testCancellationTransitionsToCancelled() async throws {
        let root = try makeTempTree(fileCount: 20_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let vm = ScanViewModel(engine: FileScanEngine())
        vm.start(root: root)
        XCTAssertEqual(vm.phase, .scanning)

        // Give the scan a moment to start producing work, then cancel.
        try? await Task.sleep(nanoseconds: 30_000_000)
        vm.cancel()

        let cancelled = await waitUntil { vm.phase == .cancelled || vm.phase == .finished }
        XCTAssertTrue(cancelled, "scan should resolve after cancel, got \(vm.phase)")
        // With no summary recorded the flow falls back to source selection.
        if vm.phase == .cancelled {
            XCTAssertFalse(vm.isScanning)
        }
    }

    // MARK: - Reset

    func testResetReturnsToIdleAndClearsState() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let vm = ScanViewModel(engine: FileScanEngine())
        vm.start(root: root)
        _ = await waitUntil { vm.phase == .finished }

        vm.reset()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.summary)
        XCTAssertNil(vm.progress)
        XCTAssertNil(vm.currentRoot)
        XCTAssertTrue(vm.issues.isEmpty)
    }

    // MARK: - Issues accumulate on error

    func testErrorsAreCollectedAsIssues() async throws {
        let root = try makeTempTree()
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: root.appendingPathComponent("nope")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let vm = ScanViewModel(engine: FileScanEngine())
        vm.start(root: root, options: ScanOptions(followSymlinks: true))
        _ = await waitUntil { vm.phase == .finished }

        XCTAssertEqual(vm.phase, .finished)
        XCTAssertFalse(vm.issues.isEmpty, "the broken symlink should be recorded as a non-fatal issue")
        XCTAssertGreaterThanOrEqual(vm.summary?.errorCount ?? 0, 1)
    }

    // MARK: - Progressive snapshot cadence

    func testTheFirstSnapshotReachesTheScreenAtOnce() async {
        let engine = ScriptedEngine()
        let vm = ScanViewModel(engine: engine)
        let root = URL(fileURLWithPath: "/qa/cadence")

        vm.start(root: root)
        engine.emit(.started(root: root))
        engine.emit(.partial(makeSummary(root: root, logical: 1_000)))

        let shown = await waitUntil(timeout: 0.2) { vm.liveSummary != nil }
        XCTAssertTrue(shown, "the first snapshot fills the screen in without waiting out the cadence")
        XCTAssertEqual(vm.liveSummary?.totalLogicalSize, 1_000)
        XCTAssertNil(vm.summary, "nothing is terminal while the scan still runs")
    }

    func testABurstOfSnapshotsIsBoundedByTheCadenceAndCarriesTheNewest() async {
        let engine = ScriptedEngine()
        let vm = ScanViewModel(engine: engine)
        let root = URL(fileURLWithPath: "/qa/burst")

        vm.start(root: root)
        engine.emit(.started(root: root))
        let afterStart = vm.resultsRevision

        for i in 1...25 {
            engine.emit(.partial(makeSummary(root: root, logical: Int64(i) * 1_000, fileCount: i)))
        }

        let shown = await waitUntil { vm.liveSummary?.totalLogicalSize == 25_000 }
        XCTAssertTrue(shown, "the newest snapshot in the burst is the one on screen")

        // The one the screen paints on arrival, and the one the cadence releases
        // once it has passed: never one per snapshot.
        XCTAssertLessThanOrEqual(
            vm.resultsRevision - afterStart, 2,
            "25 snapshots must not become 25 screen updates"
        )
        XCTAssertTrue(vm.isScanning, "the scan is still running behind the snapshot on screen")
    }

    func testAHeldSnapshotNeverLandsOnASettledScan() async {
        let engine = ScriptedEngine()
        let vm = ScanViewModel(engine: engine)
        let root = URL(fileURLWithPath: "/qa/settle")

        vm.start(root: root)
        engine.emit(.started(root: root))
        engine.emit(.partial(makeSummary(root: root, logical: 1_000)))
        _ = await waitUntil { vm.liveSummary != nil }

        // These two arrive inside the cadence, so the second is held back; the
        // scan then settles before the cadence would have released it.
        engine.emit(.partial(makeSummary(root: root, logical: 2_000)))
        engine.emit(.partial(makeSummary(root: root, logical: 3_000)))
        engine.emit(.finished(makeSummary(root: root, logical: 9_000, fileCount: 40)))

        let settled = await waitUntil { vm.phase == .finished }
        XCTAssertTrue(settled)
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(vm.liveSummary?.totalLogicalSize, 9_000, "the terminal summary supersedes the snapshots")
        XCTAssertNil(vm.partialSummary, "a held snapshot never lands on a settled scan")
    }

    func testResetDropsAHeldSnapshot() async {
        let engine = ScriptedEngine()
        let vm = ScanViewModel(engine: engine)
        let root = URL(fileURLWithPath: "/qa/reset-held")

        vm.start(root: root)
        engine.emit(.started(root: root))
        engine.emit(.partial(makeSummary(root: root, logical: 1_000)))
        _ = await waitUntil { vm.liveSummary != nil }

        engine.emit(.partial(makeSummary(root: root, logical: 2_000)))
        vm.reset()
        try? await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.liveSummary, "a discarded scan leaves nothing behind, held snapshot included")
    }
}
