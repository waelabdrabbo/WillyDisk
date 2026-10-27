import Foundation
import os

/// In-flight scan bookkeeping guarded by an unfair lock.
private struct CancelState {
    var task: Task<Void, Never>?
}

/// An engine that can hand back the tree its walk built.
///
/// `ScanEngine` is the frozen contract: it reports measurements as summaries. An
/// engine that also fills a `LiveTree` as it walks can let a screen read that
/// tree while it fills, and hand it over when the walk is done, so a screen
/// never converts a finished summary into a tree of its own.
public protocol LiveTreeScanning: Sendable {
    /// The same events as `scan(_:)`. With `buildingLiveTree`, the walk fills a
    /// tree that `takeLiveTree()` returns after the terminal event; without it,
    /// the walk behaves exactly as `scan(_:)`.
    func scan(_ request: ScanRequest, buildingLiveTree: Bool) -> AsyncStream<ScanEvent>

    /// The tree of the last scan that asked for one, consumed once. `nil` when
    /// that scan built none (a file root, a cancelled run) or the tree did not
    /// agree with the summary the same walk produced.
    func takeLiveTree() async -> LiveTree?

    /// The tree the walk is filling right now, without consuming it.
    ///
    /// The tree is lock-protected, so a screen can read it while the walk adds
    /// to it; a read reports entries that have actually been inserted. It stays
    /// available after the walk ends until the next scan starts, so a cancelled
    /// run can still be read. A producer that does not build a tree returns
    /// `nil`.
    func liveTreeInProgress() async -> LiveTree?

    /// Releases the tree the engine is holding.
    ///
    /// A consumer that has installed the tree itself can drop the engine's
    /// reference when the run ends, so a stopped or abandoned scan does not keep
    /// the arena alive until the next scan starts. Safe to call at any time.
    func clearLiveTree()
}

public extension LiveTreeScanning {
    /// No tree to expose for a producer that only reports summaries.
    func liveTreeInProgress() async -> LiveTree? { nil }

    /// No tree to release for a producer that only reports summaries.
    func clearLiveTree() {}
}

/// The tree a scan is filling and the one it has handed over.
private struct TreeSlots: Sendable {
    /// Identifies the scan that owns the slots. A tree callback from an older
    /// scan is ignored rather than latching its tree into a later run.
    var generation = 0
    var inProgress: LiveTree?
    var handed: LiveTree?
}

/// Default `ScanEngine` implementation.
///
/// Concurrency model: the single mutable piece of state (the in-flight scan
/// task) is guarded by `OSAllocatedUnfairLock`. All filesystem work runs inside
/// a `Task.detached` — never on the main actor. Cancelling that task propagates
/// to the traversal's workers, which observe it and surface `.cancelled`.
public final class FileScanEngine: ScanEngine, LiveTreeScanning, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<CancelState>(initialState: CancelState())
    /// The tree the current walk is filling, and the one the last opted-in walk
    /// built, waiting for its consumer.
    private let treeSlots = OSAllocatedUnfairLock<TreeSlots>(initialState: TreeSlots())
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
        treeSlots.withLock { slots in
            let tree = slots.handed
            slots.generation &+= 1
            slots.handed = nil
            slots.inProgress = nil
            return tree
        }
    }

    public func liveTreeInProgress() async -> LiveTree? {
        treeSlots.withLock { $0.inProgress }
    }

    public func clearLiveTree() {
        treeSlots.withLock { slots in
            slots.generation &+= 1
            slots.inProgress = nil
            slots.handed = nil
        }
    }

    private func start(_ request: ScanRequest, buildingLiveTree: Bool) -> AsyncStream<ScanEvent> {
        let state = self.state
        let slots = self.treeSlots
        let access = self.access
        let concurrency = self.concurrency
        // A tree a previous scan left behind belonged to that scan; the next one
        // starts from nothing rather than exposing or handing the wrong tree. The
        // generation keeps a late callback from the previous walk out of these
        // slots.
        let generation: Int = slots.withLock { (held: inout TreeSlots) in
            held.generation &+= 1
            held.inProgress = nil
            held.handed = nil
            return held.generation
        }
        let onTreeCreated: (@Sendable (LiveTree) -> Void)? = buildingLiveTree
            ? { @Sendable (tree: LiveTree) in
                slots.withLock { (held: inout TreeSlots) in
                    guard held.generation == generation else { return }
                    held.inProgress = tree
                }
            }
            : nil
        let onTreeReady: (@Sendable (LiveTree) -> Void)? = buildingLiveTree
            ? { @Sendable (tree: LiveTree) in
                slots.withLock { (held: inout TreeSlots) in
                    guard held.generation == generation else { return }
                    held.handed = tree
                }
            }
            : nil
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await FileScanner.run(
                    request: request,
                    access: access,
                    concurrency: concurrency,
                    liveTreeCreated: onTreeCreated,
                    liveTreeReady: onTreeReady
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
