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

        // The tree the walk filled and the one a conversion would build describe
        // the same entries.
        let converted = try XCTUnwrap(LiveTree(scanning: summary))
        XCTAssertEqual(tree.nodeCount, converted.nodeCount)
        assertSameTree(
            tree.scanNode(for: LiveTree.rootID, depth: 5),
            converted.scanNode(for: LiveTree.rootID, depth: 5)
        )
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

    // MARK: - Comparison

    private func assertSameTree(
        _ live: ScanNode?,
        _ converted: ScanNode?,
        path: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let live, let converted else {
            XCTAssertNil(live, "only one tree holds \(path)", file: file, line: line)
            XCTAssertNil(converted, "only one tree holds \(path)", file: file, line: line)
            return
        }
        let name = path.isEmpty ? live.name : path + "/" + live.name
        XCTAssertEqual(live.isDirectory, converted.isDirectory, name, file: file, line: line)
        XCTAssertEqual(live.isSymlink, converted.isSymlink, name, file: file, line: line)
        XCTAssertEqual(live.category, converted.category, name, file: file, line: line)
        XCTAssertEqual(live.logicalSize, converted.logicalSize, name, file: file, line: line)
        XCTAssertEqual(live.allocatedSize, converted.allocatedSize, name, file: file, line: line)
        XCTAssertEqual(live.fileCount, converted.fileCount, name, file: file, line: line)
        XCTAssertEqual(live.directoryCount, converted.directoryCount, name, file: file, line: line)
        let left = Dictionary(uniqueKeysWithValues: live.children.map { ($0.name, $0) })
        let right = Dictionary(uniqueKeysWithValues: converted.children.map { ($0.name, $0) })
        XCTAssertEqual(Set(left.keys), Set(right.keys), "children of \(name)", file: file, line: line)
        for child in Set(left.keys).intersection(right.keys) {
            assertSameTree(left[child], right[child], path: name, file: file, line: line)
        }
    }
}
