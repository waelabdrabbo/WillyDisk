import Foundation
import DiskCore

extension ScanNode {
    /// Whether the size panes can present this entry.
    ///
    /// A wedge's angle is the entry's share of its parent, so an entry with no
    /// bytes has no share to draw. The explorer follows the same rule, so the
    /// chart and the list never disagree about what a folder holds.
    var isPresentable: Bool { logicalSize > 0 }
}

/// How the explorer orders a folder's entries.
enum SortOrder: String, CaseIterable, Identifiable {
    case size, name, date, items

    var id: String { rawValue }

    var label: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .date: "Date"
        case .items: "Items"
        }
    }
}

/// The entries the results screen lists for one folder.
///
/// Search and ordering live here rather than in the view so the chart and the
/// explorer share one definition of what is on screen.
enum ExplorerQuery {
    static func entries(
        in children: [ScanNode],
        search: String,
        sort: SortOrder
    ) -> [ScanNode] {
        var nodes = children.filter(\.isPresentable)
        if !search.isEmpty {
            nodes = nodes.filter { $0.name.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .size:
            nodes.sort { $0.logicalSize > $1.logicalSize }
        case .name:
            nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            nodes.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .items:
            nodes.sort { ($0.fileCount + $0.directoryCount) > ($1.fileCount + $1.directoryCount) }
        }
        return nodes
    }

    /// The largest items from a list the engine already ranked.
    ///
    /// The results screen shows the engine's top 100 files and folders, which come
    /// sorted by size. Search runs over that list rather than the whole scan: the
    /// screen says it is searching the top items, and the summary keeps only the
    /// ranked lists, not every file for the UI to search.
    static func ranked(_ nodes: [ScanNode], search: String) -> [ScanNode] {
        var result = nodes.filter(\.isPresentable)
        if !search.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(search)
                    || $0.url.path.localizedCaseInsensitiveContains(search)
            }
        }
        result.sort { $0.logicalSize > $1.logicalSize }
        return result
    }
}
