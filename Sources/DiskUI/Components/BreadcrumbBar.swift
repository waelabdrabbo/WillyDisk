import SwiftUI
import DiskCore

/// A horizontal breadcrumb trail for chart/explorer navigation.
///
/// Each crumb is a button that jumps the navigation back to that ancestor. The
/// trail is scrollable when it grows too long to fit.
public struct BreadcrumbBar: View {
    /// The path from the root to the current node (inclusive). Empty means root.
    private let path: [ScanNode]
    private let rootName: String
    private let onSelect: (Int) -> Void

    public init(path: [ScanNode], rootName: String, onSelect: @escaping (Int) -> Void) {
        self.path = path
        self.rootName = rootName
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xSmall) {
                crumb(rootName, index: -1)

                ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                    Image(systemName: "chevron.right")
                        .font(DS.Icon.crumb)
                        .foregroundStyle(DS.Color.tertiaryText)
                    crumb(node.name, index: index)
                }
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xSmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func crumb(_ title: String, index: Int) -> some View {
        Button {
            onSelect(index)
        } label: {
            Text(title)
                .font(DS.Typography.callout)
                .foregroundStyle(index == path.count - 1 ? DS.Color.primaryText : DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.xSmall)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(index == -1 ? rootName : path[index].url.path)
        .accessibilityLabel(index == -1 ? "Back to root" : title)
    }
}
