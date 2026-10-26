import XCTest
@testable import DiskCore
@testable import DiskUI

/// Verifies the guard in front of a trash action, the seam that performs it, and
/// what the screen says afterwards.
@MainActor
final class ReclaimQATests: XCTestCase {

    // MARK: - Selection

    func testANestedSelectionMovesOnlyTheOutermostPath() {
        let folder = URL(fileURLWithPath: "/Users/me/Library/Caches/com.example")
        let inner = folder.appendingPathComponent("blob.bin")
        let sibling = URL(fileURLWithPath: "/Users/me/Downloads/old.dmg")

        let result = ReclaimSelection.outermost([inner, folder, sibling, folder])

        XCTAssertEqual(result.map(\.path), [folder.path, sibling.path])
    }

    func testAPathThatOnlySharesAPrefixIsNotNested() {
        let cache = URL(fileURLWithPath: "/scan/cache")
        let cache2 = URL(fileURLWithPath: "/scan/cache2/old.bin")
        let inside = URL(fileURLWithPath: "/scan/cache/old.bin")

        let result = ReclaimSelection.outermost([cache, cache2, inside])

        XCTAssertEqual(result.map(\.path), [cache.path, cache2.path],
                       "a longer name and a sibling folder are not inside the selection")
    }

    // MARK: - Fixtures

    private final class RecordingEngine: ScanEngine, @unchecked Sendable {
        private var continuations: [AsyncStream<ScanEvent>.Continuation] = []

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            AsyncStream { continuation in
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

    /// The QA test drives one trash request at a time, so the record needs no
    /// lock; the class is marked unchecked only to cross the seam's Sendable
    /// boundary.
    private final class FakeTrasher: FileTrashing, @unchecked Sendable {
        private(set) var trashed: [URL] = []
        var failure: Error?

        func fail(with error: Error) {
            failure = error
        }

        func trash(_ url: URL) async throws -> URL? {
            trashed.append(url)
            if let failure { throw failure }
            return URL(fileURLWithPath: "/Trash/\(url.lastPathComponent)")
        }
    }

    private func makeSummary(root: URL, files: [ScanNode] = [], directories: [ScanNode] = []) -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: files.reduce(0) { $0 + $1.logicalSize } + 1,
            totalAllocatedSize: files.reduce(0) { $0 + $1.allocatedSize } + 1,
            fileCount: files.count,
            directoryCount: directories.count + 1,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(),
            finishedAt: Date(),
            categoryBreakdown: [:],
            largestFiles: files,
            largestDirectories: directories,
            rootChildren: []
        )
    }

    private func makeNode(_ url: URL, size: Int64 = 1024, isDirectory: Bool = false) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            isSymlink: false,
            category: isDirectory ? .other : .documents,
            logicalSize: size,
            allocatedSize: size,
            fileCount: isDirectory ? 1 : 0,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }

    private func context(
        scanRoot: String = "/Users/me/scan",
        volumeRoot: String? = "/",
        readOnly: Bool = false,
        exists: Bool = true,
        scanning: Bool = false
    ) -> ReclaimContext {
        ReclaimContext(
            scanRoot: URL(fileURLWithPath: scanRoot),
            isScanning: scanning,
            volumeRoot: volumeRoot.map { URL(fileURLWithPath: $0) },
            isVolumeReadOnly: readOnly,
            exists: exists
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - Policy

    func testTheScanRootAndItsAncestorsAreRefused() {
        let target = URL(fileURLWithPath: "/Users/me/scan")
        XCTAssertEqual(ReclaimPolicy.refusal(for: target, in: context(scanRoot: "/Users/me/scan")), .scanRoot)

        let parent = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(
            ReclaimPolicy.refusal(for: parent, in: context(scanRoot: "/Users/me/scan")),
            .scanRootAncestor
        )

        let child = URL(fileURLWithPath: "/Users/me/scan/photo.jpg")
        XCTAssertNil(ReclaimPolicy.refusal(for: child, in: context(scanRoot: "/Users/me/scan")))
    }

    func testAPathNamedLikeTheScanRootButElsewhereIsNotTheRoot() {
        let target = URL(fileURLWithPath: "/Users/other/scan/photo.jpg")
        XCTAssertNil(ReclaimPolicy.refusal(for: target, in: context(scanRoot: "/Users/me/scan")))
    }

    func testVolumeRootsAreRefused() {
        let target = URL(fileURLWithPath: "/Volumes/Archive")
        XCTAssertEqual(
            ReclaimPolicy.refusal(for: target, in: context(volumeRoot: "/Volumes/Archive")),
            .volumeRoot
        )
    }

    func testReadOnlyVolumesAndMissingItemsAreRefused() {
        let target = URL(fileURLWithPath: "/Users/me/scan/a.bin")
        XCTAssertEqual(ReclaimPolicy.refusal(for: target, in: context(readOnly: true)), .readOnlyVolume)
        XCTAssertEqual(ReclaimPolicy.refusal(for: target, in: context(exists: false)), .missing)
    }

    func testScanningRefusesEverythingFirst() {
        let target = URL(fileURLWithPath: "/Users/me/scan/a.bin")
        XCTAssertEqual(ReclaimPolicy.refusal(for: target, in: context(exists: false, scanning: true)), .scanning)
    }

    func testSystemTreesAndTheirRootsAreRefused() {
        let root = context(scanRoot: "/Volumes/Work/scan", volumeRoot: "/Volumes/Work")
        for path in ["/System/Library", "/usr/bin", "/bin/sh", "/sbin/mount", "/Library/Apple",
                     "/private/etc/hosts", "/private/var/db/anything", "/private/var/vm/swapfile"] {
            XCTAssertEqual(
                ReclaimPolicy.refusal(for: URL(fileURLWithPath: path), in: root),
                .protectedPath,
                path
            )
        }
        // `/` is above every scan root, so the scan rule answers first.
        XCTAssertEqual(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: "/"), in: root),
            .scanRootAncestor
        )
        XCTAssertEqual(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: NSHomeDirectory()), in: root),
            .homeFolder
        )
    }

    func testApplicationFoldersAreRefusedButAppsInsideThemAreNot() {
        let root = context(scanRoot: "/Users/me/scan")
        XCTAssertEqual(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: "/Applications"), in: root),
            .protectedPath
        )
        XCTAssertNil(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: "/Applications/Example.app"), in: root)
        )
    }

    func testCachesUnderPrivateAreAllowedButTheirSystemRootsAreNot() {
        let root = context(scanRoot: "/Users/me/scan")
        XCTAssertNil(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: "/private/var/folders/x/Caches/a.bin"), in: root)
        )
        XCTAssertNil(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: "/tmp/scratch/a.bin"), in: root)
        )
        XCTAssertEqual(
            ReclaimPolicy.refusal(for: URL(fileURLWithPath: "/private/var/folders"), in: root),
            .protectedPath
        )
    }

    func testTheDataVolumeIsJudgedByItsUserVisiblePath() {
        let root = context(scanRoot: "/Users/me/scan")
        XCTAssertNil(
            ReclaimPolicy.refusal(
                for: URL(fileURLWithPath: "/System/Volumes/Data/Users/me/Library/Caches/a.bin"),
                in: root
            )
        )
        XCTAssertEqual(
            ReclaimPolicy.refusal(
                for: URL(fileURLWithPath: "/System/Volumes/Data/Users/me/scan"),
                in: root
            ),
            .scanRoot
        )
        XCTAssertEqual(
            ReclaimPolicy.refusal(
                for: URL(fileURLWithPath: "/System/Volumes/Data/System/Library/CoreServices"),
                in: root
            ),
            .protectedPath
        )
    }

    func testASymlinkToAProtectedTreeIsJudgedByItsTarget() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimQA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let link = folder.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Library"))

        let root = context(scanRoot: folder.path)
        XCTAssertEqual(ReclaimPolicy.refusal(for: link, in: root), .protectedPath)
    }

    func testARealTemporaryFileOutsideTheScanRootPasses() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let item = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimItem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: item)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: item)
        }

        let probe = await ReclaimContextProbe.context(for: item, scanRoot: root)
        XCTAssertTrue(probe.exists)
        XCTAssertEqual(probe.targetPath, ReclaimPolicy.resolvedPath(for: item))
        XCTAssertEqual(probe.scanRootPath, ReclaimPolicy.resolvedPath(for: root))
        XCTAssertNotNil(probe.volumeRootPath)
        XCTAssertNil(ReclaimPolicy.refusal(for: item, in: probe))
    }

    func testABrokenSymlinkStillCountsAsAnEntry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("broken-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: root.appendingPathComponent("missing-target")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let probe = await ReclaimContextProbe.context(for: link, scanRoot: root)
        XCTAssertTrue(probe.exists, "lstat sees the link itself, not its missing target")
        XCTAssertNil(ReclaimPolicy.refusal(for: link, in: probe))
    }

    // MARK: - Trash seam

    func testControllerReportsTheSystemsOwnReason() async {
        let trasher = FakeTrasher()
        trasher.fail(with: NSError(
            domain: "ReclaimQATests",
            code: 1,
            userInfo: [NSLocalizedFailureReasonErrorKey: "Permission denied"]
        ))
        let controller = ReclaimController(trasher: trasher)
        let outcome = await controller.trash(URL(fileURLWithPath: "/Users/me/scan/a.bin"))
        XCTAssertEqual(outcome, .failed("Permission denied"))
    }

    // MARK: - The view model

    private func finishedViewModel(
        root: URL,
        file: ScanNode,
        controller: ReclaimController,
        reclaimLog: ReclaimLog? = nil
    ) async -> ScanViewModel {
        let engine = RecordingEngine()
        let vm = ScanViewModel(
            engine: engine,
            reclaimController: controller,
            reclaimLog: reclaimLog
        )
        vm.start(root: root)
        engine.finishLast(summary: makeSummary(root: root, files: [file]))
        let done = await waitUntil { vm.phase == .finished }
        XCTAssertTrue(done)
        return vm
    }

    func testATrashMarksTheResultsStaleAndSaysWhenSpaceComesBack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let item = root.appendingPathComponent("installer.dmg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: item)
        defer { try? FileManager.default.removeItem(at: root) }

        let trasher = FakeTrasher()
        let vm = await finishedViewModel(
            root: root,
            file: makeNode(item),
            controller: ReclaimController(trasher: trasher)
        )

        let notice = await vm.reclaim([ReclaimCandidate(node: makeNode(item))])

        XCTAssertEqual(trasher.trashed, [item])
        XCTAssertTrue(vm.resultsAreStale)
        XCTAssertEqual(notice.tone, .success)
        XCTAssertTrue(notice.message.contains("empty the Trash"), notice.message)
        XCTAssertFalse(notice.message.lowercased().contains("reclaim"), notice.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path), "the fake must not delete")
    }

    func testRefusedItemIsNotHandedToTheTrashAndSaysWhy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let trasher = FakeTrasher()
        let vm = await finishedViewModel(
            root: root,
            file: makeNode(root.appendingPathComponent("a.bin")),
            controller: ReclaimController(trasher: trasher)
        )

        let notice = await vm.reclaim([ReclaimCandidate(node: makeNode(root, isDirectory: true))])

        XCTAssertTrue(trasher.trashed.isEmpty)
        XCTAssertFalse(vm.resultsAreStale)
        XCTAssertEqual(notice.tone, .failure)
        XCTAssertTrue(notice.message.contains("folder being scanned"), notice.message)
    }

    func testARunningScanRefusesATrash() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let item = root.appendingPathComponent("a.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: item)
        defer { try? FileManager.default.removeItem(at: root) }

        let trasher = FakeTrasher()
        let vm = ScanViewModel(engine: RecordingEngine(), reclaimController: ReclaimController(trasher: trasher))
        vm.start(root: root)

        let notice = await vm.reclaim([ReclaimCandidate(node: makeNode(item))])

        XCTAssertTrue(trasher.trashed.isEmpty)
        XCTAssertEqual(notice.tone, .failure)
        XCTAssertTrue(notice.message.contains("A scan is running"), notice.message)
    }

    func testAFailedTrashKeepsTheResultsAsTheyWereAndReportsTheReason() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let item = root.appendingPathComponent("locked.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: item)
        defer { try? FileManager.default.removeItem(at: root) }

        let trasher = FakeTrasher()
        trasher.fail(with: NSError(
            domain: "ReclaimQATests",
            code: 2,
            userInfo: [NSLocalizedFailureReasonErrorKey: "The item is in use"]
        ))
        let vm = await finishedViewModel(
            root: root,
            file: makeNode(item),
            controller: ReclaimController(trasher: trasher)
        )

        let notice = await vm.reclaim([ReclaimCandidate(node: makeNode(item))])

        XCTAssertFalse(vm.resultsAreStale)
        XCTAssertEqual(notice.tone, .failure)
        XCTAssertTrue(notice.message.contains("The item is in use"), notice.message)
    }

    // MARK: - The move log and Put Back

    func testAMoveIsRecordedWithWhereTheSystemPutIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let item = root.appendingPathComponent("installer.dmg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: item)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = ReclaimLog(store: ReclaimLogStore(url: root.appendingPathComponent("log.json")))
        let vm = await finishedViewModel(
            root: root,
            file: makeNode(item),
            controller: ReclaimController(trasher: FakeTrasher()),
            reclaimLog: log
        )

        _ = await vm.reclaim([ReclaimCandidate(node: makeNode(item))])

        let move = try XCTUnwrap(log.moves.first)
        XCTAssertEqual(move.items.count, 1)
        XCTAssertEqual(move.items.first?.name, "installer.dmg")
        XCTAssertEqual(move.items.first?.originalPath, item.standardizedFileURL.path)
        XCTAssertEqual(move.items.first?.trashedPath, "/Trash/installer.dmg")
        XCTAssertEqual(move.items.first?.isPending, true)
        XCTAssertEqual(move.rootPath, root.standardizedFileURL.path)
    }

    func testPutBackReturnsTheFileAndMarksTheMove() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let item = root.appendingPathComponent("photo.jpg")
        let trashed = trash.appendingPathComponent("photo.jpg")
        try Data("x".utf8).write(to: trashed)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = ReclaimLog(store: ReclaimLogStore(url: root.appendingPathComponent("log.json")))
        let move = ReclaimMove(
            date: Date(),
            rootPath: root.path,
            items: [
                ReclaimMove.Item(
                    name: "photo.jpg",
                    originalPath: item.path,
                    trashedPath: trashed.path,
                    isDirectory: false,
                    logicalSize: 1,
                    allocatedSize: 1
                ),
            ]
        )
        await log.record(move)

        let vm = await finishedViewModel(
            root: root,
            file: makeNode(item),
            controller: ReclaimController(trasher: FakeTrasher()),
            reclaimLog: log
        )
        let report = await vm.restore(move)

        XCTAssertEqual(report.restoredItemIDs, [move.items[0].id])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(log.moves.first?.items.first?.isRestored, true)
    }

    func testPutBackRefusesWhenTheOldPlaceIsTaken() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let item = root.appendingPathComponent("photo.jpg")
        let trashed = trash.appendingPathComponent("photo.jpg")
        try Data("new".utf8).write(to: item)
        try Data("old".utf8).write(to: trashed)
        defer { try? FileManager.default.removeItem(at: root) }

        let move = ReclaimMove(
            date: Date(),
            rootPath: root.path,
            items: [
                ReclaimMove.Item(
                    name: "photo.jpg",
                    originalPath: item.path,
                    trashedPath: trashed.path,
                    isDirectory: false,
                    logicalSize: 1,
                    allocatedSize: 1
                ),
            ]
        )
        let vm = await finishedViewModel(
            root: root,
            file: makeNode(item),
            controller: ReclaimController(trasher: FakeTrasher())
        )
        let report = await vm.restore(move)

        XCTAssertTrue(report.restoredItemIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("Something else"), report.failures[0])
        XCTAssertEqual(try String(contentsOf: item, encoding: .utf8), "new", "the item there is untouched")
    }

    func testPutBackRefusesWhenTheTrashCopyIsGone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReclaimRoot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let item = root.appendingPathComponent("photo.jpg")
        let move = ReclaimMove(
            date: Date(),
            rootPath: root.path,
            items: [
                ReclaimMove.Item(
                    name: "photo.jpg",
                    originalPath: item.path,
                    trashedPath: root.appendingPathComponent("Trash/photo.jpg").path,
                    isDirectory: false,
                    logicalSize: 1,
                    allocatedSize: 1
                ),
            ]
        )
        let vm = await finishedViewModel(
            root: root,
            file: makeNode(item),
            controller: ReclaimController(trasher: FakeTrasher())
        )
        let report = await vm.restore(move)

        XCTAssertTrue(report.restoredItemIDs.isEmpty)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("no longer in the Trash"), report.failures[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
    }
}
