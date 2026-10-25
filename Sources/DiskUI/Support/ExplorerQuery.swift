import Foundation
import DiskCore
import DiskLocalization

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
        case .size: L10n.string("Size")
        case .name: L10n.string("Name")
        case .date: L10n.string("Date")
        case .items: L10n.string("Items")
        }
    }
}

/// The entries the results screen lists for one folder.
///
/// Ordering lives here rather than in the view so the chart and the explorer
/// share one definition of what is on screen. Search is not an entry filter: the
/// field searches the whole scan (`ScanSearch`), so this only decides what a
/// folder and the engine's ranked lists present.
enum ExplorerQuery {
    /// The presentable entries of a folder, in the list's order.
    static func entries(in children: [ScanNode], sort: SortOrder) -> [ScanNode] {
        ordered(children.filter(\.isPresentable), sort: sort)
    }

    /// The explorer's order applied to entries already chosen for the list.
    ///
    /// A folder's list, a ranked list, and a search's matches are chosen
    /// differently but read the same way, so the ordering lives here once.
    static func ordered(_ nodes: [ScanNode], sort: SortOrder) -> [ScanNode] {
        var nodes = nodes
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
    /// The results screen shows the engine's top 100 files and folders, which
    /// come sorted by size; the ranked lists keep that order and drop the entries
    /// with nothing to draw.
    static func ranked(_ nodes: [ScanNode]) -> [ScanNode] {
        nodes.filter(\.isPresentable).sorted { $0.logicalSize > $1.logicalSize }
    }
}
