import SwiftUI
import DiskCore
import DiskLocalization

/// Where a deeper treemap level reads a folder's entries from.
///
/// The sunburst receives a closure because it is laid out on the main actor; the
/// treemap's layout runs off it, so its children have to be readable from another
/// task. A snapshot answers from the node's own children, and a live tree answers
/// from the tree, which is safe to read from any actor.
public protocol TreemapNodeSource: Sendable {
    func children(of node: ScanNode) -> [ScanNode]
}

/// The children a finished scan's nodes already carry.
public struct SnapshotTreemapSource: TreemapNodeSource {
    public init() {}

    public func children(of node: ScanNode) -> [ScanNode] {
        node.isDirectory ? node.children : []
    }
}

/// The children the live tree holds now.
///
/// The tree is edited on the main actor and read here through its own lock, the
/// same way `CategoryFileIndex` walks it off the main actor.
public struct LiveTreemapSource: TreemapNodeSource {
    private let tree: LiveTree

    public init(_ tree: LiveTree) {
        self.tree = tree
    }

    public func children(of node: ScanNode) -> [ScanNode] {
        guard node.isDirectory, let id = tree.id(atPath: node.url.path) else { return [] }
        return tree.scanNodes(forChildrenOf: id) ?? []
    }
}

/// One box of the treemap.
struct TreemapTile: Identifiable, Equatable {
    /// What the box stands for, independent of where it is drawn: a node's path,
    /// or the parent of a folded group. A drill that moves a node out of a nested
    /// box into the whole chart keeps this key, so the chart moves the box
    /// instead of replacing it.
    let key: String
    let node: ScanNode?
    let remainderCount: Int
    /// 1 is the focused directory's entries.
    let depth: Int
    let rect: CGRect
    let fill: ChartFill
    let size: Int64
    /// Whether the box shows its own contents, and so keeps a header band for its
    /// own name.
    let isNested: Bool

    var id: String { key }

    var label: String {
        if let node { return node.name }
        return L10n.format("%lld smaller items", remainderCount)
    }
}

/// Builds the treemap's boxes from the focused directory's entries.
///
/// Every box's area is its share of the box that holds it, and the shares of one
/// group always add up to the whole: children are drawn largest first, the ones
/// that do not fit are folded into one aggregate that stands for exactly their
/// bytes, and nothing is rescaled to make the picture fill its frame. A folder
/// that is too small to show its own contents stays flat — it still stands for
/// its whole size, so that is a legibility choice, never a measurement.
enum TreemapLayout {

    /// A parent whose children are waiting to be laid out.
    private struct Pending {
        let nodes: [ScanNode]
        let rect: CGRect
        let depth: Int
        /// The path the remainder key is built from. The focused folder is the
        /// empty path, which is the same prefix `SunburstLayout` uses for ring 1,
        /// so an aggregate box and an aggregate wedge share one identity.
        let parentPath: String
    }

    /// The boxes the chart draws, parents before their children.
    static func tiles(
        nodes: [ScanNode],
        source: TreemapNodeSource,
        maxChildren: Int,
        in rect: CGRect,
        maxDepth: Int = DS.Treemap.maxDepth,
        maxTiles: Int = DS.Treemap.maxTiles
    ) -> [TreemapTile] {
        var out: [TreemapTile] = []
        out.reserveCapacity(256)
        guard rect.width > 0, rect.height > 0, !nodes.isEmpty else { return out }

        var pending: [Pending] = [Pending(nodes: nodes, rect: rect, depth: 1, parentPath: "")]
        while let parent = pending.popLast() {
            guard out.count < maxTiles else { break }
            guard let group = ChartGrouping.group(
                parent.nodes,
                maxChildren: maxChildren,
                slots: maxTiles - out.count,
                ring: parent.depth
            ) else { continue }

            // The area of each box is its share of the parent's whole. The
            // aggregate stands for the folded bytes, so the shares of one group
            // add up to its parent's rectangle exactly.
            let area = Double(parent.rect.width) * Double(parent.rect.height)
            guard area > 0 else { continue }
            var shares: [Double] = []
            shares.reserveCapacity(group.shown.count + (group.remainderSize > 0 ? 1 : 0))
            for node in group.shown {
                shares.append(area * Double(node.logicalSize) / Double(group.total))
            }
            if group.remainderSize > 0 {
                shares.append(area * Double(group.remainderSize) / Double(group.total))
            }
            guard !shares.isEmpty else { continue }

            let rects = squarify(shares, in: parent.rect)
            guard rects.count == shares.count else { continue }

            for (index, tileRect) in rects.enumerated() {
                if index < group.shown.count {
                    let node = group.shown[index]
                    // A big enough folder shows its own contents inside its box.
                    var children: [ScanNode]?
                    if node.isDirectory, parent.depth < maxDepth {
                        let content = Self.contentRect(of: tileRect)
                        if content.width >= DS.Treemap.nestingMinimumWidth,
                           content.height >= DS.Treemap.nestingMinimumHeight {
                            let nested = source.children(of: node)
                            if !nested.isEmpty { children = nested }
                        }
                    }
                    out.append(
                        TreemapTile(
                            key: node.url.path,
                            node: node,
                            remainderCount: 0,
                            depth: parent.depth,
                            rect: tileRect,
                            fill: group.fills[node.url.path] ?? .neutral,
                            size: node.logicalSize,
                            isNested: children != nil
                        )
                    )
                    if let children {
                        pending.append(
                            Pending(nodes: children, rect: Self.contentRect(of: tileRect),
                                    depth: parent.depth + 1, parentPath: node.url.path)
                        )
                    }
                } else {
                    out.append(
                        TreemapTile(
                            key: "remainder:\(parent.parentPath)",
                            node: nil,
                            remainderCount: group.remainderCount,
                            depth: parent.depth,
                            rect: tileRect,
                            fill: .aggregate,
                            size: group.remainderSize,
                            isNested: false
                        )
                    )
                }
            }
        }
        return out
    }

    /// The area inside a box that its own children fill: inset by the band that
    /// shows the box, and below the header band that names it.
    static func contentRect(of rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + DS.Treemap.innerPadding,
            y: rect.minY + DS.Treemap.headerHeight,
            width: rect.width - 2 * DS.Treemap.innerPadding,
            height: rect.height - DS.Treemap.headerHeight - DS.Treemap.innerPadding
        )
    }

    /// The deepest box that holds `point`, or nil outside every box.
    ///
    /// The boxes are in draw order, parents before their children, so the last
    /// match is the one painted on top.
    static func tile(at point: CGPoint, in tiles: [TreemapTile]) -> TreemapTile? {
        for tile in tiles.reversed() where tile.rect.contains(point) {
            return tile
        }
        return nil
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk): the boxes of one row are
    /// laid along the shorter side of the free space, and a row is closed as soon
    /// as adding another box would make its worst aspect ratio longer.
    ///
    /// `areas` are descending and add up to `rect`'s area; the result has one
    /// rectangle per area, in the same order, and together they tile `rect`.
    static func squarify(_ areas: [Double], in rect: CGRect) -> [CGRect] {
        guard !areas.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(areas.count)
        var free = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        var index = 0

        while index < areas.count {
            let short = Double(min(free.width, free.height))
            guard short > 0 else { break }
            // One more box joins the row while it does not make the row's worst
            // aspect ratio worse, which is what keeps the boxes close to square.
            var end = index + 1
            while end < areas.count,
                  worst(areas[index...end], short) <= worst(areas[index..<end], short) {
                end += 1
            }
            let row = areas[index..<end]
            let sum = row.reduce(0, +)
            guard sum > 0 else { break }

            if free.width >= free.height {
                // A column down the leading side; the row is stacked along the
                // shorter side.
                let width = min(sum / Double(free.height), Double(free.width))
                var y = Double(free.minY)
                for area in row {
                    let height = area / width
                    out.append(CGRect(x: Double(free.minX), y: y, width: width, height: height))
                    y += height
                }
                free = CGRect(x: free.minX + CGFloat(width), y: free.minY,
                              width: free.width - CGFloat(width), height: free.height)
            } else {
                let height = min(sum / Double(free.width), Double(free.height))
                var x = Double(free.minX)
                for area in row {
                    let width = area / height
                    out.append(CGRect(x: x, y: Double(free.minY), width: width, height: height))
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + CGFloat(height),
                              width: free.width, height: free.height - CGFloat(height))
            }
            index = end
        }
        return out
    }

    /// The worst aspect ratio a row laid along `short` would have.
    private static func worst(_ areas: ArraySlice<Double>, _ short: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard sum > 0, let largest = areas.max(), let smallest = areas.min(), smallest > 0 else {
            return .infinity
        }
        let square = short * short
        return max(square * largest / (sum * sum), (sum * sum) / (square * smallest))
    }
}
