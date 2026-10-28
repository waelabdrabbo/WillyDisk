import DiskCore

/// The children of one directory that a chart draws, and the remainder it folds.
///
/// The sunburst and the treemap draw the same tree at the same density: the
/// largest children are drawn individually and every other child is folded into
/// one aggregate that stands for exactly their bytes. Deciding that here, once,
/// is what keeps the two charts from disagreeing about what is on screen, what
/// the aggregate says, and the fill they give an entry they share.
struct ChartGroup {
    /// The bytes of every presentable child, drawn or folded.
    let total: Int64
    /// The children drawn individually, largest first.
    let shown: [ScanNode]
    /// How many children the aggregate stands for.
    let remainderCount: Int
    /// The bytes the aggregate stands for; zero when nothing was folded.
    let remainderSize: Int64
    /// The chart fill of every child of the parent, keyed by path, whether it is
    /// drawn or folded. Both charts read it, so a node's colour survives a change
    /// of chart.
    let fills: [String: ChartFill]
}

/// Decides which of a directory's children a chart draws.
///
/// The rule is deliberately a function of count rather than of geometry: the
/// chart's density follows the explorer's page, so paging the list with Show More
/// reveals more of the chart too. Geometry decides only whether a box is big
/// enough to show its own children (a treemap), never what is measured.
enum ChartGrouping {
    /// The group a parent's children make at `maxChildren` density, using at most
    /// `slots` drawn shapes. `slots` is what is left of the chart's ceiling, and
    /// it covers the aggregate as well as the individual children: when one slot
    /// is left, the whole group is folded into it rather than drawn as a wedge
    /// with no room for what it hid.
    ///
    /// Returns nil when the parent has nothing to draw: no presentable child, no
    /// bytes, or no slots left.
    static func group(
        _ children: [ScanNode],
        maxChildren: Int,
        slots: Int,
        ring: Int
    ) -> ChartGroup? {
        let ordered = children
            .filter(\.isPresentable)
            .sorted { $0.logicalSize > $1.logicalSize }
        guard !ordered.isEmpty else { return nil }

        let total = ordered.reduce(Int64(0)) { $0 + $1.logicalSize }
        guard total > 0, slots > 0 else { return nil }

        // A parent whose children do not all fit needs a slot for the aggregate
        // as well as for the children it draws; when only that slot is left the
        // whole group is drawn as the one aggregate.
        var shownCount = min(min(ordered.count, maxChildren), slots)
        if ordered.count > shownCount {
            shownCount = min(shownCount, slots - 1)
        }

        let shown = Array(ordered.prefix(max(shownCount, 0)))
        let shownTotal = shown.reduce(Int64(0)) { $0 + $1.logicalSize }

        // Tone ranks the siblings by path, not by size, and ranks every child the
        // parent holds — including one whose bytes have not been counted yet. A
        // sibling arriving during a scan therefore takes a place of its own
        // instead of moving the tones already on screen.
        let fills = ChartPalette.fills(for: children, ring: ring)

        return ChartGroup(
            total: total,
            shown: shown,
            remainderCount: ordered.count - shown.count,
            remainderSize: total - shownTotal,
            fills: fills
        )
    }
}
