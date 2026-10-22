import Foundation
import DiskCore

/// What a whole-scan search found.
public struct ScanSearchResults: Equatable, Sendable {
    /// The query the walk ran, trimmed.
    public let query: String
    /// The matches the list shows, largest first, never more than the limit.
    public let matches: [ScanNode]
    /// Every match the walk saw, including the ones `matches` leaves out.
    public let matchCount: Int
    /// How many entries the walk visited before it finished or stopped.
    public let visitedCount: Int
    /// True when the walk stopped at its node cap, so `matchCount` counts only
    /// the entries it reached.
    public let stoppedAtLimit: Bool

    /// Whether the list is a slice of a larger match set.
    public var isTruncated: Bool { matchCount > matches.count }
}

/// Finds names anywhere in the tree a scan carries.
///
/// The explorer's own filter only sees the folder or the ranked list on screen.
/// This walks the finished scan's nodes instead, so a match several folders deep
/// is found, and it keeps only the largest matches while counting every one, so
/// the screen can say what it is showing out of what. Nothing touches the
/// filesystem, and the walk is bounded by both the matches it keeps and the
/// entries it visits.
///
/// A bare word is matched against names. A query containing a `/` is a path
/// query and is matched against each entry's full path as well, so
/// `Photos/2024` finds what lives there — without making a one-letter query
/// return every path on the disk.
///
/// The scanned root itself is not searched: it is the scope, not one of its own
/// entries. Callers pass the root's entries.
public enum ScanSearch {
    /// How many matches a screen holds at once.
    public static let resultLimit = 200
    /// How many entries one search may visit.
    public static let visitedNodeLimit = 2_000_000

    /// Returns nil when the caller cancelled before the walk finished.
    public static func results(
        for query: String,
        searching entries: [ScanNode],
        limit: Int = resultLimit,
        maxVisitedNodes: Int = visitedNodeLimit,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ScanSearchResults? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return ScanSearchResults(
                query: needle,
                matches: [],
                matchCount: 0,
                visitedCount: 0,
                stoppedAtLimit: false
            )
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matchesPaths = needle.contains("/")
        let capacity = max(limit, 0)
        var matches: [ScanNode] = []
        var matchCount = 0
        var visited = 0
        var stoppedAtLimit = false

        var stack = entries
        while let node = stack.popLast() {
            // The cap counts entries the walk actually looked at, so it is
            // checked before this one is.
            if visited >= maxVisitedNodes {
                stoppedAtLimit = true
                break
            }
            if isCancelled() { return nil }
            visited += 1

            let matchesName = node.name.range(of: needle, options: options) != nil
            let matchesPath = matchesPaths
                && node.url.path.range(of: needle, options: options) != nil
            if matchesName || matchesPath {
                matchCount += 1
                matches.append(node)
                if matches.count > max(capacity * 2, 32) {
                    matches = largest(matches, to: capacity)
                }
            }

            // A symbolic link is an entry by its own name; its children are
            // whatever it points at, which the scan does not walk either.
            if node.isDirectory && !node.isSymlink {
                stack.append(contentsOf: node.children)
            }
        }

        return ScanSearchResults(
            query: needle,
            matches: largest(matches, to: capacity),
            matchCount: matchCount,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit
        )
    }

    /// The largest `capacity` matches, ordered the way the explorer's size sort
    /// is: bytes first, path second, so equal sizes have one stable order.
    private static func largest(_ nodes: [ScanNode], to capacity: Int) -> [ScanNode] {
        var sorted = nodes.sorted { lhs, rhs in
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
