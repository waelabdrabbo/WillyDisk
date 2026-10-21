import Foundation
import DiskCore

/// The kinds of place the cleanup analysis looks, in the order the sheet shows
/// them.
public enum CleanupKind: String, CaseIterable, Identifiable, Sendable {
    case largeAndOld
    case caches
    case downloads

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .largeAndOld: "Large and old"
        case .caches: "Caches"
        case .downloads: "Old downloads"
        }
    }
}

/// One item the analysis would put in front of a person for review.
public struct CleanupCandidate: Identifiable, Equatable, Sendable {
    public let node: ScanNode

    public var id: URL { node.url }
    public var name: String { node.name }
    public var url: URL { node.url }
    public var isDirectory: Bool { node.isDirectory }
    public var logicalSize: Int64 { node.logicalSize }
    public var allocatedSize: Int64 { node.allocatedSize }
    public var modifiedAt: Date? { node.modifiedAt }
    /// Files inside the candidate, so a folder can say what it holds instead of
    /// showing its own modification date, which only says when a child changed.
    public var fileCount: Int { node.fileCount }

    init(node: ScanNode) {
        self.node = node
    }
}

/// One section of the report: what matched, what is shown, and the size of
/// everything that matched.
public struct CleanupGroup: Identifiable, Equatable, Sendable {
    public let kind: CleanupKind
    /// The largest matches, at most the policy's cap.
    public let candidates: [CleanupCandidate]
    /// Every match, including the ones the cap left out.
    public let matchCount: Int
    /// Logical size of every match, not just the shown ones.
    public let totalLogicalSize: Int64
    /// Allocated size of every match, not just the shown ones.
    public let totalAllocatedSize: Int64

    public var id: CleanupKind { kind }
    public var isTruncated: Bool { matchCount > candidates.count }
}

/// What one pass over a finished scan found, with the limits it ran under.
public struct CleanupReport: Equatable, Sendable {
    public let groups: [CleanupGroup]
    /// Same-size files worth checking, largest size first, capped by the policy.
    /// These are candidates, not duplicates; `DuplicateHasher` is what reads
    /// their contents.
    public let duplicateGroups: [DuplicateSizeGroup]
    /// Every size group with at least two files, including those the cap left out.
    public let duplicateGroupCount: Int
    /// Nodes actually looked at, so a stopped walk can say how far it got.
    public let visitedCount: Int
    /// True when the walk stopped at the policy's node cap: the report is a
    /// sample of the tree, not the whole of it.
    public let stoppedAtLimit: Bool
    public let policy: CleanupPolicy

    public var isEmpty: Bool {
        groups.allSatisfy { $0.candidates.isEmpty } && duplicateGroups.isEmpty
    }

    public var duplicateCandidateCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.matchCount }
    }
}

/// The thresholds and limits one analysis runs under.
///
/// These are heuristics, not rules: the sheet states each threshold beside the
/// list it produced, and nothing is moved without the reclaim confirmation.
public struct CleanupPolicy: Equatable, Sendable {
    /// A file counts as large at or above this logical size.
    public var largeFileMinimum: Int64
    /// How old a large file must be to count as old.
    public var largeFileAge: TimeInterval
    /// How old a file in a Downloads folder must be to count as stale.
    public var downloadAge: TimeInterval
    /// Most candidates kept per section; the report still counts every match.
    public var maxCandidatesPerGroup: Int
    /// A file must be at least this large to be a duplicate candidate. Same-size
    /// files below it are not worth the read.
    public var duplicateMinimum: Int64
    /// Most same-size groups checked; the largest sizes are kept.
    public var maxDuplicateGroups: Int
    /// Most files kept from one same-size group.
    public var maxDuplicateFilesPerGroup: Int
    /// Most nodes one analysis may look at before it reports a partial picture.
    public var maxVisitedNodes: Int

    public init(
        largeFileMinimum: Int64 = 500_000_000,
        largeFileAge: TimeInterval = 365 * 24 * 3600,
        downloadAge: TimeInterval = 180 * 24 * 3600,
        maxCandidatesPerGroup: Int = 100,
        duplicateMinimum: Int64 = 1_000_000,
        maxDuplicateGroups: Int = 20,
        maxDuplicateFilesPerGroup: Int = 20,
        maxVisitedNodes: Int = 2_000_000
    ) {
        self.largeFileMinimum = largeFileMinimum
        self.largeFileAge = largeFileAge
        self.downloadAge = downloadAge
        self.maxCandidatesPerGroup = maxCandidatesPerGroup
        self.duplicateMinimum = duplicateMinimum
        self.maxDuplicateGroups = maxDuplicateGroups
        self.maxDuplicateFilesPerGroup = maxDuplicateFilesPerGroup
        self.maxVisitedNodes = maxVisitedNodes
    }

    public static let standard = CleanupPolicy()
}

/// Looks through a finished scan's tree for candidates worth reviewing.
///
/// The walk reads the nodes the summary already carries: it never touches the
/// filesystem, so it cannot invent a size or a date, and it runs off the main
/// actor. Caches are recognised by path — a `Caches` folder directly inside a
/// `Library`, or Xcode's `DerivedData` — and a matching folder is offered whole,
/// with its subtree left unvisited so its files are not also listed as large and
/// old. Nothing is deleted here; the sheet sends a selection to the same reclaim
/// confirmation every other move uses.
public enum CleanupAnalysis {

    /// Returns nil when the caller cancelled before the walk finished.
    public static func analyze(
        root: ScanNode,
        policy: CleanupPolicy = .standard,
        now: Date = Date(),
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CleanupReport? {
        var largeAndOld = BoundedGroup(kind: .largeAndOld, capacity: policy.maxCandidatesPerGroup)
        var caches = BoundedGroup(kind: .caches, capacity: policy.maxCandidatesPerGroup)
        var downloads = BoundedGroup(kind: .downloads, capacity: policy.maxCandidatesPerGroup)
        var duplicateSizes = DuplicateSizeBuckets(capacity: policy.maxDuplicateFilesPerGroup)

        let largeCutoff = now.addingTimeInterval(-policy.largeFileAge)
        let downloadCutoff = now.addingTimeInterval(-policy.downloadAge)
        let rootPath = root.url.standardizedFileURL.path

        var visited = 0
        var stoppedAtLimit = false
        var stack: [(node: ScanNode, inDownloads: Bool)] = [(root, root.name == "Downloads")]

        while let entry = stack.popLast() {
            if isCancelled() { return nil }
            visited += 1
            if visited > policy.maxVisitedNodes {
                stoppedAtLimit = true
                break
            }

            let node = entry.node
            if node.isSymlink { continue }

            if node.isDirectory {
                // The scan root itself is never offered: the reclaim guard would
                // refuse it, and a root that happens to be a cache is the reason
                // the person is looking, not a candidate.
                if node.url.standardizedFileURL.path != rootPath, isCacheRoot(node) {
                    if node.logicalSize > 0 {
                        caches.offer(node)
                    }
                    continue
                }
                let inDownloads = entry.inDownloads || node.name == "Downloads"
                for child in node.children {
                    stack.append((child, inDownloads))
                }
                continue
            }

            if node.logicalSize >= policy.duplicateMinimum {
                duplicateSizes.offer(node)
            }

            if node.logicalSize >= policy.largeFileMinimum,
               let modified = node.modifiedAt,
               modified <= largeCutoff {
                largeAndOld.offer(node)
            }

            if entry.inDownloads,
               let modified = node.modifiedAt,
               modified <= downloadCutoff {
                downloads.offer(node)
            }
        }

        let duplicates = duplicateSizes.finish(maxGroups: policy.maxDuplicateGroups)
        return CleanupReport(
            groups: [largeAndOld.finish(), caches.finish(), downloads.finish()],
            duplicateGroups: duplicates.groups,
            duplicateGroupCount: duplicates.totalGroupCount,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit,
            policy: policy
        )
    }

    /// A cache folder by path: `Library/Caches`, or Xcode's `DerivedData`.
    static func isCacheRoot(_ node: ScanNode) -> Bool {
        guard node.isDirectory else { return false }
        let components = node.url.standardizedFileURL.pathComponents
        guard components.count >= 2 else { return false }
        let name = components[components.count - 1]
        let parent = components[components.count - 2]
        if name == "Caches", parent == "Library" { return true }
        if name == "DerivedData", parent == "Xcode" { return true }
        return false
    }

    /// Keeps the largest matches while counting every match.
    ///
    /// A scan can match thousands of files; only the policy's cap is retained,
    /// but the sizes and the count in the report cover all of them, so the sheet
    /// can say “showing the largest 100 of 1,234”.
    private struct BoundedGroup {
        let kind: CleanupKind
        let capacity: Int
        private(set) var matchCount = 0
        private(set) var totalLogicalSize: Int64 = 0
        private(set) var totalAllocatedSize: Int64 = 0
        private var kept: [ScanNode] = []

        init(kind: CleanupKind, capacity: Int) {
            self.kind = kind
            self.capacity = max(0, capacity)
        }

        mutating func offer(_ node: ScanNode) {
            matchCount += 1
            totalLogicalSize += max(0, node.logicalSize)
            totalAllocatedSize += max(0, node.allocatedSize)
            kept.append(node)
            // Trim as the walk runs so a huge match set cannot grow without
            // bound; the final cut happens in `finish()`.
            if kept.count > max(capacity * 2, 16) {
                trim()
            }
        }

        func finish() -> CleanupGroup {
            var items = kept
            items.sort { lhs, rhs in
                lhs.logicalSize == rhs.logicalSize
                    ? lhs.url.path < rhs.url.path
                    : lhs.logicalSize > rhs.logicalSize
            }
            if items.count > capacity {
                items.removeLast(items.count - capacity)
            }
            return CleanupGroup(
                kind: kind,
                candidates: items.map(CleanupCandidate.init),
                matchCount: matchCount,
                totalLogicalSize: totalLogicalSize,
                totalAllocatedSize: totalAllocatedSize
            )
        }

        private mutating func trim() {
            kept.sort { lhs, rhs in
                lhs.logicalSize == rhs.logicalSize
                    ? lhs.url.path < rhs.url.path
                    : lhs.logicalSize > rhs.logicalSize
            }
            if kept.count > capacity {
                kept.removeLast(kept.count - capacity)
            }
        }
    }

    /// Collects files by size without keeping every file in memory.
    ///
    /// A size seen once is held as a single node; a second file moves it into a
    /// bounded group. A size that never repeats is dropped when the walk ends.
    private struct DuplicateSizeBuckets {
        let capacity: Int
        private var firstBySize: [Int64: ScanNode] = [:]
        private var groups: [Int64: BoundedDuplicateGroup] = [:]

        init(capacity: Int) {
            self.capacity = max(2, capacity)
        }

        mutating func offer(_ node: ScanNode) {
            let size = max(0, node.logicalSize)
            if var group = groups[size] {
                group.offer(node)
                groups[size] = group
            } else if let first = firstBySize.removeValue(forKey: size) {
                var group = BoundedDuplicateGroup(logicalSize: size, capacity: capacity)
                group.offer(first)
                group.offer(node)
                groups[size] = group
            } else {
                firstBySize[size] = node
            }
        }

        func finish(maxGroups: Int) -> (groups: [DuplicateSizeGroup], totalGroupCount: Int) {
            let totalGroupCount = groups.count
            var finished = groups.values.map { $0.finish() }
            finished.sort { lhs, rhs in
                lhs.logicalSize == rhs.logicalSize
                    ? lhs.matchCount > rhs.matchCount
                    : lhs.logicalSize > rhs.logicalSize
            }
            let capacity = max(0, maxGroups)
            if finished.count > capacity {
                finished.removeLast(finished.count - capacity)
            }
            return (finished, totalGroupCount)
        }
    }

    /// One size's files, counting every match while keeping the first `capacity`
    /// paths. All files have the same size, so path order is a stable cut.
    private struct BoundedDuplicateGroup {
        let logicalSize: Int64
        let capacity: Int
        private(set) var matchCount = 0
        private var kept: [ScanNode] = []

        init(logicalSize: Int64, capacity: Int) {
            self.logicalSize = logicalSize
            self.capacity = max(2, capacity)
        }

        mutating func offer(_ node: ScanNode) {
            matchCount += 1
            kept.append(node)
            if kept.count > max(capacity * 2, 16) {
                trim()
            }
        }

        func finish() -> DuplicateSizeGroup {
            var items = kept
            items.sort { $0.url.path < $1.url.path }
            if items.count > capacity {
                items.removeLast(items.count - capacity)
            }
            return DuplicateSizeGroup(
                logicalSize: logicalSize,
                candidates: items.map(CleanupCandidate.init),
                matchCount: matchCount
            )
        }

        private mutating func trim() {
            kept.sort { $0.url.path < $1.url.path }
            if kept.count > capacity {
                kept.removeLast(kept.count - capacity)
            }
        }
    }
}
