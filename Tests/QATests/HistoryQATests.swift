import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The scan history as the app wires it: a finished scan is remembered with the
/// choices it ran with, a cancelled one is not, and the sheet's comparison comes
/// from the same records the store wrote.
@MainActor
final class HistoryQATests: XCTestCase {

    /// An engine whose stream the test settles by hand, so a scan is finished or
    /// cancelled at the moment the test means it to be.
    private final class ControlledEngine: ScanEngine, @unchecked Sendable {
        private(set) var requests: [ScanRequest] = []
        private var continuations: [AsyncStream<ScanEvent>.Continuation] = []

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            requests.append(request)
            return AsyncStream { continuation in
                continuations.append(continuation)
            }
        }

        func cancel() async {}

        func finish(_ summary: ScanSummary) {
            guard let continuation = continuations.last else { return }
            continuation.yield(.finished(summary))
            continuation.finish()
        }

        func stop(_ partial: ScanSummary?) {
            guard let continuation = continuations.last else { return }
            continuation.yield(.cancelled(partial: partial))
            continuation.finish()
        }
    }

    private var directory: URL!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskHistoryQATests-\(UUID().uuidString)")
        root = directory.appendingPathComponent("Scanned Folder")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeSummary(
        totalLogicalSize: Int64 = 9_000_000,
        fileCount: Int = 42,
        finishedAt: Date = Date()
    ) -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: totalLogicalSize,
            totalAllocatedSize: totalLogicalSize + 1_000,
            fileCount: fileCount,
            directoryCount: 5,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: finishedAt.addingTimeInterval(-3),
            finishedAt: finishedAt,
            categoryBreakdown: [.documents: totalLogicalSize],
            largestFiles: [
                ScanNode(
                    id: UUID(),
                    url: root.appendingPathComponent("report.pdf"),
                    name: "report.pdf",
                    isDirectory: false,
                    isSymlink: false,
                    category: .documents,
                    logicalSize: totalLogicalSize,
                    allocatedSize: totalLogicalSize,
                    fileCount: 1,
                    directoryCount: 0,
                    modifiedAt: nil,
                    isAccessible: true,
                    errorMessage: nil,
                    children: []
                )
            ],
            largestDirectories: [],
            rootChildren: []
        )
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - Recording

    func testFinishedScanIsRecordedWithTheChoicesItRanWith() async throws {
        let suiteName = "HistoryQATests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let optionsStore = ScanOptionsStore(defaults: defaults)

        let store = ScanHistoryStore(directory: directory.appendingPathComponent("history"))
        let history = ScanHistory(store: store)
        let engine = ControlledEngine()
        let viewModel = ScanViewModel(engine: engine, optionsStore: optionsStore, history: history)

        let options = ScanOptions(
            followSymlinks: true,
            stayOnVolume: false,
            includeHidden: false,
            excludedPaths: [root.appendingPathComponent("Archives")]
        )
        viewModel.start(root: root, options: options)
        engine.finish(makeSummary())

        let recorded = await waitUntil { !store.load().records.isEmpty }
        XCTAssertTrue(recorded, "a finished scan should reach the store")

        let record = try XCTUnwrap(store.load().records.first)
        XCTAssertEqual(record.rootPath, root.standardizedFileURL.path)
        XCTAssertEqual(record.totalLogicalSize, 9_000_000)
        XCTAssertEqual(record.fileCount, 42)
        XCTAssertEqual(record.categoryBreakdown[.documents], 9_000_000)
        XCTAssertEqual(record.largestFiles.first?.name, "report.pdf")

        XCTAssertTrue(record.options.followSymlinks, "the run's own options are stored")
        XCTAssertFalse(record.options.includeHidden)
        XCTAssertEqual(record.options.excludedPaths, [root.appendingPathComponent("Archives").standardizedFileURL.path])

        XCTAssertEqual(history.records(for: root).count, 1)
        XCTAssertTrue(history.records(for: URL(fileURLWithPath: "/elsewhere")).isEmpty)
    }

    func testCancelledScanIsNotRecorded() async throws {
        let store = ScanHistoryStore(directory: directory.appendingPathComponent("history"))
        let history = ScanHistory(store: store)
        let engine = ControlledEngine()
        let viewModel = ScanViewModel(engine: engine, history: history)

        viewModel.start(root: root)
        engine.stop(makeSummary())

        // Give a record the chance to be written before asserting there is none.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(store.load().records.isEmpty, "a partial scan is not a comparable run")
        XCTAssertEqual(viewModel.phase, .cancelled)
    }

    func testEachFinishedRunAddsOneRecord() async throws {
        let store = ScanHistoryStore(directory: directory.appendingPathComponent("history"))
        let history = ScanHistory(store: store)
        let engine = ControlledEngine()
        let viewModel = ScanViewModel(engine: engine, history: history)

        viewModel.start(root: root)
        engine.finish(makeSummary(totalLogicalSize: 1_000_000, finishedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = await waitUntil { store.load().records.count == 1 }

        viewModel.start(root: root)
        engine.finish(makeSummary(totalLogicalSize: 2_000_000, finishedAt: Date(timeIntervalSince1970: 1_700_100_000)))
        let recorded = await waitUntil { store.load().records.count == 2 }
        XCTAssertTrue(recorded)

        let records = store.load().records
        XCTAssertEqual(records.map(\.totalLogicalSize), [2_000_000, 1_000_000], "newest first")
    }

    // MARK: - Comparison from stored runs

    func testStoredRunsCompareWithTheirOwnNumbers() async throws {
        let store = ScanHistoryStore(directory: directory.appendingPathComponent("history"))
        let engine = ControlledEngine()
        let viewModel = ScanViewModel(engine: engine, history: ScanHistory(store: store))

        viewModel.start(root: root)
        engine.finish(makeSummary(totalLogicalSize: 1_000_000, fileCount: 10, finishedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        _ = await waitUntil { store.load().records.count == 1 }

        viewModel.start(root: root)
        engine.finish(makeSummary(totalLogicalSize: 4_000_000, fileCount: 13, finishedAt: Date(timeIntervalSince1970: 1_700_500_000)))
        _ = await waitUntil { store.load().records.count == 2 }

        let records = store.load().records
        XCTAssertEqual(records.count, 2)
        let comparison = ScanComparison.between(records[1], records[0])
        XCTAssertEqual(comparison.totalLogicalDelta, 3_000_000)
        XCTAssertEqual(comparison.fileCountDelta, 3)
        XCTAssertEqual(comparison.files.first?.change, .grown)
        XCTAssertEqual(comparison.files.first?.delta, 3_000_000)
        XCTAssertFalse(comparison.optionsDiffer)
    }
}
