import Foundation

/// One finished scan, reduced to the facts a history comparison needs.
///
/// `ScanSummary` is the engine's measurement of a moment, and it is deliberately
/// not `Codable`: persisting it would make its tree, its node identities, and
/// every future field part of a file format. A record is an explicit, versioned
/// DTO instead — counts, ranked lists, accounting, and the volume it measured —
/// so a stored scan can be read by a later release without that release
/// inheriting the frozen model as an on-disk schema.
///
/// There is one record per finished scan. A cancelled scan produces no record:
/// its totals are only part of the root, and a comparison against them would
/// read as real growth or shrinkage.
public struct ScanRecord: Codable, Sendable, Equatable, Identifiable {

    /// The format this release writes and reads. A record carrying any other
    /// value is left alone rather than guessed at: a newer app may describe
    /// fields this one cannot interpret, and rewriting it would destroy them.
    public static let currentSchemaVersion = 1

    /// How many entries each ranked list can hold in this release. A stored
    /// record carries the capacity it was written with, so a later release that
    /// keeps a different number still reads older runs correctly.
    public static var currentEntryCapacity: Int { FileScanner.largestCapacity }

    public let schemaVersion: Int
    public let id: UUID
    public let rootPath: String
    public let startedAt: Date
    public let finishedAt: Date

    public let totalLogicalSize: Int64
    public let totalAllocatedSize: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let inaccessibleCount: Int
    public let errorCount: Int
    public let permissionDeniedCount: Int
    public let surfacedIssueCount: Int

    /// Logical bytes by `FileCategory` raw value. A dictionary of raw values
    /// rather than of the enum, so the file stays a plain, readable JSON object
    /// whose keys are the document's own vocabulary.
    public let categorySizes: [String: Int64]

    public let largestFiles: [RecordedEntry]
    public let largestDirectories: [RecordedEntry]
    /// The engine's ranked-list capacity when this run was recorded. A list whose
    /// count reaches it was truncated; a shorter one held every entry the scan
    /// found.
    public let entryCapacity: Int
    public let accounting: RecordedAccounting

    /// The choices the scan ran with. Two runs with different choices measured
    /// different things, and a comparison says so rather than presenting the
    /// difference as a change on disk.
    public let options: RecordedOptions

    /// The volume's own figures at the time of the scan, when they were
    /// available. Stored beside the scan, never subtracted from it.
    public let volume: RecordedVolume?

    public var root: URL { URL(fileURLWithPath: rootPath) }

    public var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    public var categoryBreakdown: [FileCategory: Int64] {
        var breakdown: [FileCategory: Int64] = [:]
        for (raw, size) in categorySizes {
            if let category = FileCategory(rawValue: raw) {
                breakdown[category] = size
            }
        }
        return breakdown
    }

    public init(
        schemaVersion: Int = ScanRecord.currentSchemaVersion,
        id: UUID = UUID(),
        rootPath: String,
        startedAt: Date,
        finishedAt: Date,
        totalLogicalSize: Int64,
        totalAllocatedSize: Int64,
        fileCount: Int,
        directoryCount: Int,
        inaccessibleCount: Int,
        errorCount: Int,
        permissionDeniedCount: Int,
        surfacedIssueCount: Int,
        categorySizes: [String: Int64],
        largestFiles: [RecordedEntry],
        largestDirectories: [RecordedEntry],
        entryCapacity: Int,
        accounting: RecordedAccounting,
        options: RecordedOptions,
        volume: RecordedVolume?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.rootPath = rootPath
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.totalLogicalSize = totalLogicalSize
        self.totalAllocatedSize = totalAllocatedSize
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.inaccessibleCount = inaccessibleCount
        self.errorCount = errorCount
        self.permissionDeniedCount = permissionDeniedCount
        self.surfacedIssueCount = surfacedIssueCount
        self.categorySizes = categorySizes
        self.largestFiles = largestFiles
        self.largestDirectories = largestDirectories
        self.entryCapacity = entryCapacity
        self.accounting = accounting
        self.options = options
        self.volume = volume
    }

    /// Captures a finished scan. Only `.finished` summaries belong here; the
    /// caller decides that, because only the caller knows the outcome.
    public init(
        summary: ScanSummary,
        options: RecordedOptions,
        volume: RecordedVolume? = nil,
        id: UUID = UUID()
    ) {
        self.init(
            id: id,
            rootPath: summary.root.standardizedFileURL.path,
            startedAt: ScanRecord.wholeSecond(summary.startedAt),
            finishedAt: ScanRecord.wholeSecond(summary.finishedAt),
            totalLogicalSize: summary.totalLogicalSize,
            totalAllocatedSize: summary.totalAllocatedSize,
            fileCount: summary.fileCount,
            directoryCount: summary.directoryCount,
            inaccessibleCount: summary.inaccessibleCount,
            errorCount: summary.errorCount,
            permissionDeniedCount: summary.permissionDeniedCount,
            surfacedIssueCount: summary.surfacedIssueCount,
            categorySizes: Dictionary(uniqueKeysWithValues: summary.categoryBreakdown.map { ($0.key.rawValue, $0.value) }),
            largestFiles: summary.largestFiles.map(RecordedEntry.init),
            largestDirectories: summary.largestDirectories.map(RecordedEntry.init),
            entryCapacity: ScanRecord.currentEntryCapacity,
            accounting: RecordedAccounting(summary.accounting),
            options: options,
            volume: volume
        )
    }

    /// Stored dates are whole seconds: the record is written as ISO 8601 without
    /// a fraction, and rounding on the way in makes a stored record equal to the
    /// one that produced it.
    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

/// A ranked entry — a file or a folder — as one scan reported it.
public struct RecordedEntry: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let modifiedAt: Date?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        logicalSize: Int64,
        allocatedSize: Int64,
        modifiedAt: Date?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modifiedAt = modifiedAt
    }

    init(_ node: ScanNode) {
        self.init(
            path: node.url.standardizedFileURL.path,
            name: node.name,
            isDirectory: node.isDirectory,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            modifiedAt: node.modifiedAt.map(ScanRecord.wholeSecond)
        )
    }
}

/// `ScanAccounting` as a stored value, with the same fields the coverage sheet
/// explains. Kept separate so the frozen model is not a file format.
public struct RecordedAccounting: Codable, Sendable, Equatable {
    public let hardlinkFileCount: Int
    public let hardlinkExtraLogicalSize: Int64
    public let hardlinkExtraAllocatedSize: Int64
    public let datalessFileCount: Int
    public let datalessLogicalSize: Int64
    public let datalessAllocatedSize: Int64
    public let skippedSymlinkCount: Int
    public let skippedVolumeCount: Int
    public let specialFileCount: Int
    public let excludedItemCount: Int

    public init(_ accounting: ScanAccounting) {
        hardlinkFileCount = accounting.hardlinkFileCount
        hardlinkExtraLogicalSize = accounting.hardlinkExtraLogicalSize
        hardlinkExtraAllocatedSize = accounting.hardlinkExtraAllocatedSize
        datalessFileCount = accounting.datalessFileCount
        datalessLogicalSize = accounting.datalessLogicalSize
        datalessAllocatedSize = accounting.datalessAllocatedSize
        skippedSymlinkCount = accounting.skippedSymlinkCount
        skippedVolumeCount = accounting.skippedVolumeCount
        specialFileCount = accounting.specialFileCount
        excludedItemCount = accounting.excludedItemCount
    }

    public init(
        hardlinkFileCount: Int = 0,
        hardlinkExtraLogicalSize: Int64 = 0,
        hardlinkExtraAllocatedSize: Int64 = 0,
        datalessFileCount: Int = 0,
        datalessLogicalSize: Int64 = 0,
        datalessAllocatedSize: Int64 = 0,
        skippedSymlinkCount: Int = 0,
        skippedVolumeCount: Int = 0,
        specialFileCount: Int = 0,
        excludedItemCount: Int = 0
    ) {
        self.hardlinkFileCount = hardlinkFileCount
        self.hardlinkExtraLogicalSize = hardlinkExtraLogicalSize
        self.hardlinkExtraAllocatedSize = hardlinkExtraAllocatedSize
        self.datalessFileCount = datalessFileCount
        self.datalessLogicalSize = datalessLogicalSize
        self.datalessAllocatedSize = datalessAllocatedSize
        self.skippedSymlinkCount = skippedSymlinkCount
        self.skippedVolumeCount = skippedVolumeCount
        self.specialFileCount = specialFileCount
        self.excludedItemCount = excludedItemCount
    }
}

/// The scan choices a record was produced with, as stored values.
public struct RecordedOptions: Codable, Sendable, Equatable {
    public let followSymlinks: Bool
    public let stayOnVolume: Bool
    public let includeHidden: Bool
    public let excludedPaths: [String]

    public init(
        followSymlinks: Bool,
        stayOnVolume: Bool,
        includeHidden: Bool,
        excludedPaths: [String]
    ) {
        self.followSymlinks = followSymlinks
        self.stayOnVolume = stayOnVolume
        self.includeHidden = includeHidden
        self.excludedPaths = excludedPaths
    }
}

/// The volume a scan measured, recorded beside it. Never used to reconcile the
/// scan's total: a folder scan and a volume's used space measure different
/// things.
public struct RecordedVolume: Codable, Sendable, Equatable {
    public let name: String
    public let mountPath: String
    public let totalCapacity: Int64
    public let availableCapacity: Int64

    public init(name: String, mountPath: String, totalCapacity: Int64, availableCapacity: Int64) {
        self.name = name
        self.mountPath = mountPath
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }
}
