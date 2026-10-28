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
    ///
    /// A home folder holds a few million entries and this Mac's full disk under
    /// five, so a query normally answers over the whole tree. The cap is a time
    /// bound for the trees larger than that, not a memory one — the walk keeps no
    /// per-entry state — and a search that reaches it says so.
    public static let visitedNodeLimit = 5_000_000

    /// Returns nil when the caller cancelled before the walk finished.
    public static func results(
        for query: String,
        searching entries: [ScanNode],
        limit: Int = resultLimit,
        maxVisitedNodes: Int = visitedNodeLimit,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ScanSearchResults? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return empty(needle) }

        let matcher = Matcher(needle)
        let matchesPaths = needle.contains("/")
        let capacity = max(limit, 0)
        var matches: [ScanNode] = []
        var matchCount = 0
        var visited = 0
        var stoppedAtLimit = false
        var smallestKeptSize = capacity == 0 ? Int64.max : Int64.min

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

            if matcher.matches(node.name) || (matchesPaths && matcher.matches(node.url.path)) {
                matchCount += 1
                // A match smaller than every entry already kept cannot reach
                // the largest list, so it is counted without being kept.
                if node.logicalSize >= smallestKeptSize {
                    matches.append(node)
                    if matches.count > max(capacity * 2, 32) {
                        matches = largest(matches, to: capacity)
                        smallestKeptSize = matches.last?.logicalSize ?? Int64.max
                    }
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

    /// The same search over the live tree.
    ///
    /// The tree holds what the disk holds now, so a file created after the scan is
    /// found and a deleted one is not. Names come from the tree; a path query
    /// walks with each entry's path, which is why it costs more than a name query.
    /// The walk is bounded by the same visited cap and can be cancelled between
    /// entries.
    public static func results(
        for query: String,
        in tree: LiveTree,
        limit: Int = resultLimit,
        maxVisitedNodes: Int = visitedNodeLimit,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ScanSearchResults? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return empty(needle) }

        let matcher = Matcher(needle)
        let matchesPaths = needle.contains("/")
        let capacity = max(limit, 0)
        var matches: [ScanNode] = []
        var matchCount = 0
        var visited = 0
        var stoppedAtLimit = false
        var cancelled = false
        var smallestKeptSize = capacity == 0 ? Int64.max : Int64.min

        // The same rules as the frozen-node walk, over an entry whose numbers
        // are read from the arena instead of a materialized node.
        func consider(_ entry: LiveEntry, path: String?) -> LiveTree.WalkStep {
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

            let matched = matcher.matches(entry.name)
                || (matchesPaths && path.map(matcher.matches) == true)
            if matched {
                matchCount += 1
                // The same bound as the frozen-node walk: one that cannot reach
                // the list is counted without materializing its node.
                if entry.logicalSize >= smallestKeptSize, let node = tree.scanNode(for: entry.id) {
                    matches.append(node)
                    if matches.count > max(capacity * 2, 32) {
                        matches = largest(matches, to: capacity)
                        smallestKeptSize = matches.last?.logicalSize ?? Int64.max
                    }
                }
            }
            // A symbolic link is an entry by its own name; whatever it points at
            // is not walked, exactly as the scan did not walk it.
            return entry.kind == .directory && !entry.isSymlink ? .descend : .skipChildren
        }

        if matchesPaths {
            tree.walk { entry, path in consider(entry, path: path) }
        } else {
            tree.walk { entry in consider(entry, path: nil) }
        }
        guard !cancelled else { return nil }

        return ScanSearchResults(
            query: needle,
            matches: largest(matches, to: capacity),
            matchCount: matchCount,
            visitedCount: visited,
            stoppedAtLimit: stoppedAtLimit
        )
    }

    private static func empty(_ needle: String) -> ScanSearchResults {
        ScanSearchResults(
            query: needle,
            matches: [],
            matchCount: 0,
            visitedCount: 0,
            stoppedAtLimit: false
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

    /// One query, matched against names case- and diacritic-insensitively.
    ///
    /// `range(of:options:)` costs several microseconds per name and a search runs
    /// it once per entry — most of a walk's time. When both sides are ASCII, ASCII
    /// case folding is exactly that comparison, and one pass over the bytes costs
    /// a fraction of it; nearly every name is ASCII. A name or query with anything
    /// else in it falls back to the Unicode comparison.
    private struct Matcher {
        let query: String
        /// The query folded to ASCII lowercase, or nil when it holds a byte the
        /// ASCII comparison cannot account for.
        let asciiQuery: [UInt8]?

        init(_ query: String) {
            self.query = query
            let bytes = Array(query.utf8)
            self.asciiQuery = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.fold) : nil
        }

        func matches(_ text: String) -> Bool {
            if let asciiQuery, let answer = Self.asciiContains(text, asciiQuery) {
                return answer
            }
            return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        private static func fold(_ byte: UInt8) -> UInt8 {
            byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte
        }

        /// Whether `text` holds `query` under ASCII case folding, or nil when
        /// `text` is not ASCII and only the Unicode comparison can say.
        private static func asciiContains(_ text: String, _ query: [UInt8]) -> Bool? {
            text.utf8.withContiguousStorageIfAvailable { haystack in
                guard haystack.allSatisfy({ $0 < 0x80 }) else { return nil }
                guard haystack.count >= query.count else { return false }
                for start in 0...(haystack.count - query.count) {
                    var offset = 0
                    while offset < query.count, fold(haystack[start + offset]) == query[offset] {
                        offset += 1
                    }
                    if offset == query.count { return true }
                }
                return false
            } ?? nil
        }
    }
}
