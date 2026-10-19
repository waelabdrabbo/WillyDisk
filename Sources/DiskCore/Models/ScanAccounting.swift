import Foundation

/// What the scan counted, and what it deliberately did not.
///
/// The totals on `ScanSummary` are the bytes of every entry the walk reached.
/// Some of those bytes are not distinct data (hard links), some are not on this
/// disk (dataless files), and some entries are left out entirely (unfollowed
/// links, other volumes, special files). Keeping those facts separate lets a
/// screen explain a scanned total honestly instead of reconciling it to the
/// volume by guesswork.
///
/// Frozen by the Architecture & Shared Contracts document (`docs/ARCHITECTURE.md`).
public struct ScanAccounting: Sendable, Equatable {
    /// Distinct regular files whose link count is greater than one, whether or
    /// not more than one of their links was reached by this scan.
    public let hardlinkFileCount: Int
    /// Logical bytes counted again for links reached after the first one. The
    /// first link's bytes are part of the scan total; each later link's bytes
    /// are counted here as an overlap.
    public let hardlinkExtraLogicalSize: Int64
    /// Allocated bytes counted again for later links.
    public let hardlinkExtraAllocatedSize: Int64

    /// Regular files whose data is not present on this disk (`SF_DATALESS`).
    public let datalessFileCount: Int
    /// Logical size those files report. Their data lives in the cloud, so this
    /// is not space the scan could reclaim locally.
    public let datalessLogicalSize: Int64
    /// Allocated bytes those files actually occupy locally.
    public let datalessAllocatedSize: Int64

    /// Symbolic links the walk did not follow: links are not followed by
    /// default, and a followed link can still be skipped for being broken,
    /// outside the root, on another volume, or already visited.
    public let skippedSymlinkCount: Int
    /// Directories the walk did not enter because they belong to another volume
    /// while `stayOnVolume` is set.
    public let skippedVolumeCount: Int
    /// Sockets, devices, and FIFOs the walk skipped.
    public let specialFileCount: Int
    /// Entries the walk skipped because they match a path listed in the scan
    /// request's exclusions. Their contents are not part of the totals; the
    /// count is the disclosure, not a measured size.
    public let excludedItemCount: Int

    public static let zero = ScanAccounting()

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

    /// Whether the scan found anything a coverage explanation should mention.
    public var hasFindings: Bool {
        hardlinkFileCount > 0
            || datalessFileCount > 0
            || skippedSymlinkCount > 0
            || skippedVolumeCount > 0
            || specialFileCount > 0
            || excludedItemCount > 0
    }
}
