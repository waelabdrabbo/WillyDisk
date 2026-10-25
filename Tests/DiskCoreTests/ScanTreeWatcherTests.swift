import XCTest
@testable import DiskCore

/// Exercises the real FSEvents stream against a temporary tree.
///
/// The event filter itself is covered deterministically in
/// `ScanWatchScopeTests`; these tests exist to prove the stream is installed,
/// delivers a batch, and stops delivering once it is stopped.
final class ScanTreeWatcherTests: XCTestCase {

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T

        init(_ value: T) { self.value = value }

        var current: T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func mutate(_ body: (inout T) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&value)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskWatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForChange(_ changes: Box<[ScanTreeChange]>, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while changes.current.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !changes.current.isEmpty
    }

    func testReportsAChangeInsideTheWatchedRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = ScanTreeWatcher(latency: 0.2)
        let changes = Box<[ScanTreeChange]>([])
        try watcher.start(root: root, excludedPaths: [], stayOnVolume: false) { change in
            changes.mutate { $0.append(change) }
        }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        try Data("hello".utf8).write(to: root.appendingPathComponent("created.txt"))

        XCTAssertTrue(waitForChange(changes), "FSEvents should report a file created in the root")
        let change = try XCTUnwrap(changes.current.first)
        XCTAssertFalse(change.rootMissing)
        let canonical = ScanWatchScope.canonicalPath(root)
        XCTAssertTrue(
            change.folders.contains { $0.path == canonical || $0.path.hasPrefix(canonical + "/") },
            "the reported folder should be in the watched tree, got \(change.folders.map(\.path))"
        )
    }

    func testAFileEventNamesTheFolderThatHoldsIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let watcher = ScanTreeWatcher(latency: 0.2)
        let changes = Box<[ScanTreeChange]>([])
        try watcher.start(root: root, excludedPaths: [], stayOnVolume: false) { change in
            changes.mutate { $0.append(change) }
        }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        try Data("hello".utf8).write(to: nested.appendingPathComponent("inside.txt"))

        XCTAssertTrue(waitForChange(changes), "FSEvents should report a file written in a subfolder")
        Thread.sleep(forTimeInterval: 0.5)
        let reported = changes.current.flatMap { $0.folders.map(\.path) }
        XCTAssertTrue(
            reported.contains(ScanWatchScope.canonicalPath(nested)),
            "the file's own event should name the folder that holds it, got \(reported)"
        )
        XCTAssertFalse(
            reported.contains(ScanWatchScope.canonicalPath(nested.appendingPathComponent("inside.txt"))),
            "an item event is reported as its folder, never as the file"
        )
    }

    func testStoppingEndsDelivery() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = ScanTreeWatcher(latency: 0.2)
        let changes = Box<[ScanTreeChange]>([])
        try watcher.start(root: root, excludedPaths: [], stayOnVolume: false) { change in
            changes.mutate { $0.append(change) }
        }
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()

        try Data("after".utf8).write(to: root.appendingPathComponent("after-stop.txt"))
        Thread.sleep(forTimeInterval: 2)

        XCTAssertTrue(changes.current.isEmpty, "a stopped watcher must not deliver")
    }
}
