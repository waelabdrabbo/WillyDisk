import XCTest
import Foundation
@testable import DiskCore

/// The updater: what a folder re-listing does to the arena, and whether the arena
/// a watcher has been editing still says what a fresh scan of the same disk says.
final class LiveTreeUpdaterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTreeUpdater-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Fixtures

    private func write(_ bytes: Int, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    private func scan(_ policy: LiveTreePolicy = LiveTreePolicy()) async throws -> ScanSummary {
        let request = ScanRequest(
            root: root,
            followSymlinks: policy.followSymlinks,
            stayOnVolume: policy.stayOnVolume,
            includeHidden: policy.includeHidden,
            excludedPaths: policy.excludedPaths
        )
        var summary: ScanSummary?
        for await event in FileScanEngine().scan(request) {
            switch event {
            case .finished(let finished):
                summary = finished
            case .cancelled:
                XCTFail("the fixture scan was cancelled")
            case .started, .progress, .issue, .partial:
                break
            }
        }
        return try XCTUnwrap(summary)
    }

    private func makeTree(_ policy: LiveTreePolicy = LiveTreePolicy()) async throws -> LiveTree {
        let summary = try await scan(policy)
        return try XCTUnwrap(LiveTree(scanning: summary))
    }

    /// Counts the subtree walks the updater asks for: a file-only change must
    /// cost a directory listing, never an engine run.
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

    /// The strongest check available: reconcile, then scan the same disk again
    /// and require the two trees to agree entry by entry.
    private func assertMatchesAFreshScan(
        _ tree: LiveTree,
        _ policy: LiveTreePolicy = LiveTreePolicy(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fresh = try await makeTree(policy)
        XCTAssertEqual(tree.totalLogicalSize, fresh.totalLogicalSize, "total bytes", file: file, line: line)
        XCTAssertEqual(tree.totalAllocatedSize, fresh.totalAllocatedSize, "allocated bytes", file: file, line: line)
        XCTAssertEqual(tree.fileCount, fresh.fileCount, "files", file: file, line: line)
        XCTAssertEqual(tree.directoryCount, fresh.directoryCount, "folders", file: file, line: line)
        XCTAssertEqual(tree.categorySizes(), fresh.categorySizes(), "categories", file: file, line: line)
        compare(
            tree.scanNode(for: LiveTree.rootID, depth: 64),
            fresh.scanNode(for: LiveTree.rootID, depth: 64),
            path: "",
            file: file,
            line: line
        )
    }

    private func compare(
        _ live: ScanNode?,
        _ scanned: ScanNode?,
        path: String,
        file: StaticString,
        line: UInt
    ) {
        guard let live, let scanned else {
            XCTAssertNil(live, "only the live tree holds \(path)", file: file, line: line)
            XCTAssertNil(scanned, "only the fresh scan holds \(path)", file: file, line: line)
            return
        }
        let name = path.isEmpty ? live.name : path + "/" + live.name
        XCTAssertEqual(live.isDirectory, scanned.isDirectory, name, file: file, line: line)
        XCTAssertEqual(live.isSymlink, scanned.isSymlink, name, file: file, line: line)
        XCTAssertEqual(live.category, scanned.category, name, file: file, line: line)
        XCTAssertEqual(live.logicalSize, scanned.logicalSize, name, file: file, line: line)
        XCTAssertEqual(live.allocatedSize, scanned.allocatedSize, name, file: file, line: line)
        XCTAssertEqual(live.fileCount, scanned.fileCount, name, file: file, line: line)
        XCTAssertEqual(live.directoryCount, scanned.directoryCount, name, file: file, line: line)

        let liveChildren = Dictionary(uniqueKeysWithValues: live.children.map { ($0.name, $0) })
        let scannedChildren = Dictionary(uniqueKeysWithValues: scanned.children.map { ($0.name, $0) })
        XCTAssertEqual(Set(liveChildren.keys), Set(scannedChildren.keys), "children of \(name)", file: file, line: line)
        for childName in Set(liveChildren.keys).intersection(scannedChildren.keys) {
            compare(liveChildren[childName], scannedChildren[childName], path: name, file: file, line: line)
        }
    }

    // MARK: - Files

    func testANewFileIsAdded() async throws {
        try write(1_000, to: "seed.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try write(4_000, to: "added.bin")
        let batch = await updater.apply(changedFolders: [root.path])

        XCTAssertTrue(batch.changed)
        XCTAssertEqual(batch.folders, 1)
        XCTAssertTrue(batch.deferred.isEmpty)
        XCTAssertEqual(tree.fileCount, 2)
        XCTAssertEqual(tree.totalLogicalSize, 5_000)
        XCTAssertNotNil(tree.id(atPath: path("added.bin")))
        try await assertMatchesAFreshScan(tree)
    }

    func testAFileThatGrewKeepsItsIdentity() async throws {
        try write(1_000, to: "growing.bin")
        let tree = try await makeTree()
        let fileID = try XCTUnwrap(tree.id(atPath: path("growing.bin")))
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try write(5_000, to: "growing.bin")
        await updater.apply(changedFolders: [root.path])

        XCTAssertEqual(tree.totalLogicalSize, 5_000)
        let entry = try XCTUnwrap(tree.entry(for: fileID), "a changed file keeps its identity")
        XCTAssertEqual(entry.logicalSize, 5_000)
        try await assertMatchesAFreshScan(tree)
    }

    func testARemovedFileIsRemoved() async throws {
        try write(1_000, to: "a.bin")
        try write(2_000, to: "b.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.removeItem(atPath: path("a.bin"))
        await updater.apply(changedFolders: [root.path])

        XCTAssertEqual(tree.fileCount, 1)
        XCTAssertEqual(tree.totalLogicalSize, 2_000)
        XCTAssertNil(tree.id(atPath: path("a.bin")))
        try await assertMatchesAFreshScan(tree)
    }

    func testARenamedFileBecomesTheNewName() async throws {
        try write(1_000, to: "old.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.moveItem(atPath: path("old.bin"), toPath: path("new.bin"))
        await updater.apply(changedFolders: [root.path])

        XCTAssertEqual(tree.totalLogicalSize, 1_000)
        XCTAssertNil(tree.id(atPath: path("old.bin")))
        XCTAssertNotNil(tree.id(atPath: path("new.bin")))
        try await assertMatchesAFreshScan(tree)
    }

    // MARK: - Folders

    func testANewFolderIsMeasuredWithItsContents() async throws {
        try write(100, to: "seed.bin")
        let tree = try await makeTree()
        let engine = CountingEngine()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy(), engine: engine)

        try write(1_000, to: "Pictures/a.bin")
        try write(2_000, to: "Pictures/nested/b.bin")
        let batch = await updater.apply(changedFolders: [root.path])

        XCTAssertTrue(batch.changed)
        XCTAssertEqual(engine.scans, 1, "one subtree walk, for the folder that arrived")
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertEqual(tree.totalLogicalSize, 3_100)
        XCTAssertEqual(tree.directoryCount, 3)
        let pictures = try XCTUnwrap(tree.entry(for: XCTUnwrap(tree.id(atPath: path("Pictures")))))
        XCTAssertEqual(pictures.fileCount, 2)
        XCTAssertEqual(pictures.directoryCount, 2)
        try await assertMatchesAFreshScan(tree)
    }

    func testARemovedFolderTakesItsSubtree() async throws {
        try write(1_000, to: "Folder/a.bin")
        try write(2_000, to: "Folder/sub/b.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.removeItem(atPath: path("Folder"))
        await updater.apply(changedFolders: [root.path])

        XCTAssertEqual(tree.fileCount, 0)
        XCTAssertEqual(tree.totalLogicalSize, 0)
        XCTAssertEqual(tree.directoryCount, 1)
        XCTAssertNil(tree.id(atPath: path("Folder")))
        try await assertMatchesAFreshScan(tree)
    }

    func testAFileReplacedByAFolderIsMeasured() async throws {
        try write(1_000, to: "thing")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.removeItem(atPath: path("thing"))
        try write(500, to: "thing/inside.bin")
        await updater.apply(changedFolders: [root.path])

        let entry = try XCTUnwrap(tree.entry(for: XCTUnwrap(tree.id(atPath: path("thing")))))
        XCTAssertEqual(entry.kind, .directory)
        XCTAssertEqual(entry.fileCount, 1)
        XCTAssertEqual(tree.totalLogicalSize, 500)
        try await assertMatchesAFreshScan(tree)
    }

    func testAFolderThatDisappearedIsRemoved() async throws {
        try write(1_000, to: "Folder/a.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        // The watcher can name the folder itself rather than its parent.
        try FileManager.default.removeItem(atPath: path("Folder"))
        let batch = await updater.apply(changedFolders: [path("Folder")])

        XCTAssertTrue(batch.changed)
        XCTAssertNil(tree.id(atPath: path("Folder")))
        XCTAssertEqual(tree.totalLogicalSize, 0)
    }

    func testARenamedFolderIsMeasuredUnderItsNewName() async throws {
        try write(1_000, to: "Source/a.bin")
        try write(2_000, to: "Source/deep/b.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.moveItem(atPath: path("Source"), toPath: path("Target"))
        await updater.apply(changedFolders: [root.path])

        XCTAssertNil(tree.id(atPath: path("Source")))
        let target = try XCTUnwrap(tree.entry(for: XCTUnwrap(tree.id(atPath: path("Target")))))
        XCTAssertEqual(target.fileCount, 2)
        XCTAssertEqual(target.directoryCount, 2)
        XCTAssertEqual(tree.totalLogicalSize, 3_000)
        try await assertMatchesAFreshScan(tree)
    }

    func testAFolderThatCannotBeReadKeepsItsLastMeasuredContents() async throws {
        try XCTSkipIf(geteuid() == 0, "root can read a folder with no permissions")
        try write(1_000, to: "Locked/inside.bin")
        let tree = try await makeTree()
        let lockedID = try XCTUnwrap(tree.id(atPath: path("Locked")))
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("Locked"))
        await updater.apply(changedFolders: [path("Locked")])

        let denied = try XCTUnwrap(tree.entry(for: lockedID))
        XCTAssertFalse(denied.isAccessible)
        XCTAssertNotNil(denied.errorMessage)
        XCTAssertEqual(denied.fileCount, 1, "the last measured contents stay; nothing was read to contradict them")
        XCTAssertEqual(tree.totalLogicalSize, 1_000)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path("Locked"))
        await updater.apply(changedFolders: [path("Locked")])
        let restored = try XCTUnwrap(tree.entry(for: lockedID))
        XCTAssertTrue(restored.isAccessible)
        XCTAssertNil(restored.errorMessage)
        try await assertMatchesAFreshScan(tree)
    }

    // MARK: - Cost

    func testAFileOnlyChangeNeverRunsAScan() async throws {
        try write(1_000, to: "folder/a.bin")
        let tree = try await makeTree()
        let engine = CountingEngine()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy(), engine: engine)

        try write(2_000, to: "folder/a.bin")
        await updater.apply(changedFolders: [path("folder")])

        XCTAssertEqual(engine.scans, 0, "a file is written from its own stat")
        XCTAssertEqual(tree.totalLogicalSize, 2_000)
    }

    func testABatchThatChangedNothingDoesNotBumpTheRevision() async throws {
        try write(1_000, to: "a.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())
        let revision = tree.revision

        let batch = await updater.apply(changedFolders: [root.path])

        XCTAssertFalse(batch.changed)
        XCTAssertEqual(tree.revision, revision)
    }

    func testNewFoldersBeyondTheBudgetAreDeferredNotHalfApplied() async throws {
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(
            tree: tree,
            policy: LiveTreePolicy(),
            maxFoldersPerBatch: 4,
            maxSubtreeScansPerBatch: 1
        )

        try write(1_000, to: "One/a.bin")
        try write(1_000, to: "Two/b.bin")
        try write(1_000, to: "Three/c.bin")

        let first = await updater.apply(changedFolders: [root.path])
        XCTAssertEqual(first.deferred, [root.path], "the folder is retried whole")
        XCTAssertFalse(first.changed, "nothing half-measured reached the tree")
        XCTAssertEqual(tree.totalLogicalSize, 0)

        let roomier = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy(), maxSubtreeScansPerBatch: 8)
        let second = await roomier.apply(changedFolders: first.deferred)
        XCTAssertTrue(second.deferred.isEmpty)
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertEqual(tree.totalLogicalSize, 3_000)
        try await assertMatchesAFreshScan(tree)
    }

    // MARK: - Measurement failures

    /// Measures nothing: the scan it would run was cancelled.
    private final class CancellingEngine: ScanEngine, @unchecked Sendable {
        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            AsyncStream { continuation in
                continuation.yield(.cancelled(partial:
                    ScanSummary(
                        root: request.root,
                        totalLogicalSize: 0,
                        totalAllocatedSize: 0,
                        fileCount: 0,
                        directoryCount: 1,
                        inaccessibleCount: 0,
                        errorCount: 0,
                        permissionDeniedCount: 0,
                        surfacedIssueCount: 0,
                        startedAt: Date(timeIntervalSince1970: 0),
                        finishedAt: Date(timeIntervalSince1970: 1),
                        categoryBreakdown: [:],
                        largestFiles: [],
                        largestDirectories: [],
                        rootChildren: []
                    )
                ))
                continuation.finish()
            }
        }

        func cancel() async {}
    }

    func testAMeasurementThatCannotBeMadeLeavesTheEntryAsItWas() async throws {
        try write(100, to: "Folder/thing")
        let tree = try await makeTree()

        // The file became a folder, but the walk that would measure it cannot run.
        let manager = FileManager.default
        try manager.removeItem(atPath: path("Folder/thing"))
        try manager.createDirectory(atPath: path("Folder/thing"), withIntermediateDirectories: true)
        try write(50, to: "Folder/thing/inner.bin")

        let updater = LiveTreeUpdater(
            tree: tree,
            policy: LiveTreePolicy(),
            engine: CancellingEngine()
        )
        let batch = await updater.apply(changedFolders: [path("Folder")])
        XCTAssertTrue(batch.deferred.isEmpty)

        let folder = try XCTUnwrap(tree.id(atPath: path("Folder")))
        let thing = try XCTUnwrap(
            tree.child(named: "thing", of: folder),
            "an entry whose new state could not be measured is not deleted"
        )
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: thing)).kind, .file)
    }

    // MARK: - Concurrency

    /// Answers a subtree measurement only when the test lets it, so a second pass
    /// can be submitted while the first is suspended.
    private final class GatedEngine: ScanEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var gate: AsyncStream<Void>.Continuation?
        private var startedFlag = false

        var hasStarted: Bool { lock.withLock { startedFlag } }

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .unbounded)
            let (gateStream, gate) = AsyncStream<Void>.makeStream()
            lock.withLock {
                self.gate = gate
                startedFlag = true
            }
            Task {
                for await _ in gateStream { break }
                for await event in FileScanEngine().scan(request) {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            return stream
        }

        func release() {
            let gate = lock.withLock { () -> AsyncStream<Void>.Continuation? in
                let held = self.gate
                self.gate = nil
                return held
            }
            gate?.yield(())
        }

        func cancel() async {
            release()
        }
    }

    func testAPassInFlightDefersASecondCallersWork() async throws {
        try write(1_000, to: "Existing/a.bin")
        try write(1_000, to: "Folder/b.bin")
        let tree = try await makeTree()
        let engine = GatedEngine()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy(), engine: engine)

        // A folder that arrived: measuring it suspends on the engine.
        try write(100, to: "Folder/New/inside.bin")
        let folderPath = path("Folder")
        let first = Task { await updater.apply(changedFolders: [folderPath]) }
        let started = await waitUntil { engine.hasStarted }
        XCTAssertTrue(started, "the new folder should be measured")

        let second = await updater.apply(changedFolders: [root.path])
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.folders, 0)
        XCTAssertEqual(second.deferred, [root.path], "a pass in flight defers a second caller's work")

        engine.release()
        let firstBatch = await first.value
        XCTAssertTrue(firstBatch.changed)
        XCTAssertNotNil(tree.id(atPath: path("Folder/New")), "the measurement lands once it is let through")

        let third = await updater.apply(changedFolders: second.deferred)
        XCTAssertTrue(third.deferred.isEmpty, "the deferred work is applied by the next pass")
        let measured = try await scan()
        XCTAssertTrue(tree.matches(measured))
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: - Scope

    func testHiddenItemsFollowThePolicy() async throws {
        let policy = LiveTreePolicy(includeHidden: false)
        try write(10, to: "visible.bin")
        try write(20, to: ".hidden.bin")
        let tree = try await makeTree(policy)
        XCTAssertNil(tree.id(atPath: path(".hidden.bin")), "the scan skipped it, so the tree never had it")

        let updater = LiveTreeUpdater(tree: tree, policy: policy)
        try write(1_000, to: "added.bin")
        try write(2_000, to: ".added.bin")
        await updater.apply(changedFolders: [root.path])

        XCTAssertEqual(tree.totalLogicalSize, 1_010)
        XCTAssertNil(tree.id(atPath: path(".added.bin")))
        try await assertMatchesAFreshScan(tree, policy)
    }

    func testExcludedPathsAreNotReconciled() async throws {
        let skipped = root.appendingPathComponent("Skip", isDirectory: true)
        let policy = LiveTreePolicy(excludedPaths: [skipped])
        try write(10, to: "visible.bin")
        try write(20, to: "Skip/inside.bin")
        let tree = try await makeTree(policy)
        XCTAssertNil(tree.id(atPath: path("Skip")))

        let updater = LiveTreeUpdater(tree: tree, policy: policy)
        try write(5_000, to: "Skip/inside.bin")
        try write(1_000, to: "added.bin")
        await updater.apply(changedFolders: [root.path])

        XCTAssertEqual(tree.totalLogicalSize, 1_010)
        XCTAssertNil(tree.id(atPath: path("Skip")))
        try await assertMatchesAFreshScan(tree, policy)
    }

    // MARK: - Links

    func testANewSymlinkIsAZeroSizedLeaf() async throws {
        try write(1_000, to: "target.bin")
        let tree = try await makeTree()
        let updater = LiveTreeUpdater(tree: tree, policy: LiveTreePolicy())

        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("target.bin"))
        await updater.apply(changedFolders: [root.path])

        let entry = try XCTUnwrap(tree.entry(for: XCTUnwrap(tree.id(atPath: path("link")))))
        XCTAssertTrue(entry.isSymlink)
        XCTAssertEqual(entry.fileCount, 0)
        XCTAssertEqual(entry.logicalSize, 0)
        XCTAssertEqual(tree.totalLogicalSize, 1_000, "the link adds no bytes")
        try await assertMatchesAFreshScan(tree)
    }

    func testAFollowedSymlinkToAFileCountsTheTarget() async throws {
        let policy = LiveTreePolicy(followSymlinks: true)
        try write(1_000, to: "target.bin")
        let tree = try await makeTree(policy)
        let updater = LiveTreeUpdater(tree: tree, policy: policy)

        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: path("target.bin"))
        await updater.apply(changedFolders: [root.path])

        let entry = try XCTUnwrap(tree.entry(for: XCTUnwrap(tree.id(atPath: path("link")))))
        XCTAssertTrue(entry.isSymlink)
        XCTAssertEqual(entry.fileCount, 1)
        XCTAssertEqual(entry.logicalSize, 1_000)
        XCTAssertEqual(tree.totalLogicalSize, 2_000)
        try await assertMatchesAFreshScan(tree, policy)
    }

    // MARK: - Batching

    func testOnlyTheOutermostChangedFolderIsReconciled() {
        XCTAssertEqual(LiveTreeUpdater.outermost(["/a/b", "/a", "/a/c/d"]), ["/a"])
        XCTAssertEqual(LiveTreeUpdater.outermost(["/a", "/b", "/a"]), ["/a", "/b"])
        XCTAssertEqual(LiveTreeUpdater.outermost(["/a/b", "/a/c"]), ["/a/b", "/a/c"])
        XCTAssertEqual(LiveTreeUpdater.outermost(["/", "/a"]), ["/"])
    }
}
