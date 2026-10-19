import XCTest
@testable import DiskCore
@testable import DiskUI

/// Verifies the guard in front of a trash action, the seam that performs it, and
/// what the screen says afterwards.
@MainActor
final class ReclaimQATests: XCTestCase {

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
        controller: ReclaimController
    ) async -> ScanViewModel {
        let engine = RecordingEngine()
        let vm = ScanViewModel(engine: engine, reclaimController: controller)
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
}
