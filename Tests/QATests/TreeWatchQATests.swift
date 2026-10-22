import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The watcher-driven refresh, exercised without touching FSEvents: a scripted
/// watcher says what changed, and a multi-shot engine says what the scan found.
@MainActor
final class TreeWatchQATests: XCTestCase {

    // MARK: - Doubles

    /// Reports the batches the test chooses and records its own lifecycle.
    @MainActor
    private final class FakeWatcher: TreeWatching {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var lastRoot: URL?
        private(set) var lastExcludedPaths: [URL] = []
        private(set) var lastStayOnVolume = true
        private(set) var isRunning = false

        private var handler: (@Sendable (ScanTreeChange) -> Void)?

        func start(
            root: URL,
            excludedPaths: [URL],
            stayOnVolume: Bool,
            onChange: @escaping @Sendable (ScanTreeChange) -> Void
        ) throws {
            startCount += 1
            lastRoot = root
            lastExcludedPaths = excludedPaths
            lastStayOnVolume = stayOnVolume
            handler = onChange
            isRunning = true
        }

        func stop() {
            stopCount += 1
            isRunning = false
            // The handler stays: a real stream can deliver a batch that was
            // already in flight when it was stopped.
        }

        func emit(
            _ folders: [URL],
            folderCount: Int? = nil,
            rootMissing: Bool = false
        ) {
            // A real scope names the root when it disappears, and a batch is a
            // list of folders rather than the files inside them.
            let reported = rootMissing ? [lastRoot].compactMap { $0 } : folders
            handler?(ScanTreeChange(
                folders: reported,
                folderCount: folderCount,
                isCoarse: rootMissing,
                rootMissing: rootMissing
            ))
        }
    }

    /// A `ScanEngine` that opens a fresh stream for every request, so a refresh
    /// can be answered separately from the scan that came before it.
    private final class MultiShotEngine: ScanEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [AsyncStream<ScanEvent>.Continuation] = []
        private var recordedRequests: [ScanRequest] = []

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests.count
        }

        var requests: [ScanRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .unbounded)
            lock.lock()
            recordedRequests.append(request)
            continuations.append(continuation)
            lock.unlock()
            return stream
        }

        func cancel() async {
            finishLatest()
        }

        func emitLatest(_ event: ScanEvent) {
            lock.lock()
            let continuation = continuations.last
            lock.unlock()
            continuation?.yield(event)
        }

        func finishLatest() {
            lock.lock()
            let continuation = continuations.last
            lock.unlock()
            continuation?.finish()
        }
    }

    // MARK: - Helpers

    private func makeEnvironment(
        history: ScanHistory? = nil,
        policy: RefreshPolicy = RefreshPolicy(
            quietPeriod: .milliseconds(30),
            cooldown: .zero,
            budget: 10
        )
    ) -> (ScanViewModel, MultiShotEngine, FakeWatcher, ScanOptionsStore, WatchPreferences) {
        let name = "TreeWatchQATests-\(UUID().uuidString)"
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: name)
        }
        let defaults = UserDefaults(suiteName: name)!
        let options = ScanOptionsStore(defaults: defaults)
        let preferences = WatchPreferences(defaults: defaults)
        let engine = MultiShotEngine()
        let watcher = FakeWatcher()
        let viewModel = ScanViewModel(
            engine: engine,
            optionsStore: options,
            history: history,
            watchPreferences: preferences,
            watcher: watcher,
            refreshPolicy: policy
        )
        return (viewModel, engine, watcher, options, preferences)
    }

    private let root = URL(fileURLWithPath: "/scan/tree", isDirectory: true)

    private func makeSummary(
        logical: Int64,
        startedAt: Date = Date(timeIntervalSince1970: 0),
        finishedAt: Date = Date(timeIntervalSince1970: 1),
        fileCount: Int = 1
    ) -> ScanSummary {
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
            startedAt: startedAt,
            finishedAt: finishedAt,
            categoryBreakdown: [.documents: logical],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )
    }

    /// Settles a scan on the results route and leaves the watcher armed.
    private func settle(
        _ viewModel: ScanViewModel,
        _ engine: MultiShotEngine,
        logical: Int64 = 100,
        summary: ScanSummary? = nil
    ) async {
        viewModel.start(root: root, options: viewModel.optionsStore.options)
        engine.emitLatest(.started(root: root))
        engine.emitLatest(.finished(summary ?? makeSummary(logical: logical)))
        _ = await waitUntil { viewModel.phase == .finished && viewModel.isWatching }
    }

    private func assertEventually(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let met = await waitUntil(timeout: timeout, condition)
        XCTAssertTrue(met, "condition was not met before the timeout", file: file, line: line)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private var changeFolder: URL { root.appendingPathComponent("Downloads", isDirectory: true) }

    // MARK: - The refresh

    func testAChangeRefreshesSettledResultsInPlace() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment()
        await settle(viewModel, engine)

        XCTAssertTrue(viewModel.isWatching)
        watcher.emit([changeFolder])

        await assertEventually { viewModel.isRefreshing }
        XCTAssertTrue(viewModel.resultsAreStale)
        XCTAssertEqual(engine.requestCount, 2)
        XCTAssertEqual(viewModel.liveSummary?.totalLogicalSize, 100, "the old measurement stays on screen")
        XCTAssertNil(viewModel.progress)

        engine.emitLatest(.partial(makeSummary(logical: 999)))
        XCTAssertEqual(viewModel.liveSummary?.totalLogicalSize, 100, "a refresh never shows a partial")
        XCTAssertNil(viewModel.progress)

        engine.emitLatest(.finished(makeSummary(logical: 60)))
        await assertEventually { !viewModel.isRefreshing && viewModel.summary?.totalLogicalSize == 60 }
        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertFalse(viewModel.resultsAreStale)
        XCTAssertEqual(viewModel.changedFolders, [])
        XCTAssertTrue(viewModel.isWatching, "the watch resumes once the new measurement lands")
    }

    func testTheRefreshRepeatsTheOptionsTheResultsCameFrom() async {
        let (viewModel, engine, watcher, options, _) = makeEnvironment()
        let original = ScanOptions(
            followSymlinks: true,
            stayOnVolume: false,
            includeHidden: false,
            excludedPaths: [root.appendingPathComponent("Archives")]
        )
        options.options = original
        await settle(viewModel, engine)

        // A later Settings edit must not quietly change what the watched tree
        // means while its results are still on screen.
        options.options = .standard
        watcher.emit([changeFolder])
        await assertEventually { viewModel.isRefreshing }

        let request = engine.requests.last
        XCTAssertEqual(request?.followSymlinks, true)
        XCTAssertEqual(request?.stayOnVolume, false)
        XCTAssertEqual(request?.includeHidden, false)
        XCTAssertEqual(
            request?.excludedPaths.map { $0.standardizedFileURL.path },
            original.excludedPaths.map { $0.standardizedFileURL.path }
        )
    }

    func testAnAutomaticRefreshIsNotRecordedInHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeWatchHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScanHistoryStore(directory: directory)
        let history = ScanHistory(store: store)
        let (viewModel, engine, watcher, _, _) = makeEnvironment(history: history)

        await settle(viewModel, engine)
        await assertEventually { store.load().records.count == 1 }

        watcher.emit([changeFolder])
        await assertEventually { viewModel.isRefreshing }
        engine.emitLatest(.finished(makeSummary(logical: 60)))
        await assertEventually { !viewModel.isRefreshing }

        // Give a record the chance to be written before asserting there is none.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(store.load().records.count, 1, "a refresh updates the screen, not the record")
    }

    // MARK: - When it does not refresh

    func testASlowScanIsOfferedARescanInsteadOfRepeated() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment()
        await settle(
            viewModel,
            engine,
            summary: makeSummary(
                logical: 500,
                startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 60)
            )
        )

        watcher.emit([changeFolder])
        await assertEventually { viewModel.resultsAreStale }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(viewModel.isUpdating, "a run over the budget is not repeated automatically")
        XCTAssertEqual(engine.requestCount, 1)
        XCTAssertTrue(viewModel.isWatching)
    }

    func testACancelledRefreshKeepsTheCompleteResultsAndStopsWatching() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment()
        await settle(viewModel, engine, logical: 100)

        watcher.emit([changeFolder])
        await assertEventually { viewModel.isRefreshing }
        engine.emitLatest(.cancelled(partial: nil))
        await assertEventually { !viewModel.isRefreshing }

        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(viewModel.summary?.totalLogicalSize, 100)
        XCTAssertTrue(viewModel.resultsAreStale)
        XCTAssertFalse(viewModel.isWatching)
        XCTAssertFalse(viewModel.isRefreshPending)
        XCTAssertEqual(engine.requestCount, 2)
    }

    func testARootThatIsGoneStopsTheWatchAndNeverRefreshes() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment(
            policy: RefreshPolicy(quietPeriod: .milliseconds(400), cooldown: .zero, budget: 10)
        )
        await settle(viewModel, engine)

        watcher.emit([changeFolder])
        await assertEventually { viewModel.isRefreshPending }

        watcher.emit([], rootMissing: true)
        await assertEventually { !viewModel.isWatching }

        XCTAssertTrue(viewModel.resultsAreStale)
        XCTAssertFalse(viewModel.isUpdating)
        XCTAssertFalse(viewModel.isRefreshPending)
        XCTAssertTrue(viewModel.changedFolders.map(\.path).contains(root.path))
        XCTAssertEqual(engine.requestCount, 1)
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(engine.requestCount, 1, "a missing root is never re-measured")
    }

    func testTurningThePreferenceOffStopsTheWatchAtOnce() async {
        let (viewModel, engine, watcher, _, preferences) = makeEnvironment()
        await settle(viewModel, engine)
        XCTAssertTrue(viewModel.isWatching)

        preferences.keepsResultsCurrent = false
        viewModel.watchPreferenceChanged()
        XCTAssertFalse(viewModel.isWatching)
        XCTAssertFalse(watcher.isRunning)

        // A batch already in flight cannot revive the stale state.
        watcher.emit([changeFolder])
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(viewModel.resultsAreStale)
        XCTAssertEqual(engine.requestCount, 1)
    }

    func testTurningThePreferenceOffDropsAPendingRefresh() async {
        let (viewModel, engine, watcher, _, preferences) = makeEnvironment(
            policy: RefreshPolicy(quietPeriod: .milliseconds(400), cooldown: .zero, budget: 10)
        )
        await settle(viewModel, engine)

        watcher.emit([changeFolder])
        await assertEventually { viewModel.isRefreshPending }

        preferences.keepsResultsCurrent = false
        viewModel.watchPreferenceChanged()
        XCTAssertFalse(viewModel.isRefreshPending)
        XCTAssertFalse(viewModel.isWatching)

        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(engine.requestCount, 1, "a scheduled update must not survive the switch")
        XCTAssertTrue(viewModel.resultsAreStale, "the change still happened, so the results stay stale")
    }

    func testLeavingTheScreenStopsTheWatchAndDropsAPendingRefresh() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment(
            policy: RefreshPolicy(quietPeriod: .milliseconds(500), cooldown: .zero, budget: 10)
        )
        await settle(viewModel, engine)

        watcher.emit([changeFolder])
        await assertEventually { viewModel.isRefreshPending }
        viewModel.showHome()

        XCTAssertFalse(viewModel.isWatching)
        XCTAssertFalse(viewModel.isRefreshPending)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(engine.requestCount, 1, "leaving the screen cancels the scheduled update")

        viewModel.showResults()
        XCTAssertTrue(viewModel.isWatching, "returning to settled results arms the watch again")
    }

    // MARK: - Superseded work

    func testANewScanDropsABatchFromTheOldWatch() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment()
        await settle(viewModel, engine)

        viewModel.start(root: root)
        XCTAssertEqual(viewModel.phase, .scanning)
        XCTAssertFalse(viewModel.isWatching)

        // The fake still holds the old closure, as an in-flight FSEvents batch
        // would.
        watcher.emit([changeFolder])
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(viewModel.resultsAreStale)
        XCTAssertFalse(viewModel.isRefreshPending)
        XCTAssertEqual(engine.requestCount, 2)
    }

    func testTheWatchIsOnlyArmedOnTheResultsRoute() async {
        let (viewModel, engine, watcher, _, _) = makeEnvironment()
        await settle(viewModel, engine)
        XCTAssertTrue(viewModel.isWatching)

        viewModel.showHome()
        XCTAssertFalse(viewModel.isWatching)
        XCTAssertGreaterThan(watcher.stopCount, 0)

        viewModel.showResults()
        XCTAssertTrue(viewModel.isWatching)
        XCTAssertGreaterThan(watcher.startCount, 1)
    }

    // MARK: - End to end

    func testARealChangeRefreshesARealScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TreeWatchEndToEnd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 4_096).write(to: directory.appendingPathComponent("seed.bin"))

        let name = "TreeWatchEndToEnd-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let viewModel = ScanViewModel(
            engine: FileScanEngine(),
            optionsStore: ScanOptionsStore(defaults: defaults),
            watchPreferences: WatchPreferences(defaults: defaults),
            watcher: ScanTreeWatcher(latency: 0.2),
            refreshPolicy: RefreshPolicy(quietPeriod: .milliseconds(100), cooldown: .zero, budget: 30)
        )

        viewModel.start(root: directory, options: .standard)
        let settled = await waitUntil(timeout: 15) {
            viewModel.phase == .finished && viewModel.isWatching
        }
        XCTAssertTrue(settled, "the fixture scan should settle and arm the watch")
        let before = try XCTUnwrap(viewModel.summary?.totalLogicalSize)

        try Data(repeating: 1, count: 1_000_000)
            .write(to: directory.appendingPathComponent("added.bin"))

        let refreshed = await waitUntil(timeout: 20) {
            viewModel.phase == .finished
                && (viewModel.summary?.totalLogicalSize ?? 0) > before
        }
        XCTAssertTrue(refreshed, "a change in the root should be re-measured; totals stayed at \(before)")
        XCTAssertFalse(viewModel.resultsAreStale)
    }

    // MARK: - Exclusions and options

    func testTheWatchReceivesTheScansOwnExclusions() async {
        let (viewModel, engine, watcher, options, _) = makeEnvironment()
        let excluded = root.appendingPathComponent("Archives", isDirectory: true)
        options.options = ScanOptions(excludedPaths: [excluded])
        await settle(viewModel, engine)

        XCTAssertEqual(
            watcher.lastExcludedPaths.map { $0.standardizedFileURL.path },
            [excluded.standardizedFileURL.path]
        )
    }
}
