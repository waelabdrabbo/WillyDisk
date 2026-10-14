import Foundation
import XCTest
@testable import DiskCore

/// Shared helpers for the scanner tests.
///
/// Traversal runs on concurrent workers, so an event sink has to be safe to call
/// from more than one of them.

/// Collects `ScanEvent`s from any thread.
final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanEvent] = []

    func append(_ event: ScanEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [ScanEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var snapshots: [ScanSummary] {
        events.compactMap { if case .partial(let summary) = $0 { return summary }; return nil }
    }

    var finished: ScanSummary? {
        for event in events { if case .finished(let summary) = event { return summary } }
        return nil
    }

    var cancelled: ScanSummary? {
        for event in events { if case .cancelled(let partial) = event { return partial } }
        return nil
    }

    func count(of kind: (ScanEvent) -> Bool) -> Int {
        events.reduce(into: 0) { total, event in if kind(event) { total += 1 } }
    }
}

/// Runs the traversal to completion on the calling task and returns every event.
@discardableResult
func runScanner(
    _ request: ScanRequest,
    access: FileSystemAccess = .live,
    cadence: FileScanner.SnapshotCadence = .production,
    concurrency: Int = FileScanner.defaultConcurrency
) async -> EventCollector {
    let collector = EventCollector()
    await FileScanner.run(
        request: request,
        access: access,
        cadence: cadence,
        concurrency: concurrency
    ) { collector.append($0) }
    return collector
}

/// A canonical, order-independent description of a node's subtree, used to prove
/// that a parallel scan produces exactly the same tree as a serial one.
func treeSignature(_ node: ScanNode) -> String {
    let children = node.children
        .map { "\($0.name):\($0.logicalSize):\($0.fileCount):\($0.directoryCount)[\(treeSignature($0))]" }
        .sorted()
        .joined(separator: ",")
    return "\(node.name)|\(node.logicalSize)|\(node.allocatedSize)|\(node.fileCount)|\(node.directoryCount)|{\(children)}"
}
