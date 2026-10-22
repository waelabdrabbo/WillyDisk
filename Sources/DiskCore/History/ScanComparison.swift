import Foundation

/// Two records of the same location, compared. This is a statement about what
/// two measurements say, not about what happened on disk between them: a file
/// can be replaced by an identical one, and a folder can shrink because it was
/// excluded from one run.
///
/// The totals and the category breakdown are complete — every scan measures all
/// of what it walked — so their differences are exact. The ranked lists are not:
/// each run stores up to its `entryCapacity` entries. When the earlier run found
/// more entries than its list could keep, a later entry at or below its cut-off
/// cannot be told from one that was simply ranked lower then, so it is left out
/// of the comparison rather than called new. An entry above the cut-off is new
/// beyond doubt: the earlier run would have recorded it had it existed.
public struct ScanComparison: Sendable, Equatable {

    /// How one recorded entry relates the later run to the earlier one.
    public enum Change: String, Sendable, Equatable, CaseIterable {
        /// Present in the later run and provably absent from the earlier one:
        /// above the cut-off of a truncated earlier list, or absent from a list
        /// that held every entry its run found.
        case new
        /// In both lists, larger in the later run.
        case grown
        /// In both lists, smaller in the later run.
        case shrunk
        /// In both lists, the same size.
        case unchanged

        public var label: String {
            switch self {
            case .new: "New"
            case .grown: "Grown"
            case .shrunk: "Shrunk"
            case .unchanged: "Unchanged"
            }
        }
    }

    /// One ranked entry in the later run, with the earlier run's answer when the
    /// entry was in its list too.
    public struct Entry: Identifiable, Sendable, Equatable {
        public let path: String
        public let name: String
        public let isDirectory: Bool
        /// `nil` when the entry was not in the earlier run's list. For a `new`
        /// entry that absence is proof it was not there; see `change`.
        public let earlierSize: Int64?
        public let laterSize: Int64
        public let change: Change

        /// The later size less the earlier one; for `new` entries, the whole of
        /// the later size, because that is what the entry now contributes.
        public var delta: Int64 { laterSize - (earlierSize ?? 0) }

        public var id: String { path }
    }

    /// One category's bytes in both runs. Unlike a ranked entry, this is exact.
    public struct CategoryChange: Identifiable, Sendable, Equatable {
        public let category: FileCategory
        public let earlier: Int64
        public let later: Int64
        public let change: Change

        public var delta: Int64 { later - earlier }
        public var id: String { category.rawValue }
    }

    public let earlier: ScanRecord
    public let later: ScanRecord

    /// Entries from the later run's ranked folders that can be compared: in
    /// both lists, or new beyond doubt. Largest change first.
    public let directories: [Entry]
    /// Entries from the later run's ranked files that can be compared: in both
    /// lists, or new beyond doubt. Largest change first.
    public let files: [Entry]
    /// Every category either run measured, largest change first.
    public let categories: [CategoryChange]

    /// Entries that were in the earlier run's ranked list and are not in the
    /// later one. Not listed as removals: a folder can drop out of a top list by
    /// shrinking below its cut-off, and the record cannot tell that from a move
    /// to the Trash.
    public let droppedDirectoryCount: Int
    public let droppedFileCount: Int

    /// Later entries left out of the comparison because they were absent from a
    /// truncated earlier list at or below its cut-off. The earlier run recorded
    /// only its largest entries, so one of that size could have existed there
    /// unrecorded; its absence is not evidence that it is new.
    public let uncomparedDirectoryCount: Int
    public let uncomparedFileCount: Int

    /// The smallest sizes the earlier run's lists held when the run found more
    /// entries than they could keep — the cut-off below which it recorded
    /// nothing. `nil` when the list held every entry the run found, in which
    /// case an entry missing from it really was absent.
    public let earlierDirectoryCutOff: Int64?
    public let earlierFileCutOff: Int64?

    // MARK: Derived

    public var totalLogicalDelta: Int64 { later.totalLogicalSize - earlier.totalLogicalSize }
    public var totalAllocatedDelta: Int64 { later.totalAllocatedSize - earlier.totalAllocatedSize }
    public var fileCountDelta: Int { later.fileCount - earlier.fileCount }
    public var directoryCountDelta: Int { later.directoryCount - earlier.directoryCount }

    public var rootsMatch: Bool { earlier.rootPath == later.rootPath }

    /// Whether the two runs measured the same thing. A difference in options —
    /// hidden items, other volumes, followed links, excluded paths — means the
    /// difference between the totals may be what each walk included rather than
    /// what changed on disk.
    public var optionsDiffer: Bool { earlier.options != later.options }

    /// The entries that moved, in the order a screen should show them.
    public var changedDirectories: [Entry] { directories.filter { $0.change != .unchanged } }
    public var changedFiles: [Entry] { files.filter { $0.change != .unchanged } }

    public var hasChanges: Bool {
        totalLogicalDelta != 0
            || fileCountDelta != 0
            || directoryCountDelta != 0
            || !changedDirectories.isEmpty
            || !changedFiles.isEmpty
    }

    // MARK: Building

    /// Compares two records of the same location in time order, whichever order
    /// they arrive in. "Grown" always means the later run is larger.
    public static func between(_ first: ScanRecord, _ second: ScanRecord) -> ScanComparison {
        let earlier: ScanRecord
        let later: ScanRecord
        if ScanHistoryStore.isNewer(first, second) {
            earlier = second
            later = first
        } else {
            earlier = first
            later = second
        }
        return ScanComparison(earlier: earlier, later: later)
    }

    private init(earlier: ScanRecord, later: ScanRecord) {
        self.earlier = earlier
        self.later = later

        let earlierDirectories = Dictionary(uniqueKeysWithValues: earlier.largestDirectories.map { ($0.path, $0) })
        let earlierFiles = Dictionary(uniqueKeysWithValues: earlier.largestFiles.map { ($0.path, $0) })
        let directoryCutOff = ScanComparison.cutOff(
            of: earlier.largestDirectories,
            capacity: earlier.entryCapacity,
            totalCount: earlier.directoryCount
        )
        let fileCutOff = ScanComparison.cutOff(
            of: earlier.largestFiles,
            capacity: earlier.entryCapacity,
            totalCount: earlier.fileCount
        )
        earlierDirectoryCutOff = directoryCutOff
        earlierFileCutOff = fileCutOff

        let comparedDirectories = ScanComparison.entries(
            later: later.largestDirectories,
            earlier: earlierDirectories,
            earlierCutOff: directoryCutOff
        )
        directories = comparedDirectories.entries
        uncomparedDirectoryCount = comparedDirectories.uncompared

        let comparedFiles = ScanComparison.entries(
            later: later.largestFiles,
            earlier: earlierFiles,
            earlierCutOff: fileCutOff
        )
        files = comparedFiles.entries
        uncomparedFileCount = comparedFiles.uncompared

        let laterPaths = Set(later.largestDirectories.map(\.path))
        let laterFilePaths = Set(later.largestFiles.map(\.path))
        droppedDirectoryCount = earlier.largestDirectories.filter { !laterPaths.contains($0.path) }.count
        droppedFileCount = earlier.largestFiles.filter { !laterFilePaths.contains($0.path) }.count

        categories = ScanComparison.categoryChanges(earlier: earlier, later: later)
    }

    /// The entries the comparison can speak about, and how many it had to leave
    /// out because the earlier list's cut-off cannot rule them in or out.
    private static func entries(
        later: [RecordedEntry],
        earlier: [String: RecordedEntry],
        earlierCutOff: Int64?
    ) -> (entries: [Entry], uncompared: Int) {
        var entries: [Entry] = []
        var uncompared = 0
        for entry in later {
            let previous = earlier[entry.path]?.logicalSize
            let change: Change
            if let previous {
                let delta = entry.logicalSize - previous
                if delta > 0 {
                    change = .grown
                } else if delta < 0 {
                    change = .shrunk
                } else {
                    change = .unchanged
                }
            } else if let earlierCutOff, entry.logicalSize <= earlierCutOff {
                // The earlier list was full and this entry would have ranked at
                // or below its smallest recorded size, so it could have been
                // there without being recorded. Absence proves nothing.
                uncompared += 1
                continue
            } else {
                change = .new
            }
            entries.append(Entry(
                path: entry.path,
                name: entry.name,
                isDirectory: entry.isDirectory,
                earlierSize: previous,
                laterSize: entry.logicalSize,
                change: change
            ))
        }
        entries.sort { lhs, rhs in
            if lhs.delta.magnitude != rhs.delta.magnitude { return lhs.delta.magnitude > rhs.delta.magnitude }
            if lhs.laterSize != rhs.laterSize { return lhs.laterSize > rhs.laterSize }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return (entries, uncompared)
    }

    /// The smallest size the list recorded when the run found more entries than
    /// it could keep, `nil` when it held every entry the scan found: in that
    /// case an entry missing from it really was absent.
    private static func cutOff(
        of entries: [RecordedEntry],
        capacity: Int,
        totalCount: Int
    ) -> Int64? {
        guard totalCount > capacity, entries.count >= capacity else { return nil }
        return entries.map(\.logicalSize).min()
    }

    private static func categoryChanges(earlier: ScanRecord, later: ScanRecord) -> [CategoryChange] {
        let earlierSizes = earlier.categoryBreakdown
        let laterSizes = later.categoryBreakdown
        return FileCategory.allCases.compactMap { category in
            let before = earlierSizes[category] ?? 0
            let after = laterSizes[category] ?? 0
            guard before != 0 || after != 0 else { return nil }
            let change: Change
            if before == 0 {
                change = .new
            } else if after > before {
                change = .grown
            } else if after < before {
                change = .shrunk
            } else {
                change = .unchanged
            }
            return CategoryChange(category: category, earlier: before, later: after, change: change)
        }
        .sorted { lhs, rhs in
            if lhs.delta.magnitude != rhs.delta.magnitude { return lhs.delta.magnitude > rhs.delta.magnitude }
            return lhs.category.rawValue < rhs.category.rawValue
        }
    }
}
