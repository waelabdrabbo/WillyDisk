import Foundation

/// What a rule's findings are worth trusting for.
///
/// The tier decides what a bulk action may touch: a rebuildable rule can offer a
/// whole section because the app that made those files makes them again; a
/// personal rule is the person's own work and is only ever chosen row by row.
public enum CleanupTier: String, CaseIterable, Sendable {
    /// The app or the system rebuilds it. Removing one costs time, not data.
    case rebuildable
    /// The person's own files: nothing puts them back.
    case personal
}

/// The kinds of place the cleanup analysis looks, in the order the sheet shows
/// them: rebuildable rules first, personal rules last.
///
/// A rule carries its identity and its tier; its threshold lives in
/// `CleanupPolicy` and its wording lives in the UI, so the CLI and the app can
/// run the same rules.
public enum CleanupRule: String, CaseIterable, Identifiable, Sendable {
    case caches
    case developerSupport
    case simulators
    case logs
    case downloads
    case largeAndOld

    public var id: String { rawValue }

    public var tier: CleanupTier {
        switch self {
        case .caches, .developerSupport, .simulators, .logs: .rebuildable
        case .downloads, .largeAndOld: .personal
        }
    }

    /// Where the rule sits among its siblings, so a screen can order sections
    /// without repeating the enum.
    public var displayOrder: Int {
        Self.allCases.firstIndex(of: self) ?? 0
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
    /// The bytes this item occupies on disk: what moving it would return once
    /// the Trash is emptied.
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
    public let rule: CleanupRule
    /// The largest matches by local bytes, at most the policy's cap.
    public let candidates: [CleanupCandidate]
    /// Every match, including the ones the cap left out.
    public let matchCount: Int
    /// Logical size of every match, not just the shown ones. A measurement, not
    /// the space a move would free.
    public let totalLogicalSize: Int64
    /// Allocated size of every match, not just the shown ones: the bytes
    /// emptying the Trash would return.
    public let totalAllocatedSize: Int64

    public var id: CleanupRule { rule }
    public var tier: CleanupTier { rule.tier }
    public var isTruncated: Bool { matchCount > candidates.count }
}

/// What one pass over a finished scan found, with the limits it ran under.
public struct CleanupReport: Equatable, Sendable {
    /// One group per rule, in rule order; a rule that matched nothing is empty.
    public let groups: [CleanupGroup]
    /// Same-size files worth checking, largest size first, capped by the policy.
    /// These are candidates, not duplicates; `DuplicateHasher` is what reads
    /// their contents.
    public let duplicateGroups: [DuplicateSizeGroup]
    /// Every size group with at least two files, including those the cap left out.
    public let duplicateGroupCount: Int
    /// Every file in a size group with another file, including the ones the
    /// group and file caps left out.
    public let duplicateFileCount: Int
    /// Nodes actually looked at, so a stopped walk can say how far it got.
    public let visitedCount: Int
    /// True when the walk stopped at the policy's node cap: the report is a
    /// sample of the tree, not the whole of it.
    public let stoppedAtLimit: Bool
    public let policy: CleanupPolicy

    public var isEmpty: Bool {
        groups.allSatisfy { $0.candidates.isEmpty } && duplicateGroups.isEmpty
    }

    /// Files in the size groups the sheet shows, which are the ones Check
    /// Contents would read. `duplicateFileCount` is the exact count.
    public var duplicateCandidateCount: Int {
        duplicateGroups.reduce(0) { $0 + $1.matchCount }
    }
}

/// The thresholds and limits one analysis runs under.
///
/// These are heuristics, not rules: the sheet states each threshold beside the
/// list it produced, and nothing is moved without the reclaim confirmation.
public struct CleanupPolicy: Equatable, Sendable {
    /// A file counts as large at or above this many local bytes — the space
    /// emptying the Trash would return, not its logical size.
    public var largeFileMinimum: Int64
    /// How old a large file must be to count as old.
    public var largeFileAge: TimeInterval
    /// How old a file in a Downloads folder must be to count as stale.
    public var downloadAge: TimeInterval
    /// Most candidates kept per section; the report still counts every match.
    public var maxCandidatesPerGroup: Int
    /// A file must be at least this large, and stored locally, to be a duplicate
    /// candidate. Same-size files below it are not worth the read.
    public var duplicateMinimum: Int64
    /// Most same-size groups checked; the largest sizes are kept.
    public var maxDuplicateGroups: Int
    /// Most files kept from one same-size group.
    public var maxDuplicateFilesPerGroup: Int
    /// Most nodes one analysis may look at before it reports a partial picture.
    /// The walk visits each folder's largest entries first, so a stopped walk is
    /// a sample of the big end of the tree.
    public var maxVisitedNodes: Int

    public init(
        largeFileMinimum: Int64 = 500_000_000,
        largeFileAge: TimeInterval = 365 * 24 * 3600,
        downloadAge: TimeInterval = 180 * 24 * 3600,
        maxCandidatesPerGroup: Int = 100,
        duplicateMinimum: Int64 = 1_000_000,
        maxDuplicateGroups: Int = 20,
        maxDuplicateFilesPerGroup: Int = 20,
        maxVisitedNodes: Int = 10_000_000
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
/// actor. A folder a rule offers is offered whole, with its subtree left
/// unvisited, so its files are not also listed as large and old. Nothing is
/// deleted here; the caller sends a selection to the same reclaim confirmation
/// every other move uses.
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
        var buckets = CleanupRule.allCases.map {
            BoundedGroup(rule: $0, capacity: policy.maxCandidatesPerGroup)
        }
        var duplicateSizes = DuplicateSizeBuckets(capacity: policy.maxDuplicateFilesPerGroup)

        let largeCutoff = now.addingTimeInterval(-policy.largeFileAge)
        let downloadCutoff = now.addingTimeInterval(-policy.downloadAge)
        let rootName = tree.entry(for: LiveTree.rootID)?.name

        var visited = 0
        var stoppedAtLimit = false
        // The scan root itself is never offered: the reclaim guard would refuse
        // it, and a root that happens to be a cache is the reason the person is
        // looking, not a candidate. The walk starts at its entries, and each
        // folder's entries are pushed smallest first so `popLast` takes the
        // largest: a walk that reaches the node cap has covered the big end of
        // the tree before the small one.
        var stack: [(entry: LiveEntry, parentName: String?, inDownloads: Bool)] = Self
            .ascendingByLocalSize(tree.children(of: LiveTree.rootID))
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
                if let rule = wholeFolderRule(name: node.name, parentName: item.parentName) {
                    if node.allocatedSize > 0 {
                        buckets[rule.displayOrder].offer(CandidateFacts(of: node))
                    }
                    continue
                }
                let inDownloads = item.inDownloads || node.name == "Downloads"
                for child in Self.ascendingByLocalSize(tree.children(of: node.id)) {
                    stack.append((child, node.name, inDownloads))
                }
                continue
            }

            // A file with no local bytes is an iCloud placeholder or an almost
            // entirely sparse file: moving it frees nothing, and reading it for
            // a content check would pull it down from the cloud.
            let isLocal = node.allocatedSize > 0

            if isLocal, node.logicalSize >= policy.duplicateMinimum {
                duplicateSizes.offer(CandidateFacts(of: node))
            }

            if node.allocatedSize >= policy.largeFileMinimum,
               let modified = node.modifiedAt,
               modified <= largeCutoff {
                buckets[CleanupRule.largeAndOld.displayOrder].offer(CandidateFacts(of: node))
            }

            if isLocal,
               item.inDownloads,
               let modified = node.modifiedAt,
               modified <= downloadCutoff {
                buckets[CleanupRule.downloads.displayOrder].offer(CandidateFacts(of: node))
            }
        }

        let duplicates = duplicateSizes.finish(maxGroups: policy.maxDuplicateGroups, tree: tree)
        return CleanupReport(
            groups: buckets.map { $0.finish(tree: tree) },
            duplicateGroups: duplicates.groups,
            duplicateGroupCount: duplicates.totalGroupCount,
            duplicateFileCount: duplicates.totalFileCount,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit,
            policy: policy
        )
    }

    /// The rule that offers this folder whole, or nil when its contents should be
    /// walked instead.
    ///
    /// A cache, a device-support set, a simulator set, and a log folder are each
    /// one decision, so the walk stops at the folder and never lists what is
    /// inside it.
    static func wholeFolderRule(name: String, parentName: String?) -> CleanupRule? {
        guard let parentName else { return nil }
        if name == "Caches", parentName == "Library" { return .caches }
        if name == "DerivedData", parentName == "Xcode" { return .caches }
        if parentName == "Xcode", name.hasSuffix("DeviceSupport") { return .developerSupport }
        if name == "Devices", parentName == "CoreSimulator" { return .simulators }
        if name == "Logs", parentName == "Library" { return .logs }
        return nil
    }

    /// A folder's entries ordered smallest first, so popping the stack visits the
    /// largest first. Ties break on the entry id, which keeps the walk's order
    /// the same from one run to the next.
    private static func ascendingByLocalSize(_ entries: [LiveEntry]) -> [LiveEntry] {
        entries.sorted { lhs, rhs in
            lhs.allocatedSize == rhs.allocatedSize
                ? lhs.id < rhs.id
                : lhs.allocatedSize < rhs.allocatedSize
        }
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

    /// Keeps the largest matches by local bytes while counting every match.
    ///
    /// A scan can match thousands of files; only the policy's cap is retained,
    /// but the sizes and the count in the report cover all of them, so the sheet
    /// can say “showing the largest 100 of 1,234”.
    private struct BoundedGroup {
        let rule: CleanupRule
        let capacity: Int
        private(set) var matchCount = 0
        private(set) var totalLogicalSize: Int64 = 0
        private(set) var totalAllocatedSize: Int64 = 0
        private var kept: [CandidateFacts] = []

        init(rule: CleanupRule, capacity: Int) {
            self.rule = rule
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
                lhs.allocatedSize == rhs.allocatedSize
                    ? lhs.id < rhs.id
                    : lhs.allocatedSize > rhs.allocatedSize
            }
            if items.count > capacity {
                items.removeLast(items.count - capacity)
            }
            let candidates = items
                .compactMap { tree.scanNode(for: $0.id) }
                .map(CleanupCandidate.init)
                .sorted { lhs, rhs in
                    lhs.allocatedSize == rhs.allocatedSize
                        ? lhs.url.path < rhs.url.path
                        : lhs.allocatedSize > rhs.allocatedSize
                }
            return CleanupGroup(
                rule: rule,
                candidates: candidates,
                matchCount: matchCount,
                totalLogicalSize: totalLogicalSize,
                totalAllocatedSize: totalAllocatedSize
            )
        }

        private mutating func trim() {
            kept.sort { lhs, rhs in
                lhs.allocatedSize == rhs.allocatedSize
                    ? lhs.id < rhs.id
                    : lhs.allocatedSize > rhs.allocatedSize
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
    /// Both counts cover every size group, including the ones the group cap
    /// later leaves out of the report.
    private struct DuplicateSizeBuckets {
        let capacity: Int
        private var firstBySize: [Int64: CandidateFacts] = [:]
        private var groups: [Int64: BoundedDuplicateGroup] = [:]
        private(set) var totalGroupCount = 0
        private(set) var totalFileCount = 0

        init(capacity: Int) {
            self.capacity = max(2, capacity)
        }

        mutating func offer(_ facts: CandidateFacts) {
            let size = max(0, facts.logicalSize)
            if var group = groups[size] {
                group.offer(facts)
                groups[size] = group
                totalFileCount += 1
            } else if let first = firstBySize.removeValue(forKey: size) {
                var group = BoundedDuplicateGroup(logicalSize: size, capacity: capacity)
                group.offer(first)
                group.offer(facts)
                groups[size] = group
                totalGroupCount += 1
                totalFileCount += 2
            } else {
                firstBySize[size] = facts
            }
        }

        func finish(maxGroups: Int, tree: LiveTree) -> (groups: [DuplicateSizeGroup], totalGroupCount: Int, totalFileCount: Int) {
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
            return (finished, totalGroupCount, totalFileCount)
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
