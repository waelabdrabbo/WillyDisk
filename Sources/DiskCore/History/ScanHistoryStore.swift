import Foundation

/// Persists one JSON file per finished scan, so history survives a relaunch
/// without turning the frozen `ScanSummary` into a file format.
///
/// The store is deliberately dull: a directory of records, one file each, read
/// back by schema version. A file this release cannot read — truncated by a
/// crash, hand-edited, or written by a later schema — is skipped rather than
/// repaired, and it is never deleted by housekeeping, because a newer release
/// may still know what it says. Losing one record degrades the history list; it
/// never fails the app.
///
/// Every method is synchronous and touches the filesystem, so callers run it
/// off the main actor. The store itself carries no state beyond its directory,
/// which keeps it `Sendable` and safe to hand to a detached task.
public struct ScanHistoryStore: Sendable {

    /// What one load found.
    public struct Snapshot: Sendable, Equatable {
        /// Newest first.
        public let records: [ScanRecord]
        /// Files present but not readable by this release. Surfaced so the UI can
        /// say the list is incomplete instead of pretending nothing is missing.
        public let skippedCount: Int

        public init(records: [ScanRecord], skippedCount: Int) {
            self.records = records
            self.skippedCount = skippedCount
        }

        public static let empty = Snapshot(records: [], skippedCount: 0)

        public func records(forRoot path: String) -> [ScanRecord] {
            records.filter { $0.rootPath == path }
        }
    }

    /// Records kept for one scanned location. Enough to compare this week with
    /// last, bounded so an often-scanned disk cannot grow the store without end.
    public static let maxRecordsPerRoot = 20

    /// Records kept across every location.
    public static let maxRecordsTotal = 100

    /// `~/Library/Application Support/WillyDisk/History`. Records carry paths,
    /// never file contents, and stay on this Mac.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillyDisk/History", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL = ScanHistoryStore.defaultDirectory) {
        self.directory = directory
    }

    // MARK: - Reading

    /// Loads every record this release understands, newest first.
    ///
    /// A missing directory is an empty history, not an error: the store is
    /// created on the first save. An unreadable file is counted and skipped.
    public func load() -> Snapshot {
        ScanHistoryStore.snapshot(readStored())
    }

    private func readStored() -> ([Stored], Int) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return ([], 0)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var stored: [Stored] = []
        var skipped = 0
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(ScanRecord.self, from: data),
                  record.schemaVersion == ScanRecord.currentSchemaVersion
            else {
                skipped += 1
                continue
            }
            stored.append(Stored(url: url, record: record))
        }
        return (stored, skipped)
    }

    // MARK: - Writing

    /// Writes a record and prunes the store back to its bounds.
    ///
    /// The write is atomic, so an interrupted save cannot leave a half record
    /// behind. Pruning drops the oldest records first by keeping the newest
    /// `maxRecordsPerRoot` of each location and the newest `maxRecordsTotal`
    /// overall; files this release could not read are left untouched.
    @discardableResult
    public func save(_ record: ScanRecord) throws -> Snapshot {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: fileURL(for: record), options: .atomic)

        prune()
        return load()
    }

    /// Removes every record, including ones this release cannot read: clearing
    /// history is an explicit request about this directory, not housekeeping.
    ///
    /// A removal that fails is reported rather than counted as cleared, so the
    /// screen never claims a history is gone while records are still there.
    public func clear() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        var failure: Error?
        for name in names where name.hasSuffix(".json") {
            do {
                try manager.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }

    private func fileURL(for record: ScanRecord) -> URL {
        directory.appendingPathComponent("record-\(record.id.uuidString.lowercased()).json")
    }

    /// Drops the oldest records past the per-location and total bounds.
    private func prune() {
        let (stored, _) = readStored()
        guard !stored.isEmpty else { return }

        var kept: [Stored] = []
        var perRoot: [String: Int] = [:]
        for item in stored.sorted(by: { ScanHistoryStore.isNewer($0.record, $1.record) }) {
            let count = perRoot[item.record.rootPath, default: 0]
            guard count < ScanHistoryStore.maxRecordsPerRoot,
                  kept.count < ScanHistoryStore.maxRecordsTotal
            else { continue }
            perRoot[item.record.rootPath] = count + 1
            kept.append(item)
        }

        let keptURLs = Set(kept.map(\.url.standardizedFileURL))
        for item in stored where !keptURLs.contains(item.url.standardizedFileURL) {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    // MARK: - Ordering

    /// Ordering shared by the store and the comparison: newest finish first, with
    /// the identifier as a stable tie-break for two scans that settled within the
    /// same second.
    static func isNewer(_ lhs: ScanRecord, _ rhs: ScanRecord) -> Bool {
        if lhs.finishedAt != rhs.finishedAt { return lhs.finishedAt > rhs.finishedAt }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func snapshot(_ stored: ([Stored], Int)) -> Snapshot {
        Snapshot(
            records: stored.0.map(\.record).sorted(by: isNewer),
            skippedCount: stored.1
        )
    }

    private struct Stored {
        let url: URL
        let record: ScanRecord
    }
}
