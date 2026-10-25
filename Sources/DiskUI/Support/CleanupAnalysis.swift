import Foundation
import DiskCore
import DiskLocalization

/// The kinds of place the cleanup analysis looks, in the order the sheet shows
/// them.
public enum CleanupKind: String, CaseIterable, Identifiable, Sendable {
    case largeAndOld
    case caches
    case downloads

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .largeAndOld: L10n.string("Large and old")
        case .caches: L10n.string("Caches")
        case .downloads: L10n.string("Old downloads")
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
    ///
    /// The walk reads the live tree, so a folder that changed or arrived since
    /// the scan is judged on what it holds now. Every number and date it uses was
    /// measured; nothing here touches the filesystem.
    public static func analyze(
        in tree: LiveTree,
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
        let rootName = tree.entry(for: LiveTree.rootID)?.name

        var visited = 0
        var stoppedAtLimit = false
        // The scan root itself is never offered: the reclaim guard would refuse
        // it, and a root that happens to be a cache is the reason the person is
        // looking, not a candidate. The walk starts at its entries.
        var stack: [(entry: LiveEntry, parentName: String?, inDownloads: Bool)] = tree
            .children(of: LiveTree.rootID)
            .map { ($0, rootName, rootName == "Downloads") }

        while let item = stack.popLast() {
            if isCancelled() { return nil }
            visited += 1
            if visited > policy.maxVisitedNodes {
                stoppedAtLimit = true
                break
            }

            let node = item.entry
            if node.isSymlink { continue }

            if node.kind == .directory {
                if isCacheRoot(name: node.name, parentName: item.parentName) {
                    if node.logicalSize > 0 {
                        caches.offer(CandidateFacts(of: node))
                    }
                    continue
                }
                let inDownloads = item.inDownloads || node.name == "Downloads"
                for child in tree.children(of: node.id) {
                    stack.append((child, node.name, inDownloads))
                }
                continue
            }

            if node.logicalSize >= policy.duplicateMinimum {
                duplicateSizes.offer(CandidateFacts(of: node))
            }

            if node.logicalSize >= policy.largeFileMinimum,
               let modified = node.modifiedAt,
               modified <= largeCutoff {
                largeAndOld.offer(CandidateFacts(of: node))
            }

            if item.inDownloads,
               let modified = node.modifiedAt,
               modified <= downloadCutoff {
                downloads.offer(CandidateFacts(of: node))
            }
        }

        let duplicates = duplicateSizes.finish(maxGroups: policy.maxDuplicateGroups, tree: tree)
        return CleanupReport(
            groups: [
                largeAndOld.finish(tree: tree),
                caches.finish(tree: tree),
                downloads.finish(tree: tree),
            ],
            duplicateGroups: duplicates.groups,
            duplicateGroupCount: duplicates.totalGroupCount,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit,
            policy: policy
        )
    }

    /// A cache folder by name and parent: `Library/Caches`, or Xcode's
    /// `DerivedData`. Read from the walk's own parent rather than a path, so the
    /// test needs no path building for every entry.
    static func isCacheRoot(name: String, parentName: String?) -> Bool {
        guard let parentName else { return false }
        if name == "Caches", parentName == "Library" { return true }
        if name == "DerivedData", parentName == "Xcode" { return true }
        return false
    }

    /// The measured facts of one entry, enough to rank and materialize it later.
    private struct CandidateFacts {
        let id: LiveNodeID
        let logicalSize: Int64
        let allocatedSize: Int64
        let modifiedAt: Date?

        init(of entry: LiveEntry) {
            self.id = entry.id
            self.logicalSize = entry.logicalSize
            self.allocatedSize = entry.allocatedSize
            self.modifiedAt = entry.modifiedAt
        }
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
        private var kept: [CandidateFacts] = []

        init(kind: CleanupKind, capacity: Int) {
            self.kind = kind
            self.capacity = max(0, capacity)
        }

        mutating func offer(_ facts: CandidateFacts) {
            matchCount += 1
            totalLogicalSize += max(0, facts.logicalSize)
            totalAllocatedSize += max(0, facts.allocatedSize)
            kept.append(facts)
            // Trim as the walk runs so a huge match set cannot grow without
            // bound; the final cut happens in `finish()`.
            if kept.count > max(capacity * 2, 16) {
                trim()
            }
        }

        func finish(tree: LiveTree) -> CleanupGroup {
            var items = kept
            items.sort { lhs, rhs in
                lhs.logicalSize == rhs.logicalSize
                    ? lhs.id < rhs.id
                    : lhs.logicalSize > rhs.logicalSize
            }
            if items.count > capacity {
                items.removeLast(items.count - capacity)
            }
            let candidates = items
                .compactMap { tree.scanNode(for: $0.id) }
                .map(CleanupCandidate.init)
                .sorted { lhs, rhs in
                    lhs.logicalSize == rhs.logicalSize
                        ? lhs.url.path < rhs.url.path
                        : lhs.logicalSize > rhs.logicalSize
                }
            return CleanupGroup(
                kind: kind,
                candidates: candidates,
                matchCount: matchCount,
                totalLogicalSize: totalLogicalSize,
                totalAllocatedSize: totalAllocatedSize
            )
        }

        private mutating func trim() {
            kept.sort { lhs, rhs in
                lhs.logicalSize == rhs.logicalSize
                    ? lhs.id < rhs.id
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
        private var firstBySize: [Int64: CandidateFacts] = [:]
        private var groups: [Int64: BoundedDuplicateGroup] = [:]

        init(capacity: Int) {
            self.capacity = max(2, capacity)
        }

        mutating func offer(_ facts: CandidateFacts) {
            let size = max(0, facts.logicalSize)
            if var group = groups[size] {
                group.offer(facts)
                groups[size] = group
            } else if let first = firstBySize.removeValue(forKey: size) {
                var group = BoundedDuplicateGroup(logicalSize: size, capacity: capacity)
                group.offer(first)
                group.offer(facts)
                groups[size] = group
            } else {
                firstBySize[size] = facts
            }
        }

        func finish(maxGroups: Int, tree: LiveTree) -> (groups: [DuplicateSizeGroup], totalGroupCount: Int) {
            let totalGroupCount = groups.count
            var finished = groups.values.map { $0.finish(tree: tree) }
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
        private var kept: [CandidateFacts] = []

        init(logicalSize: Int64, capacity: Int) {
            self.logicalSize = logicalSize
            self.capacity = max(2, capacity)
        }

        mutating func offer(_ facts: CandidateFacts) {
            matchCount += 1
            kept.append(facts)
            if kept.count > max(capacity * 2, 16) {
                trim()
            }
        }

        func finish(tree: LiveTree) -> DuplicateSizeGroup {
            var candidates = kept.compactMap { facts -> CleanupCandidate? in
                guard let node = tree.scanNode(for: facts.id) else { return nil }
                return CleanupCandidate(node: node)
            }
            candidates.sort { $0.url.path < $1.url.path }
            if candidates.count > capacity {
                candidates.removeLast(candidates.count - capacity)
            }
            return DuplicateSizeGroup(
                logicalSize: logicalSize,
                candidates: candidates,
                matchCount: matchCount
            )
        }

        /// The trim keeps the first entry ids while the walk is going, so a huge
        /// size group cannot grow without bound; the final cut is by path once the
        /// tree is in hand.
        private mutating func trim() {
            kept.sort { $0.id < $1.id }
            if kept.count > capacity {
                kept.removeLast(kept.count - capacity)
            }
        }
    }
}
