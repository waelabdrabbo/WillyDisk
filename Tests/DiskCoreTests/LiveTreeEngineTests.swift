import XCTest
import Foundation
@testable import DiskCore

/// The engine builds the live tree while it walks: the summary and the tree come
/// out of the same pass, and the tree is only handed over when they agree.
final class LiveTreeEngineTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTreeEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ bytes: Int, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func settle(_ engine: FileScanEngine, _ request: ScanRequest) async -> ScanSummary? {
        var summary: ScanSummary?
        for await event in engine.scan(request, buildingLiveTree: true) {
            switch event {
            case .finished(let finished):
                summary = finished
            case .cancelled:
                XCTFail("the fixture scan was cancelled")
            case .started, .progress, .issue, .partial:
                break
            }
        }
        return summary
    }

    func testTheWalkBuildsTheTreeItHandsOver() async throws {
        try write(1_000, to: "a.bin")
        try write(2_000, to: "Folder/b.bin")
        try write(3_000, to: "Folder/deep/c.bin")
        try write(10, to: ".hidden.bin")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link").path,
            withDestinationPath: root.appendingPathComponent("a.bin").path
        )

        let engine = FileScanEngine()
        let measured = await settle(engine, ScanRequest(root: root))
        let summary = try XCTUnwrap(measured)
        let handed = await engine.takeLiveTree()
        let tree = try XCTUnwrap(handed, "the walk should hand its tree over")

        XCTAssertTrue(tree.matches(summary), "the engine only hands over a tree that agrees with the summary")
        XCTAssertEqual(tree.fileCount, summary.fileCount)
        XCTAssertEqual(tree.directoryCount, summary.directoryCount)
        XCTAssertEqual(tree.totalLogicalSize, summary.totalLogicalSize)
        XCTAssertEqual(tree.categorySizes(), summary.categoryBreakdown.filter { $0.value != 0 })

        // A walk that fills a tree does not also keep that tree in its summary.
        // The tree is the tree; the summary is the record.
        XCTAssertTrue(summary.rootChildren.isEmpty)
        XCTAssertTrue(
            summary.largestDirectories.allSatisfy { $0.children.isEmpty },
            "a summary from a tree-building walk carries ranked entries, not subtrees"
        )
        XCTAssertNil(
            LiveTree(scanning: summary),
            "the compact summary cannot be converted back into a tree"
        )

        let rootNode = try XCTUnwrap(tree.scanNode(for: LiveTree.rootID, depth: 5))
        XCTAssertEqual(
            rootNode.children.map(\.name).sorted(),
            [".hidden.bin", "Folder", "a.bin", "link"].sorted()
        )
    }

    func testAPlainScanStillCarriesTheTreeInItsSummary() async throws {
        try write(1_000, to: "a.bin")
        try write(2_000, to: "Folder/b.bin")

        let engine = FileScanEngine()
        var summary: ScanSummary?
        for await event in engine.scan(ScanRequest(root: root)) {
            if case .finished(let finished) = event { summary = finished }
        }
        let measured = try XCTUnwrap(summary)
        let rootNode = try XCTUnwrap(measured.largestDirectories.first {
            $0.url.standardizedFileURL.path == root.standardizedFileURL.path
        })
        XCTAssertEqual(rootNode.children.map(\.name).sorted(), ["Folder", "a.bin"])
        XCTAssertNotNil(LiveTree(scanning: measured))
    }

    func testAPlainScanLeavesNoTree() async throws {
        try write(100, to: "a.bin")
        let engine = FileScanEngine()
        var finished = false
        for await event in engine.scan(ScanRequest(root: root)) {
            if case .finished = event { finished = true }
        }
        XCTAssertTrue(finished)
        let tree = await engine.takeLiveTree()
        XCTAssertNil(tree, "a caller that did not ask for a tree pays nothing for one")
    }

    func testTheTreeIsConsumedOnce() async throws {
        try write(100, to: "a.bin")
        let engine = FileScanEngine()
        _ = await settle(engine, ScanRequest(root: root))
        _ = await engine.takeLiveTree()
        let second = await engine.takeLiveTree()
        XCTAssertNil(second)
    }

    func testAFileRootHasNoTree() async throws {
        try write(100, to: "solo.bin")
        let engine = FileScanEngine()
        let fileRoot = root.appendingPathComponent("solo.bin")
        _ = await settle(engine, ScanRequest(root: fileRoot))
        let tree = await engine.takeLiveTree()
        XCTAssertNil(tree, "a file is a measurement, not a tree")
    }

    func testTheTreeKeepsTheScansRules() async throws {
        try write(100, to: "visible.bin")
        try write(50, to: ".hidden.bin")
        let skipped = root.appendingPathComponent("Skip", isDirectory: true)
        try write(70, to: "Skip/inside.bin")

        let request = ScanRequest(
            root: root,
            followSymlinks: false,
            stayOnVolume: true,
            includeHidden: false,
            excludedPaths: [skipped]
        )
        let engine = FileScanEngine()
        let measured = await settle(engine, request)
        let summary = try XCTUnwrap(measured)
        let handed = await engine.takeLiveTree()
        let tree = try XCTUnwrap(handed)

        XCTAssertNil(tree.id(atPath: root.appendingPathComponent(".hidden.bin").path))
        XCTAssertNil(tree.id(atPath: skipped.path))
        XCTAssertEqual(tree.totalLogicalSize, 100)
        XCTAssertTrue(tree.matches(summary))
    }

    func testTheInProgressTreeIsReadableWhileAFolderIsStillBeingWalked() async throws {
        // A virtual root with one file and one folder. The folder's listing waits
        // on the gate, so the test can look at the tree while the walk is inside
        // that folder and before its contents are known.
        let virtualRoot = URL(fileURLWithPath: "/willydisk-in-progress-\(UUID().uuidString)", isDirectory: true)
        let gate = DispatchSemaphore(value: 0)
        let access = gatedAccess(root: virtualRoot, gate: gate)
        let engine = FileScanEngine(access: access, concurrency: 1)
        let stream = engine.scan(ScanRequest(root: virtualRoot), buildingLiveTree: true)

        var found: LiveTree?
        for _ in 0..<400 {
            if let tree = await engine.liveTreeInProgress(),
               tree.children(of: LiveTree.rootID).count == 2 {
                found = tree
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let tree = try XCTUnwrap(found, "the in-progress tree should be readable while the walk runs")

        let rootNames = tree.children(of: LiveTree.rootID).map(\.name).sorted()
        XCTAssertEqual(rootNames, ["Folder", "a.bin"], "the listing is published as one group")
        let folderID = try XCTUnwrap(
            tree.id(atPath: virtualRoot.appendingPathComponent("Folder").path)
        )
        XCTAssertTrue(
            tree.children(of: folderID).isEmpty,
            "the folder is listed before its contents have been read"
        )

        gate.signal()
        await engine.cancel()
        for await _ in stream {}
    }

    // MARK: - A gated virtual filesystem

    /// A reader whose folder listing waits until the test has looked at the tree.
    private final class GatedDirectoryReader: DirectoryReading, @unchecked Sendable {
        let rootPath: String
        let gate: DispatchSemaphore
        let rootEntries: [DirectoryEntry]
        let folderEntries: [DirectoryEntry]

        init(
            rootPath: String,
            gate: DispatchSemaphore,
            rootEntries: [DirectoryEntry],
            folderEntries: [DirectoryEntry]
        ) {
            self.rootPath = rootPath
            self.gate = gate
            self.rootEntries = rootEntries
            self.folderEntries = folderEntries
        }

        func read(path: String) throws -> [DirectoryEntry] {
            if path == rootPath { return rootEntries }
            if path == rootPath + "/Folder" {
                gate.wait()
                return folderEntries
            }
            return []
        }
    }

    private func gatedAccess(root: URL, gate: DispatchSemaphore) -> FileSystemAccess {
        let rootPath = root.path
        let folderPath = rootPath + "/Folder"
        let filePath = rootPath + "/a.bin"
        let innerPath = folderPath + "/b.bin"
        let rootStat = FileStat(error: 0, mode: 0o040755, dev: 9, ino: 1)
        let folderStat = FileStat(error: 0, mode: 0o040755, dev: 9, ino: 2)
        let fileStat = FileStat(error: 0, mode: 0o100644, size: 10, blocks: 1, dev: 9, ino: 3)
        let innerStat = FileStat(error: 0, mode: 0o100644, size: 20, blocks: 1, dev: 9, ino: 4)
        let rootEntries = [
            DirectoryEntry(name: "Folder", stat: folderStat),
            DirectoryEntry(name: "a.bin", stat: fileStat),
        ]
        let folderEntries = [DirectoryEntry(name: "b.bin", stat: innerStat)]
        let statFor: @Sendable (String) -> FileStat = { path in
            switch path {
            case rootPath: return rootStat
            case folderPath: return folderStat
            case filePath: return fileStat
            case innerPath: return innerStat
            default: return FileStat(error: 2)
            }
        }
        return FileSystemAccess(
            lstat: statFor,
            statFollowing: statFor,
            makeDirectoryReader: {
                GatedDirectoryReader(
                    rootPath: rootPath,
                    gate: gate,
                    rootEntries: rootEntries,
                    folderEntries: folderEntries
                )
            },
            resolvedPath: { $0 }
        )
    }
}
