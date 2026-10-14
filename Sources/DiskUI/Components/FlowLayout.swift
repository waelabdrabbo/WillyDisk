import SwiftUI

/// A wrapping layout: items are placed left to right at the width their own
/// content asks for, and start a new row when the next one no longer fits.
///
/// Use it wherever the labels vary in length. A grid of equal-width columns
/// sizes every column from a fixed minimum, which can leave a label narrower
/// than the text it holds; here an item is never narrowed below its intrinsic
/// width. The widest item decides how many fit on a row, and an item that cannot
/// fit the container truncates itself instead of overflowing.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = DS.Spacing.small
    var verticalSpacing: CGFloat = DS.Spacing.small

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Groups items into rows that fit `maxWidth`. An item wider than the whole
    /// container gets a row of its own and is measured at `maxWidth`, so it stays
    /// inside its bounds rather than spilling out of them.
    private func rows(for sizes: [CGSize], maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, size) in sizes.enumerated() {
            let width = min(size.width, maxWidth)
            let advance = row.indices.isEmpty ? width : horizontalSpacing + width
            if !row.indices.isEmpty, row.width + advance > maxWidth {
                rows.append(row)
                row = Row(indices: [index], width: width, height: size.height)
            } else {
                row.indices.append(index)
                row.width += advance
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(for: sizes, maxWidth: maxWidth)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(0) { $0 + $1.height }
            + verticalSpacing * CGFloat(rows.count - 1)
        // A proposed width is honoured as-is; without one, the layout reports the
        // width its widest row needs, the way a text block reports its own size.
        let width = proposal.width ?? (rows.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(for: sizes, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let width = min(sizes[index].width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: sizes[index].height)
                )
                x += width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }
}
