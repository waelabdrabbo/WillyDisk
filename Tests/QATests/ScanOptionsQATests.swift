import XCTest
@testable import DiskCore
@testable import DiskUI

/// Verifies the scan options a scan is started with, the line that dates the
/// results, and the ranking behind the explorer's largest lists.
@MainActor
final class ScanOptionsQATests: XCTestCase {

    /// An engine that records every request and keeps the stream open until the
    /// test finishes it, so the first scan's slot is free for the next one.
    private final class RecordingEngine: ScanEngine, @unchecked Sendable {
        private(set) var requests: [ScanRequest] = []
        private var continuations: [AsyncStream<ScanEvent>.Continuation] = []

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            requests.append(request)
            return AsyncStream { continuation in
                continuations.append(continuation)
            }
        }

        func cancel() async {}

        func finishLast(summary: ScanSummary) {
            guard let continuation = continuations.last else { return }
            continuation.yield(.finished(summary))
            continuation.finish()
        }
    }

    private func makeSummary(root: URL) -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: 1,
            totalAllocatedSize: 1,
            fileCount: 1,
            directoryCount: 1,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(),
            finishedAt: Date(),
            categoryBreakdown: [:],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )
    }

    private func makeNode(_ path: String, size: Int64, isDirectory: Bool = false) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            isSymlink: false,
            category: isDirectory ? .other : .documents,
            logicalSize: size,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - Options

    func testStandardOptionsAreTheSafeDefaults() {
        XCTAssertEqual(ScanOptions.standard, ScanOptions(followSymlinks: false,
                                                        stayOnVolume: true,
                                                        includeHidden: true))
        XCTAssertEqual(ScanOptions.standard.summary,
                       "Hidden items included, stays on this volume, symbolic links not followed")
    }

    func testOptionsRoundTripThroughTheStore() throws {
        let suiteName = "ScanOptionsQATests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults), .standard)

        let exclusions = [
            URL(fileURLWithPath: "/tmp/one"),
            URL(fileURLWithPath: "/tmp/two")
        ]
        let options = ScanOptions(
            followSymlinks: true,
            stayOnVolume: false,
            includeHidden: false,
            excludedPaths: exclusions
        )
        ScanOptionsStore.save(options, defaults: defaults)
        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults), options)
        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults).excludedPaths.map(\.path),
                       exclusions.map(\.path))
    }

    func testStoreEditsArePersistedAndSeenByAnotherStore() throws {
        let suiteName = "ScanOptionsQATests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ScanOptionsStore(defaults: defaults)
        XCTAssertEqual(store.options, .standard)

        store.options.includeHidden = false
        store.options.followSymlinks = true

        // The Settings window and the source screen each hold the shared store,
        // and a later launch reads the same persisted values.
        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults), store.options)
        XCTAssertEqual(ScanOptionsStore(defaults: defaults).options, store.options)

        store.reset()
        XCTAssertEqual(store.options, .standard)
        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults), .standard)
    }

    func testStoreAddsEachExclusionOnceAndRemovesByResolvedPath() throws {
        let suiteName = "ScanOptionsQATests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ScanOptionsStore(defaults: defaults)
        let one = URL(fileURLWithPath: "/tmp/one")
        let two = URL(fileURLWithPath: "/tmp/two")

        store.addExclusions([
            one,
            URL(fileURLWithPath: "/tmp/one/../one"),
            two
        ])

        XCTAssertEqual(store.options.excludedPaths.map(\.path), [one.path, two.path])
        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults).excludedPaths.map(\.path),
                       [one.path, two.path])

        store.removeExclusion(URL(fileURLWithPath: "/tmp/one/../one"))
        XCTAssertEqual(store.options.excludedPaths.map(\.path), [two.path])
        XCTAssertEqual(ScanOptionsStore.load(defaults: defaults).excludedPaths.map(\.path),
                       [two.path])
    }

    // MARK: - The view model carries the options

    func testStartCarriesTheOptionsIntoTheRequestAndRescanUsesTheCurrentStore() async throws {
        let suiteName = "ScanOptionsQATests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ScanOptionsStore(defaults: defaults)
        let engine = RecordingEngine()
        let vm = ScanViewModel(engine: engine, optionsStore: store)
        let root = URL(fileURLWithPath: "/qa/options")
        let exclusions = [URL(fileURLWithPath: "/qa/options/Caches")]
        let options = ScanOptions(
            followSymlinks: true,
            stayOnVolume: false,
            includeHidden: false,
            excludedPaths: exclusions
        )
        store.options = options

        vm.start(root: root, options: store.options)

        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests[0].followSymlinks, true)
        XCTAssertEqual(engine.requests[0].stayOnVolume, false)
        XCTAssertEqual(engine.requests[0].includeHidden, false)
        XCTAssertEqual(engine.requests[0].excludedPaths, exclusions)
        XCTAssertEqual(vm.lastOptions, options)
        XCTAssertNotNil(vm.scanStartedAt)

        engine.finishLast(summary: makeSummary(root: root))
        let finished = await waitUntil { vm.phase == .finished }
        XCTAssertTrue(finished)

        // Rescan is a new scan: the options now in the store, not the ones the
        // previous run began with, are what it requests.
        let changed = ScanOptions(
            followSymlinks: false,
            stayOnVolume: true,
            includeHidden: true,
            excludedPaths: [URL(fileURLWithPath: "/qa/options/Trash")]
        )
        store.options = changed
        vm.rescan()

        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertEqual(engine.requests[1].root, root)
        XCTAssertEqual(engine.requests[1].followSymlinks, false)
        XCTAssertEqual(engine.requests[1].stayOnVolume, true)
        XCTAssertEqual(engine.requests[1].includeHidden, true)
        XCTAssertEqual(engine.requests[1].excludedPaths,
                       [URL(fileURLWithPath: "/qa/options/Trash")])
        XCTAssertEqual(vm.lastOptions, changed)
    }

    // MARK: - Presets

    func testPresetCatalogNamesTheUsualLargeLocations() {
        let presets = ScanPresetCatalog.candidates
        XCTAssertEqual(presets.map(\.id),
                       ["home", "downloads", "applications", "caches", "derived-data", "trash"])
        XCTAssertEqual(presets.first?.url, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(presets.allSatisfy { $0.url.isFileURL })
    }

    func testPresetResolutionChecksAvailability() async {
        let resolved = await ScanPresetCatalog.resolved()
        XCTAssertEqual(resolved.map(\.id), ScanPresetCatalog.candidates.map(\.id))
        XCTAssertTrue(resolved.contains { $0.id == "home" && $0.isAvailable })
    }

    // MARK: - Provenance

    func testProvenanceStatesWhenAndHowLong() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let settled = ScanProvenance.settled(startedAt: started, finishedAt: started.addingTimeInterval(83))
        XCTAssertTrue(settled.hasPrefix("Scanned "))
        XCTAssertTrue(settled.hasSuffix("1m 23s"), settled)

        let instant = ScanProvenance.settled(startedAt: started, finishedAt: started.addingTimeInterval(0.4))
        XCTAssertTrue(instant.hasSuffix("<1s"), instant)

        let live = ScanProvenance.live(startedAt: started, now: started.addingTimeInterval(5))
        XCTAssertTrue(live.hasPrefix("Scanning since "))
        XCTAssertTrue(live.hasSuffix("5s so far"), live)
    }

    // MARK: - Largest lists

    func testRankedListDropsEmptyItemsAndRanksBySize() {
        let nodes = [
            makeNode("/scan/a/small.bin", size: 10),
            makeNode("/scan/b/big.zip", size: 300),
            makeNode("/scan/c/zero", size: 0)
        ]

        let ranked = ExplorerQuery.ranked(nodes, search: "")
        XCTAssertEqual(ranked.map(\.name), ["big.zip", "small.bin"])
    }

    func testRankedListSearchMatchesThePathAsWellAsTheName() {
        let nodes = [
            makeNode("/scan/a/small.bin", size: 10),
            makeNode("/scan/b/other.bin", size: 300)
        ]

        let matches = ExplorerQuery.ranked(nodes, search: "a/small")
        XCTAssertEqual(matches.map(\.name), ["small.bin"])
    }

    // MARK: - Row paths

    func testAbbreviatedPathUsesTheHomeDirectory() {
        let home = NSHomeDirectory()
        XCTAssertEqual(PathFormat.abbreviated(home), "~")
        XCTAssertEqual(PathFormat.abbreviated(home + "/Library/Caches"), "~/Library/Caches")
    }

    // MARK: - Counts

    func testCountsUseTheSingularOnlyForOne() {
        XCTAssertEqual(CountFormat.files(1), "1 file")
        XCTAssertEqual(CountFormat.files(2), "2 files")
        XCTAssertEqual(CountFormat.folders(1), "1 folder")
        XCTAssertEqual(CountFormat.items(0), "0 items")
    }
}
