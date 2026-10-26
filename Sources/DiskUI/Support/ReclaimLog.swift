import Foundation
import Observation
import DiskCore

/// The app's view of the persisted move log.
///
/// The log answers one question — can this move still be undone — so it is
/// loaded once at launch and updated after a move or a Put Back. Every
/// filesystem touch runs in a detached task; nothing here reads the Trash.
@MainActor
@Observable
public final class ReclaimLog {

    /// Newest move first.
    public private(set) var moves: [ReclaimMove] = []
    /// Whether a read is in flight, so a screen can tell "no moves yet" from
    /// "not read yet".
    public private(set) var isLoading = false
    public let store: ReclaimLogStore

    /// Bumped whenever `moves` is replaced, so a read that started earlier cannot
    /// overwrite a move recorded while it ran.
    private var version = 0

    public init(store: ReclaimLogStore = ReclaimLogStore()) {
        self.store = store
    }

    public func reload() async {
        isLoading = true
        let store = store
        let start = version
        let loaded = await Task.detached(priority: .utility) { store.load() }.value
        guard start == version else {
            isLoading = false
            return
        }
        apply(loaded)
        isLoading = false
    }

    public func record(_ move: ReclaimMove) async {
        let store = store
        do {
            let next = try await Task.detached(priority: .utility) { try store.append(move) }.value
            apply(next)
        } catch {
            // The list stays on screen; the files on disk are untouched.
        }
    }

    public func markRestored(moveID: UUID, itemIDs: Set<UUID>) async {
        guard !itemIDs.isEmpty else { return }
        let store = store
        do {
            let next = try await Task.detached(priority: .utility) {
                try store.markRestored(moveID: moveID, itemIDs: itemIDs, at: Date())
            }.value
            apply(next)
        } catch {
            // The items are back on disk either way. The list keeps offering
            // Put Back until a write succeeds, and a second attempt reports that
            // the Trash copy is gone.
        }
    }

    /// Forgets every move; the items themselves are untouched.
    public func clear() async {
        let store = store
        do {
            let next = try await Task.detached(priority: .utility) { try store.clear() }.value
            apply(next)
        } catch {
            // A log that cannot be written leaves the move out of the list: it
            // cannot be put back after a relaunch, so it is not offered.
        }
    }

    private func apply(_ next: [ReclaimMove]) {
        moves = next
        version &+= 1
    }
}
