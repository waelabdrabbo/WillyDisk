import Foundation
import DiskCore

/// The files one category holds in a finished scan.
///
/// `files` is the largest slice of them, capped so a category with a million
/// images cannot be held on screen; `matchCount` and `totalLogicalSize` still
/// cover every match, so the screen can say what it is showing out of what.
public struct CategoryFiles: Equatable, Sendable {
    public let category: FileCategory
    public let files: [ScanNode]
    public let matchCount: Int
    public let totalLogicalSize: Int64
    public let visitedCount: Int
    /// True when the walk stopped at its node cap, so the list is a sample.
    public let stoppedAtLimit: Bool

    public var isTruncated: Bool { matchCount > files.count }
}

/// Finds the largest files of one category in the live tree.
///
/// The category breakdown says how much a category holds; this walks the tree to
/// say which files hold it. Nothing touches the filesystem, and the walk reads
/// the tree's measured facts without decoding a name — millions of entries are
/// walked on a full disk, and the names of the few it keeps are the only ones
/// materialized. It keeps only the largest `limit` files while counting every
/// match, so it can run off the main actor over a whole disk without building a
/// second index.
public enum CategoryFileIndex {

    /// Returns nil when the caller cancelled before the walk finished.
    public static func largest(
        filesOf category: FileCategory,
        in tree: LiveTree,
        limit: Int = 100,
        maxVisitedNodes: Int = 2_000_000,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CategoryFiles? {
        let capacity = max(limit, 0)
        var kept: [RankedFile] = []
        var matchCount = 0
        var totalLogicalSize: Int64 = 0
        var visited = 0
        var stoppedAtLimit = false
        var cancelled = false

        tree.walkNodes { facts in
            if cancelled { return .stop }
            if isCancelled() {
                cancelled = true
                return .stop
            }
            if visited >= maxVisitedNodes {
                stoppedAtLimit = true
                return .stop
            }
            visited += 1

            // A symbolic link is an entry by its own name; the scan does not count
            // what it points at, and neither does this walk.
            if facts.isSymlink { return .skipChildren }
            if facts.kind == .directory { return .descend }
            guard facts.category == category, facts.fileCount > 0 else { return .skipChildren }

            matchCount += 1
            totalLogicalSize += max(0, facts.logicalSize)
            kept.append(RankedFile(id: facts.id, logicalSize: facts.logicalSize))
            if kept.count > max(capacity * 2, 16) {
                kept = trimmed(kept, to: capacity)
            }
            return .skipChildren
        }
        guard !cancelled else { return nil }

        // The walk holds twice the capacity, so the final cut can be made on the
        // paths the explorer will order by rather than on arena ids.
        let files = kept
            .compactMap { tree.scanNode(for: $0.id) }
            .sorted { lhs, rhs in
                lhs.logicalSize == rhs.logicalSize
                    ? lhs.url.path < rhs.url.path
                    : lhs.logicalSize > rhs.logicalSize
            }
            .prefix(capacity)
        return CategoryFiles(
            category: category,
            files: Array(files),
            matchCount: matchCount,
            totalLogicalSize: totalLogicalSize,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit
        )
    }

    private struct RankedFile {
        let id: LiveNodeID
        let logicalSize: Int64
    }

    private static func trimmed(_ files: [RankedFile], to capacity: Int) -> [RankedFile] {
        var sorted = files.sorted { lhs, rhs in
            lhs.logicalSize == rhs.logicalSize
                ? lhs.id < rhs.id
                : lhs.logicalSize > rhs.logicalSize
        }
        if sorted.count > capacity {
            sorted.removeLast(sorted.count - capacity)
        }
        return sorted
    }
}
