import Foundation
import os

/// In-flight scan bookkeeping guarded by an unfair lock.
private struct CancelState {
    var task: Task<Void, Never>?
}

/// An engine that can hand back the tree its walk built.
///
/// `ScanEngine` is the frozen contract: it reports measurements as summaries. An
/// engine that also fills a `LiveTree` as it walks can hand it over once the walk
/// is done, so a screen never converts a finished summary into a tree of its own.
public protocol LiveTreeScanning: Sendable {
    /// The same events as `scan(_:)`. With `buildingLiveTree`, the walk fills a
    /// tree that `takeLiveTree()` returns after the terminal event; without it,
    /// the walk behaves exactly as `scan(_:)`.
    func scan(_ request: ScanRequest, buildingLiveTree: Bool) -> AsyncStream<ScanEvent>

    /// The tree of the last scan that asked for one, consumed once. `nil` when
    /// that scan built none (a file root, a cancelled run) or the tree did not
    /// agree with the summary the same walk produced.
    func takeLiveTree() async -> LiveTree?
}

/// Default `ScanEngine` implementation.
///
/// Concurrency model: the single mutable piece of state (the in-flight scan
/// task) is guarded by `OSAllocatedUnfairLock`. All filesystem work runs inside
/// a `Task.detached` — never on the main actor. Cancelling that task propagates
/// to the traversal's workers, which observe it and surface `.cancelled`.
public final class FileScanEngine: ScanEngine, LiveTreeScanning, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<CancelState>(initialState: CancelState())
    /// The tree the last opted-in walk built, waiting for its consumer.
    private let liveTreeSlot = OSAllocatedUnfairLock<LiveTree?>(initialState: nil)
    private let access: FileSystemAccess
    private let concurrency: Int

    public init() {
        self.access = .live
        self.concurrency = FileScanner.defaultConcurrency
    }

    /// Drives the traversal with an explicit worker count. Used by tests and
    /// benchmarks.
    init(concurrency: Int) {
        self.access = .live
        self.concurrency = concurrency
    }

    /// Drives the traversal against an injected filesystem. Used by tests.
    init(access: FileSystemAccess, concurrency: Int = FileScanner.defaultConcurrency) {
        self.access = access
        self.concurrency = concurrency
    }

    public func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
        start(request, buildingLiveTree: false)
    }

    public func scan(_ request: ScanRequest, buildingLiveTree: Bool) -> AsyncStream<ScanEvent> {
        start(request, buildingLiveTree: buildingLiveTree)
    }

    public func takeLiveTree() async -> LiveTree? {
        liveTreeSlot.withLock { slot in
            let tree = slot
            slot = nil
            return tree
        }
    }

    private func start(_ request: ScanRequest, buildingLiveTree: Bool) -> AsyncStream<ScanEvent> {
        let state = self.state
        let slot = self.liveTreeSlot
        let access = self.access
        let concurrency = self.concurrency
        // A tree a previous scan left behind belonged to that scan; the next one
        // starts from nothing rather than handing the wrong tree over.
        slot.withLock { (held: inout LiveTree?) in held = nil }
        let onTree: (@Sendable (LiveTree) -> Void)? = buildingLiveTree
            ? { @Sendable (tree: LiveTree) in
                slot.withLock { (held: inout LiveTree?) in held = tree }
            }
            : nil
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await FileScanner.run(
                    request: request,
                    access: access,
                    concurrency: concurrency,
                    liveTree: onTree
                ) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            }
            state.withLock { $0.task = task }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func cancel() async {
        state.withLock { $0.task?.cancel() }
    }
}
