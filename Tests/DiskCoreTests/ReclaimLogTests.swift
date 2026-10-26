import XCTest
import Foundation
@testable import DiskCore

/// The move log: what it keeps, what it forgets, and what it refuses to
/// overwrite.
final class ReclaimLogTests: XCTestCase {

    private var root: URL!
    private var store: ReclaimLogStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReclaimLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ReclaimLogStore(url: root.appendingPathComponent("ReclaimLog.json"))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        store = nil
        try super.tearDownWithError()
    }

    func testAppendAndLoadKeepTheNewestMoveFirst() throws {
        let first = move(named: "a.bin", at: Date(timeIntervalSince1970: 1_000))
        let second = move(named: "b.bin", at: Date(timeIntervalSince1970: 2_000))

        try store.append(first)
        try store.append(second)

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(loaded.first?.items.first?.originalPath, "/scan/b.bin")
        XCTAssertEqual(loaded.first?.items.first?.trashedPath, "/Trash/b.bin")
    }

    func testTheLogIsBounded() throws {
        for index in 0..<25 {
            try store.append(move(named: "\(index).bin", at: Date(timeIntervalSince1970: Double(index))))
        }

        let loaded = store.load()
        XCTAssertEqual(loaded.count, ReclaimLogStore.maxMoves)
        XCTAssertEqual(loaded.first?.items.first?.name, "24.bin")
        XCTAssertEqual(loaded.last?.items.first?.name, "5.bin")
    }

    func testMarkRestoredTouchesOnlyTheGivenItems() throws {
        let itemA = ReclaimMove.Item(
            name: "a.bin", originalPath: "/scan/a.bin", trashedPath: "/Trash/a.bin",
            isDirectory: false, logicalSize: 10, allocatedSize: 10
        )
        let itemB = ReclaimMove.Item(
            name: "b.bin", originalPath: "/scan/b.bin", trashedPath: "/Trash/b.bin",
            isDirectory: false, logicalSize: 20, allocatedSize: 20
        )
        let batch = ReclaimMove(date: Date(), rootPath: "/scan", items: [itemA, itemB])
        try store.append(batch)

        let restored = try store.markRestored(
            moveID: batch.id,
            itemIDs: [itemA.id],
            at: Date(timeIntervalSince1970: 5_000)
        )

        let items = try XCTUnwrap(restored.first?.items)
        XCTAssertTrue(items[0].isRestored)
        XCTAssertFalse(items[1].isRestored)
        XCTAssertEqual(store.load().first?.restoredItems, 1)
    }

    func testAnUnreadableFileIsSetAsideRatherThanOverwritten() throws {
        try Data("not a log".utf8).write(to: store.url)

        let log = store.load()
        XCTAssertTrue(log.isEmpty)

        try store.append(move(named: "a.bin", at: Date()))
        XCTAssertEqual(store.load().count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.url.appendingPathExtension("unreadable").path),
            "the bytes this release could not read are kept beside the log"
        )
    }

    func testAnUnknownSchemaIsIgnored() throws {
        let encoded = """
        {"schemaVersion": 99, "moves": []}
        """
        try Data(encoded.utf8).write(to: store.url)

        XCTAssertTrue(store.load().isEmpty)
    }

    // MARK: - Fixtures

    private func move(named name: String, at date: Date) -> ReclaimMove {
        ReclaimMove(
            date: date,
            rootPath: "/scan",
            items: [
                ReclaimMove.Item(
                    name: name,
                    originalPath: "/scan/\(name)",
                    trashedPath: "/Trash/\(name)",
                    isDirectory: false,
                    logicalSize: 100,
                    allocatedSize: 100
                ),
            ]
        )
    }
}
