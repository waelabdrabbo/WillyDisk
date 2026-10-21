import Foundation
import Observation
import DiskCore

/// The app's view of the persisted scan history.
///
/// It owns no scanning and no arithmetic over a scan: a finished `ScanSummary`
/// becomes a `ScanRecord` here, and the store reads and writes the files. All
/// filesystem work runs in a detached task, so opening the history sheet or
/// finishing a scan never puts a disk read or a write on the main actor.
@MainActor
@Observable
public final class ScanHistory {

    /// The records the store holds, newest first, plus how many files it could
    /// not read.
    public private(set) var snapshot: ScanHistoryStore.Snapshot = .empty
    /// Whether a load is in flight, so the sheet can tell "no history yet" from
    /// "not read yet".
    public private(set) var isLoading = false
    /// Why the last write failed, if it did. A history that cannot be written is
    /// not a scan failure — the results on screen stay correct — so this is
    /// reported beside the list rather than raised as an alert.
    public private(set) var writeFailure: String?

    public let store: ScanHistoryStore

    /// Bumped whenever `snapshot` is replaced. A read captures it before the
    /// background load and applies its result only if nothing newer landed in the
    /// meantime — a record written while the sheet was opening must not be
    /// overwritten by a read that started before it.
    private var snapshotVersion = 0

    public init(store: ScanHistoryStore = ScanHistoryStore()) {
        self.store = store
    }

    /// Records kept for one scanned location, newest first.
    public func records(for root: URL) -> [ScanRecord] {
        snapshot.records(forRoot: root.standardizedFileURL.path)
    }

    /// Reads every record this release understands.
    public func reload() async {
        isLoading = true
        let store = store
        let version = snapshotVersion
        let loaded = await Task.detached(priority: .utility) { store.load() }.value
        guard version == snapshotVersion else {
            isLoading = false
            return
        }
        apply(loaded)
        isLoading = false
    }

    /// Captures a finished scan and writes it.
    ///
    /// Only `.finished` summaries reach this. A cancelled scan is a measurement
    /// of part of the root, and comparing it with a complete run would present
    /// the missing work as space that had disappeared.
    public func record(_ summary: ScanSummary, options: ScanOptions) async {
        let volume = await VolumeFactsProbe.facts(for: summary.root)
        let record = ScanRecord(
            summary: summary,
            options: RecordedOptions(
                followSymlinks: options.followSymlinks,
                stayOnVolume: options.stayOnVolume,
                includeHidden: options.includeHidden,
                excludedPaths: options.excludedPaths.map { $0.standardizedFileURL.path }
            ),
            volume: volume.map {
                RecordedVolume(
                    name: $0.name,
                    mountPath: $0.mountURL.path,
                    totalCapacity: $0.totalCapacity,
                    availableCapacity: $0.availableCapacity
                )
            }
        )

        let store = store
        do {
            let saved = try await Task.detached(priority: .utility) { try store.save(record) }.value
            apply(saved)
            writeFailure = nil
        } catch {
            writeFailure = error.localizedDescription
        }
    }

    private func apply(_ next: ScanHistoryStore.Snapshot) {
        snapshot = next
        snapshotVersion &+= 1
    }

    /// Removes every recorded run.
    public func clear() async {
        let store = store
        do {
            try await Task.detached(priority: .utility) { try store.clear() }.value
            apply(.empty)
            writeFailure = nil
        } catch {
            writeFailure = error.localizedDescription
        }
    }
}
