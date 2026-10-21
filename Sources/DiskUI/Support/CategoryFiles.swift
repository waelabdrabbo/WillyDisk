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

/// Finds the largest files of one category in the tree a finished scan carries.
///
/// The category breakdown says how much a category holds; this walks the same
/// nodes to say which files hold it. Nothing touches the filesystem, and the walk
/// keeps only the largest `limit` files while counting every match, so it can run
/// off the main actor over a whole disk without building a second index.
public enum CategoryFileIndex {

    /// Returns nil when the caller cancelled before the walk finished.
    public static func largest(
        filesOf category: FileCategory,
        in root: ScanNode,
        limit: Int = 100,
        maxVisitedNodes: Int = 2_000_000,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> CategoryFiles? {
        let capacity = max(limit, 0)
        var files: [ScanNode] = []
        var matchCount = 0
        var totalLogicalSize: Int64 = 0
        var visited = 0
        var stoppedAtLimit = false

        var stack: [ScanNode] = [root]
        while let node = stack.popLast() {
            if isCancelled() { return nil }
            visited += 1
            if visited > maxVisitedNodes {
                stoppedAtLimit = true
                break
            }

            if node.isSymlink { continue }
            if node.isDirectory {
                stack.append(contentsOf: node.children)
                continue
            }

            guard node.category == category else { continue }
            matchCount += 1
            totalLogicalSize += max(0, node.logicalSize)
            files.append(node)
            if files.count > max(capacity * 2, 16) {
                files = trimmed(files, to: capacity)
            }
        }

        return CategoryFiles(
            category: category,
            files: trimmed(files, to: capacity),
            matchCount: matchCount,
            totalLogicalSize: totalLogicalSize,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit
        )
    }

    private static func trimmed(_ files: [ScanNode], to capacity: Int) -> [ScanNode] {
        var sorted = files.sorted { lhs, rhs in
            lhs.logicalSize == rhs.logicalSize
                ? lhs.url.path < rhs.url.path
                : lhs.logicalSize > rhs.logicalSize
        }
        if sorted.count > capacity {
            sorted.removeLast(sorted.count - capacity)
        }
        return sorted
    }
}
