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
/// Search, category filter and ordering live here rather than in the view so the
/// chart and the explorer share one definition of what is on screen.
enum ExplorerQuery {
    static func entries(
        in children: [ScanNode],
        search: String,
        category: FileCategory?,
        sort: SortOrder
    ) -> [ScanNode] {
        var nodes = children.filter(\.isPresentable)
        if let category {
            nodes = nodes.filter { $0.category == category }
        }
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
}
