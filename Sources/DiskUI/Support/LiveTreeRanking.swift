import Foundation
import DiskCore

/// The largest files and folders the live tree holds right now.
public struct LiveTopEntries: Sendable, Equatable {
    /// Files with bytes, largest first — a link the scan did not follow is an
    /// entry without bytes and has no place in a ranking by size.
    public let files: [ScanNode]
    /// Folders below the scanned root, largest first.
    public let directories: [ScanNode]

    public init(files: [ScanNode], directories: [ScanNode]) {
        self.files = files
        self.directories = directories
    }
}

/// Ranks the entries of a live tree the way the scan's own top lists do.
///
/// The scan builds its `largestFiles`/`largestDirectories` once, at the end of the
/// walk; the tree moves afterwards, so a screen that shows a ranking has to ask
/// the tree. The walk reads facts only — no names are decoded — and the names of
/// the entries it keeps are materialized at the end, so the cost is the tree size
/// and not the size of what it prints.
public enum LiveTreeRanking {
    /// How many entries a screen shows per ranking, the scan's own cap.
    public static let limit = 100

    /// The largest files and folders, or `nil` when the caller cancelled.
    public static func topEntries(
        in tree: LiveTree,
        limit: Int = limit,
        maxVisitedEntries: Int = .max,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> LiveTopEntries? {
        let capacity = max(0, limit)
        guard capacity > 0 else { return LiveTopEntries(files: [], directories: []) }

        var files = BoundedTop(capacity: capacity)
        var directories = BoundedTop(capacity: capacity)
        var visited = 0
        var cancelled = false

        tree.walkNodes { facts in
            if cancelled || isCancelled() {
                cancelled = true
                return .stop
            }
            guard visited < maxVisitedEntries else { return .stop }
            visited += 1

            switch facts.kind {
            case .file:
                if facts.fileCount > 0 {
                    files.offer(facts)
                }
                return .skipChildren
            case .directory:
                // The scanned root is not one of its own folders, exactly as the
                // scan's ranked list leaves it out.
                if facts.id != LiveTree.rootID {
                    directories.offer(facts)
                }
                return .descend
            }
        }
        guard !cancelled else { return nil }

        return LiveTopEntries(
            files: files.ids.compactMap { tree.scanNode(for: $0) },
            directories: directories.ids.compactMap { tree.scanNode(for: $0) }
        )
    }

    /// Keeps the `capacity` largest entries by logical size, in order.
    ///
    /// The list stays sorted while it is filled, which is the right trade for a
    /// hundred slots: every insert is a short binary search and a single move,
    /// and nothing is sorted at the end.
    private struct BoundedTop {
        let capacity: Int
        private(set) var ids: [LiveNodeID] = []
        private var sizes: [Int64] = []

        init(capacity: Int) {
            self.capacity = capacity
            ids.reserveCapacity(capacity)
            sizes.reserveCapacity(capacity)
        }

        mutating func offer(_ facts: LiveTree.NodeFacts) {
            let size = facts.logicalSize
            guard size > 0 else { return }

            // Where this entry belongs among the held ones: by size, then by id,
            // so the order never depends on the order of the walk.
            var low = 0
            var high = ids.count
            while low < high {
                let middle = (low + high) / 2
                if sizes[middle] > size || (sizes[middle] == size && ids[middle] < facts.id) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < capacity else { return }
            ids.insert(facts.id, at: low)
            sizes.insert(size, at: low)
            if ids.count > capacity {
                ids.removeLast()
                sizes.removeLast()
            }
        }
    }
}
