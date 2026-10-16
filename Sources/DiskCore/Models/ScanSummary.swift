import Foundation

/// Aggregate result of a scan.
///
/// Serves two roles in the frozen contract: the terminal result carried by
/// `ScanEvent.finished`, and the in-flight snapshot carried by the non-terminal
/// `ScanEvent.partial`. In both roles the fields report only work actually
/// completed — `rootChildren` is the one field that keeps filling in while a
/// walk is under way, and it reports bytes counted, never a projection. For a
/// partial snapshot `finishedAt` is the snapshot timestamp.
///
/// Frozen by the Architecture & Shared Contracts document (`docs/ARCHITECTURE.md`).
public struct ScanSummary: Sendable {
    public let root: URL
    public let totalLogicalSize: Int64
    public let totalAllocatedSize: Int64
    public let fileCount: Int
    public let directoryCount: Int
    /// Distinct directories that could not be enumerated or whose entries were
    /// denied — the store-side "could not read this folder" total.
    public let inaccessibleCount: Int
    /// Truthful, uncapped total of non-fatal issues (permission + I/O + other).
    public let errorCount: Int
    /// Distinct directories denied by TCC/POSIX permissions. Always a subset of
    /// `inaccessibleCount`; drives the permission-specific banner.
    /// `0` means the scan hit no access restriction.
    public let permissionDeniedCount: Int
    /// Number of per-path issue details actually surfaced to the consumer. The
    /// engine caps this (see `FileScanner.maxSurfacedIssues`), so it may be less
    /// than `errorCount`. Never fabricated — `0` when nothing was surfaced.
    public let surfacedIssueCount: Int
    public let startedAt: Date
    public let finishedAt: Date
    public let categoryBreakdown: [FileCategory: Int64]   // by logical size
    public let largestFiles: [ScanNode]                   // top N, default 100
    public let largestDirectories: [ScanNode]             // top N, default 100
    /// The scan root's own entries — its files and the folders it holds — as the
    /// walk has discovered them, largest first.
    ///
    /// A directory's node is minted only once its whole subtree has finished, so
    /// `largestDirectories` cannot show a folder that is still being counted,
    /// and the folders that take longest to finish are exactly the ones a live
    /// screen needs first. This carries the root's entries from the moment they
    /// are discovered, each folder with the bytes counted under it so far — real
    /// completed work that grows, never a projection — so a screen fills in from
    /// the first snapshot instead of waiting for whole folders to complete.
    ///
    /// The whole group is reported together, the folders the root holds included
    /// before they have been walked, because a screen colours an entry by its
    /// place among its siblings: half a group would take places that move when
    /// the rest arrives. Empty once the summary carries the root itself in
    /// `largestDirectories`, whose `children` are then the complete list.
    public let rootChildren: [ScanNode]
}
