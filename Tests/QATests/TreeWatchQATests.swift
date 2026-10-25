import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The watch, exercised through the real scan engine on a real temporary tree:
/// a change is applied to the live tree and the screen follows it, with no
/// re-scan of the folder and no stale marker.
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

        func emit(_ folders: [URL], rootMissing: Bool = false) {
            let reported = rootMissing ? [lastRoot].compactMap { $0 } : folders
            handler?(ScanTreeChange(
                folders: reported,
                isCoarse: rootMissing,
                rootMissing: rootMissing
            ))
        }
    }

    /// Wraps the real engine and counts the scans the app itself asked for.
    /// The updater measures new folders with its own engine, so this count is
    /// what proves a change did not re-scan the folder.
    private final class CountingEngine: ScanEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let wrapped = FileScanEngine()

        var scans: Int {
            lock.withLock { count }
        }

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            lock.withLock { count += 1 }
            return wrapped.scan(request)
        }

        func cancel() async {
            await wrapped.cancel()
        }
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TreeWatchQA-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> String {
            root.appendingPathComponent(relative).path
        }

        func write(_ bytes: Int, to relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0, count: bytes).write(to: url)
        }

        func remove(_ relative: String) throws {
            try FileManager.default.removeItem(atPath: path(relative))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Helpers

    private func makeEnvironment(
        options: ScanOptions = .standard,
        policy: LiveUpdatePolicy = LiveUpdatePolicy(
            quietPeriod: .milliseconds(60),
            maxFoldersPerBatch: 64,
            maxSubtreeScansPerBatch: 4
        ),
        watcher: FakeWatcher
    ) -> (ScanViewModel, CountingEngine, WatchPreferences) {
        let name = "TreeWatchQA-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let store = ScanOptionsStore(defaults: defaults)
        store.options = options
        let preferences = WatchPreferences(defaults: defaults)
        let engine = CountingEngine()
        let viewModel = ScanViewModel(
            engine: engine,
            optionsStore: store,
            watchPreferences: preferences,
            watcher: watcher,
            updatePolicy: policy
        )
        return (viewModel, engine, preferences)
    }

    /// Starts a scan and waits for the settled screen: the scan finished, its
    /// tree is installed, and the watch is armed.
    private func assertSettled(
        _ viewModel: ScanViewModel,
        root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        viewModel.start(root: root, options: viewModel.optionsStore.options)
        let settled = await waitUntil(timeout: 20) {
            viewModel.phase == .finished && viewModel.liveTree != nil && viewModel.isWatching
        }
        XCTAssertTrue(settled, "the scan should settle, install its tree, and arm the watch", file: file, line: line)
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

    // MARK: - Applying a change

    func testAFileCreatedInTheScannedFolderAppearsWithoutARescan() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(1_000, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, engine, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 1_000)

        try fixture.write(4_000, to: "added.bin")
        watcher.emit([fixture.root])

        let updated = await waitUntil { viewModel.liveTree?.totalLogicalSize == 5_000 }
        XCTAssertTrue(updated, "the tree should absorb the new file")
        XCTAssertEqual(engine.scans, 1, "the screen was kept current without re-scanning the folder")
        XCTAssertFalse(viewModel.resultsAreStale)
        XCTAssertFalse(viewModel.isUpdating)
        XCTAssertNotNil(
            viewModel.liveChildren(atPath: fixture.root.path)?.first { $0.name == "added.bin" },
            "the explorer's rows read the tree"
        )
    }

    func testAFileThatGrewIsUpdatedInPlace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(1_000, to: "growing.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)

        try fixture.write(3_000, to: "growing.bin")
        watcher.emit([fixture.root])

        let updated = await waitUntil { viewModel.liveNode(atPath: fixture.path("growing.bin"))?.logicalSize == 3_000 }
        XCTAssertTrue(updated)
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 3_000)
    }

    func testANewFolderIsMeasuredAndAppears() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)

        try fixture.write(2_000, to: "Pictures/a.bin")
        watcher.emit([fixture.root])

        let measured = await waitUntil {
            viewModel.liveNode(atPath: fixture.path("Pictures"))?.fileCount == 1
        }
        XCTAssertTrue(measured, "a folder that arrived is measured, not assumed")
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 2_100)
    }

    func testARemovedFileDisappears() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(1_000, to: "a.bin")
        try fixture.write(2_000, to: "b.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)

        try fixture.remove("a.bin")
        watcher.emit([fixture.root])

        let removed = await waitUntil { viewModel.liveTree?.totalLogicalSize == 2_000 }
        XCTAssertTrue(removed)
        XCTAssertNil(viewModel.liveNode(atPath: fixture.path("a.bin")))
    }

    func testABurstOfChangesIsAppliedOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(
            policy: LiveUpdatePolicy(quietPeriod: .milliseconds(150), maxFoldersPerBatch: 64, maxSubtreeScansPerBatch: 4),
            watcher: watcher
        )
        await assertSettled(viewModel, root: fixture.root)
        let revision = viewModel.resultsRevision

        try fixture.write(100, to: "one.bin")
        watcher.emit([fixture.root])
        try fixture.write(100, to: "two.bin")
        watcher.emit([fixture.root])

        let applied = await waitUntil { viewModel.liveTree?.totalLogicalSize == 300 }
        XCTAssertTrue(applied)
        XCTAssertEqual(viewModel.resultsRevision, revision + 1, "the screen rebuilt once for the burst")
    }

    func testABatchNamingMoreFoldersThanOneUpdaterPassAppliesThemAll() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var folders: [URL] = []
        for step in 0..<20 {
            try fixture.write(100, to: "folder-\(step)/a.bin")
            folders.append(fixture.root.appendingPathComponent("folder-\(step)", isDirectory: true))
        }

        let watcher = FakeWatcher()
        // Three folders per updater pass: the rest must come back as deferred
        // work and be applied, not dropped.
        let (viewModel, _, _) = makeEnvironment(
            policy: LiveUpdatePolicy(
                quietPeriod: .milliseconds(30),
                maxFoldersPerBatch: 3,
                maxSubtreeScansPerBatch: 2
            ),
            watcher: watcher
        )
        await assertSettled(viewModel, root: fixture.root)
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 2_000)

        for step in 0..<20 {
            try fixture.write(10, to: "folder-\(step)/b.bin")
        }
        watcher.emit(folders)

        let updated = await waitUntil(timeout: 20) {
            viewModel.liveTree?.totalLogicalSize == 2_200
        }
        XCTAssertTrue(updated, "every folder the batch names is reconciled, across updater passes")
    }

    // MARK: - The rules the tree keeps

    func testHiddenItemsStayOutOfTheTree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(10, to: "visible.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(
            options: ScanOptions(includeHidden: false),
            watcher: watcher
        )
        await assertSettled(viewModel, root: fixture.root)

        try fixture.write(1_000, to: ".hidden.bin")
        watcher.emit([fixture.root])

        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 10, "a hidden item the scan skipped is not added")
        XCTAssertNil(viewModel.liveNode(atPath: fixture.path(".hidden.bin")))
    }

    func testTheWatchReceivesTheScansOwnExclusions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(10, to: "a.bin")
        let excluded = fixture.root.appendingPathComponent("Archives", isDirectory: true)

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(
            options: ScanOptions(excludedPaths: [excluded]),
            watcher: watcher
        )
        await assertSettled(viewModel, root: fixture.root)
        XCTAssertEqual(
            watcher.lastExcludedPaths.map { $0.standardizedFileURL.path },
            [excluded.standardizedFileURL.path]
        )
    }

    // MARK: - When the watch is not running

    func testTurningThePreferenceOffStopsTheWatchAtOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, preferences) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)

        preferences.keepsResultsCurrent = false
        viewModel.watchPreferenceChanged()
        XCTAssertFalse(viewModel.isWatching)
        XCTAssertFalse(watcher.isRunning)

        try fixture.write(1_000, to: "late.bin")
        watcher.emit([fixture.root])
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 100, "a batch in flight cannot revive the watch")
    }

    func testTheWatchIsOnlyArmedOnTheResultsRoute() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)
        XCTAssertTrue(viewModel.isWatching)

        viewModel.showHome()
        XCTAssertFalse(viewModel.isWatching)
        XCTAssertGreaterThan(watcher.stopCount, 0)

        viewModel.showResults()
        XCTAssertTrue(viewModel.isWatching)
        XCTAssertGreaterThan(watcher.startCount, 1)
    }

    func testARootThatIsGoneStopsTheWatchAndMarksTheScreenStale() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)

        watcher.emit([], rootMissing: true)

        let stopped = await waitUntil { !viewModel.isWatching }
        XCTAssertTrue(stopped)
        XCTAssertTrue(viewModel.resultsAreStale)
    }

    /// The whole chain, with nothing faked: a real FSEvents stream, the real
    /// scan engine, the real updater, and the screen's own state machine.
    func testARealFileSystemChangeReachesTheLiveTree() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(1_000, to: "seed.bin")

        let name = "TreeWatchEndToEnd-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let store = ScanOptionsStore(defaults: defaults)
        let preferences = WatchPreferences(defaults: defaults)
        let viewModel = ScanViewModel(
            engine: FileScanEngine(),
            optionsStore: store,
            watchPreferences: preferences,
            watcher: ScanTreeWatcher(latency: 0.1),
            updatePolicy: LiveUpdatePolicy(
                quietPeriod: .milliseconds(100),
                maxFoldersPerBatch: 64,
                maxSubtreeScansPerBatch: 4
            )
        )
        viewModel.start(root: fixture.root, options: store.options)
        let settled = await waitUntil(timeout: 25) {
            viewModel.phase == .finished && viewModel.liveTree != nil && viewModel.isWatching
        }
        XCTAssertTrue(settled, "the scan should settle, install its tree, and arm the watch")

        try fixture.write(3_000, to: "added.bin")

        let updated = await waitUntil(timeout: 25) {
            viewModel.liveTree?.totalLogicalSize == 4_000
        }
        XCTAssertTrue(updated, "a write in the scanned folder should reach the tree through FSEvents")
        XCTAssertFalse(viewModel.resultsAreStale)
        XCTAssertNotNil(
            viewModel.liveChildren(atPath: fixture.root.path)?.first { $0.name == "added.bin" }
        )
    }

    func testANewScanReplacesTheTreeAndTheOldWatchCannotTouchIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write(100, to: "seed.bin")

        let watcher = FakeWatcher()
        let (viewModel, _, _) = makeEnvironment(watcher: watcher)
        await assertSettled(viewModel, root: fixture.root)
        let firstTree = viewModel.liveTree

        // A batch is queued, then the scan is replaced before it is applied.
        try fixture.write(1_000, to: "between.bin")
        watcher.emit([fixture.root])
        await assertSettled(viewModel, root: fixture.root)

        let replaced = await waitUntil { viewModel.liveTree !== firstTree }
        XCTAssertTrue(replaced, "a new scan installs its own tree")
        XCTAssertEqual(viewModel.liveTree?.totalLogicalSize, 1_100, "the new scan measured everything on disk")
    }
}
