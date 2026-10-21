import SwiftUI
import DiskCore

/// Where a scan's bytes sit, by file category.
///
/// The sunburst shows the same scan as a tree; this cuts it the other way, so a
/// home folder that is mostly video reads that way in one glance. Choosing a row
/// applies the explorer's category filter — it narrows the list, it never changes
/// a total.
@MainActor
public struct CategoryBreakdownSheet: View {
    private let breakdown: CategoryBreakdown
    private let rootName: String
    private let scannedAt: Date
    private let selected: FileCategory?
    private let onSelect: (FileCategory?) -> Void
    private let onClose: () -> Void

    public init(
        breakdown: CategoryBreakdown,
        rootName: String,
        scannedAt: Date,
        selected: FileCategory?,
        onSelect: @escaping (FileCategory?) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.breakdown = breakdown
        self.rootName = rootName
        self.scannedAt = scannedAt
        self.selected = selected
        self.onSelect = onSelect
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if breakdown.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                    ForEach(breakdown.shares) { share in
                        CategoryShareRow(
                            share: share,
                            isSelected: selected == share.category,
                            onSelect: {
                                onSelect(share.category)
                                onClose()
                            }
                        )
                    }
                }
                .padding(DS.Spacing.xxLarge)
            }

            Divider()
            footer
        }
        .frame(width: 560)
        .background(DS.Color.windowBackground)
        .tint(DS.Color.signal)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: "chart.pie")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                Text("Where the bytes are")
                    .font(DS.Typography.title2)
                Text(rootName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Logical size of files · scanned \(DateFormat.short(scannedAt))")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xxLarge)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: "chart.pie")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.mutedText)
            Text("No file bytes to group yet")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.section)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Hard links count once per link, and dataless files at their logical size; Coverage explains what the total leaves out. Choosing a category filters the explorer.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if selected != nil {
                    Button("Show All Categories") {
                        onSelect(nil)
                        onClose()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Clears the category filter")
                }
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(.horizontal, DS.Spacing.xxLarge)
        .padding(.vertical, DS.Spacing.large)
    }
}

/// One category: its symbol, size, whole-percent share, and a bar drawn against
/// the scan's whole.
private struct CategoryShareRow: View {
    let share: CategoryShare
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    private var percentText: String { PercentFormat.ofWhole(share.share) }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: DS.Spacing.medium) {
                Image(systemName: share.category.symbolName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: DS.Spacing.xLarge, alignment: .center)

                VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                        Text(share.category.displayName)
                            .font(DS.Typography.callout)
                            .foregroundStyle(DS.Color.primaryText)
                        Spacer(minLength: DS.Spacing.small)
                        Text(ByteFormat.string(share.logicalSize))
                            .font(DS.Typography.figures)
                            .foregroundStyle(DS.Color.primaryText)
                        Text(percentText)
                            .font(DS.Typography.figures)
                            .foregroundStyle(DS.Color.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }

                    shareBar
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(DS.Icon.detail)
                    .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.secondaryText)
                    .frame(width: DS.Spacing.large, alignment: .center)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.small)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(isHovered ? DS.Color.accent.opacity(DS.Opacity.rowHover) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(share.category.displayName), \(ByteFormat.string(share.logicalSize)), \(percentText)")
        .accessibilityHint("Filters the explorer to this category")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The bar is a share of the scan's whole, so its length means the same thing
    /// as the percentage beside it; a slice too small to draw keeps two points so
    /// the row still shows there is something there.
    private var shareBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.rule.opacity(0.7))
                Capsule()
                    .fill(isSelected ? DS.Color.accent : DS.Color.graphite)
                    .frame(width: max(2, geometry.size.width * share.share))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
