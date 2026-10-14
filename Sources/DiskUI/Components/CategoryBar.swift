import SwiftUI
import DiskCore

/// A slim horizontal stacked bar showing storage distribution by
/// `FileCategory`, with an inline legend. Reads real data from `ScanSummary`.
///
/// Sized to sit as a full-width strip at the end of the results screen: a
/// thin bar over a single wrapping legend line, with no card or bordered well.
public struct CategoryBar: View {
    private let breakdown: [FileCategory: Int64]
    private let total: Int64

    public init(breakdown: [FileCategory: Int64], total: Int64) {
        self.breakdown = breakdown
        self.total = total
    }

    fileprivate struct Entry: Identifiable {
        let category: FileCategory
        let size: Int64
        var id: FileCategory { category }
    }

    private var entries: [Entry] {
        breakdown
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { Entry(category: $0.key, size: $0.value) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            bar
            FlowLegend(entries: entries)
        }
    }

    /// The stacked bar itself. Each category's width is its share of the
    /// total logical size, so the strip always accounts for every byte.
    private var bar: some View {
        GeometryReader { geo in
            let unit = total > 0 ? geo.size.width / Double(total) : 0
            HStack(spacing: 0) {
                ForEach(entries) { entry in
                    Rectangle()
                        .fill(entry.category.tint)
                        .frame(width: max(CGFloat(Double(entry.size) * unit), 0))
                }
            }
        }
        .frame(height: DS.Size.storageBarHeight)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Storage distribution by category")
    }
}

/// A wrapping legend of colored swatches + labels + sizes.
///
/// Each entry is laid out at its own width, so a long category name and a wide
/// size string sit on one line instead of competing for a shared column.
private struct FlowLegend: View {
    let entries: [CategoryBar.Entry]

    var body: some View {
        FlowLayout(horizontalSpacing: DS.Spacing.large, verticalSpacing: DS.Spacing.xSmall) {
            ForEach(entries) { entry in
                legendEntry(entry)
            }
        }
    }

    private func legendEntry(_ entry: CategoryBar.Entry) -> some View {
        HStack(spacing: DS.Spacing.xSmall) {
            Circle()
                .fill(entry.category.tint)
                .frame(width: DS.Size.legendSwatch, height: DS.Size.legendSwatch)
            Text(entry.category.displayName)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                // The name is the entry's variable part; it stays on one line and
                // shortens from the tail rather than splitting a word.
                .lineLimit(1)
                .truncationMode(.tail)
            Text(ByteFormat.string(entry.size))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}
