import Foundation
import Observation
import DiskCore

/// Runs one content check and keeps its progress for the sheet.
///
/// The task is cancellable and generation-guarded: a late progress update or a
/// result from a check the person cancelled cannot replace the current state.
@MainActor
@Observable
final class DuplicateCheck {
    enum State: Equatable {
        case idle
        case checking(DuplicateHashProgress)
        case checked(DuplicateReport)
    }

    private(set) var state: State
    private var work: Task<DuplicateReport?, Never>?
    private var watcher: Task<Void, Never>?
    private var generation = 0

    init(preview: DuplicateReport? = nil) {
        state = preview.map(State.checked) ?? .idle
    }

    func start(_ groups: [DuplicateSizeGroup]) {
        guard !groups.isEmpty else { return }
        cancel()

        generation += 1
        let generation = generation
        let candidates = groups.flatMap(\.candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + max(0, $1.logicalSize) }
        state = .checking(DuplicateHashProgress(
            processedBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 0,
            totalFiles: candidates.count
        ))

        // The detached task must not keep the sheet alive, so the only thing it
        // captures from here is this weak progress sink.
        let onProgress: @Sendable (DuplicateHashProgress) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == generation,
                      case .checking = self.state else { return }
                self.state = .checking(progress)
            }
        }
        // `Task.isCancelled` is not visible to the reading threads, so the
        // check polls this flag and the task's cancellation sets it.
        let cancellation = HashCancellation()
        let work = Task.detached(priority: .userInitiated) {
            await withTaskCancellationHandler {
                DuplicateHasher.check(
                    groups: groups,
                    isCancelled: { cancellation.isSet },
                    progress: onProgress
                )
            } onCancel: {
                cancellation.set()
            }
        }
        self.work = work
        watcher = Task { [weak self] in
            let report = await work.value
            guard let self, self.generation == generation else { return }
            // Retire this generation before publishing the result, so a late
            // progress update cannot put the view back into `.checking`.
            self.generation += 1
            self.work = nil
            self.watcher = nil
            self.state = report.map(State.checked) ?? .idle
        }
    }

    func cancel() {
        generation += 1
        work?.cancel()
        work = nil
        watcher?.cancel()
        watcher = nil
        state = .idle
    }
}

/// A one-way flag the content check's reading threads can poll.
private final class HashCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
