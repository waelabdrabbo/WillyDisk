import Foundation
import os

/// In-flight scan bookkeeping guarded by an unfair lock.
private struct CancelState {
    var task: Task<Void, Never>?
}

/// Default `ScanEngine` implementation.
///
/// Concurrency model: the single mutable piece of state (the in-flight scan
/// task) is guarded by `OSAllocatedUnfairLock`. All filesystem work runs inside
/// a `Task.detached` — never on the main actor. Cancelling that task propagates
/// to the traversal's workers, which observe it and surface `.cancelled`.
public final class FileScanEngine: ScanEngine, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<CancelState>(initialState: CancelState())
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
        let state = self.state
        let access = self.access
        let concurrency = self.concurrency
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await FileScanner.run(
                    request: request,
                    access: access,
                    concurrency: concurrency
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
