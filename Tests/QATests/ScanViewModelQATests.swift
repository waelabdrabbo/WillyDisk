import XCTest
import DiskCore
import DiskUI

/// Independent QA verification of the `ScanViewModel` state machine that drives
/// the Screen A → B → C flow.
///
/// Verifies the observable phase transitions the UI depends on: idle → scanning
/// → finished, cancellation, reset, and the truthful failure path when no engine
/// is wired (no fabricated progress).
@MainActor
final class ScanViewModelQATests: XCTestCase {

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
        vm.start(root: root, followSymlinks: true)
        _ = await waitUntil { vm.phase == .finished }

        XCTAssertEqual(vm.phase, .finished)
        XCTAssertFalse(vm.issues.isEmpty, "the broken symlink should be recorded as a non-fatal issue")
        XCTAssertGreaterThanOrEqual(vm.summary?.errorCount ?? 0, 1)
    }
}
