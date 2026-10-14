import SwiftUI
import DiskCore

/// The one access notice: the Full Disk Access explanation and the restricted
/// locations it accounts for, merged into a single row.
///
/// Three weights, lightest last. Collapsed it is one line — a lock, the count
/// and a `Details` affordance — with no prose, button, or bordered well.
/// Expanded in place it explains why the locations were skipped, offers the
/// one system action that fixes it, and lists a bounded sample with the
/// truthful total. Once dismissed the row leaves the footer entirely and the
/// storage strip's count chip brings it back.
///
/// The notice is deliberately calm rather than an error: without Full Disk
/// Access a whole-volume scan is *expected* to skip TCC-protected locations,
/// and the scan itself still completed.
public struct AccessNoticeRow: View {
    public let presentation: ScanIssuesPresentation
    /// Whether Full Disk Access is already granted. When it is, the locations
    /// were skipped for some other reason, so no grant or CTA is offered.
    public let isFullDiskAccessGranted: Bool
    @Binding public var isExpanded: Bool
    public let onDismiss: () -> Void

    public init(
        presentation: ScanIssuesPresentation,
        isFullDiskAccessGranted: Bool,
        isExpanded: Binding<Bool>,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.isFullDiskAccessGranted = isFullDiskAccessGranted
        self._isExpanded = isExpanded
        self.onDismiss = onDismiss
    }

    /// Whether the notice accounts for access restrictions (the actionable
    /// case) rather than only other unreadable items.
    private var isAccessRestriction: Bool { presentation.isAccessRestriction }

    /// The noun the affordances use, so a fault-only notice never calls its
    /// findings restricted locations.
    private var detailNoun: String {
        isAccessRestriction ? "restricted locations" : "unreadable items"
    }

    private var explanation: String {
        if isAccessRestriction {
            // With the grant in place the locations were skipped for some other
            // reason, so the notice accounts for them without offering a grant
            // that is already held.
            return isFullDiskAccessGranted
                ? "Items inside them were skipped; these locations could not be read while scanning."
                : "Items inside them were skipped. Grant WillyDisk Full Disk Access in System Settings → Privacy & Security, then rescan."
        }
        return "These items could not be read while scanning."
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            header
            if isExpanded { expanded }
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: presentation.noticeSymbolName)
                .font(DS.Icon.inline)
                .foregroundStyle(isAccessRestriction ? DS.Color.secondaryText : DS.Color.warning)
                .accessibilityHidden(true)

            Text(presentation.noticeHeadline)
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.medium)

            Button(isExpanded ? "Hide" : "Details") {
                isExpanded.toggle()
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .accessibilityLabel(isExpanded ? "Hide \(detailNoun)" : "Show \(detailNoun)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Toggles the explanation and the list of \(detailNoun)")

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Hide this notice; the count stays on the storage strip")
            .accessibilityLabel("Dismiss the \(detailNoun) notice")
            .accessibilityHint("Removes the notice; a count chip on the storage strip reopens it")
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var expanded: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(explanation)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if isAccessRestriction && !isFullDiskAccessGranted {
                Button {
                    FullDiskAccessSettings.open()
                } label: {
                    Label("Open System Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                .help("Open System Settings → Privacy & Security → Full Disk Access")
                .accessibilityLabel("Open Full Disk Access in System Settings")
                .accessibilityHint("Opens the Full Disk Access pane in System Settings")
            }

            if presentation.hasRows {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.small) {
                        ForEach(presentation.rows) { issue in
                            AccessIssueRow(issue: issue)
                        }
                    }
                    .padding(.vertical, DS.Spacing.xSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: DS.Size.accessListMaxHeight)

                // The truthful accounting, read from `ScanSummary` totals — the
                // list itself never claims to be complete.
                Text(presentation.listSummaryText)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .padding(.leading, DS.Spacing.large)
    }
}

/// The tiny count chip the storage strip shows once the notice is dismissed.
///
/// It keeps the count on screen when the row is gone, and clicking it brings
/// the row back in its collapsed state. Its glyph and label follow the notice's
/// own kind, so a fault-only scan never reads as restricted locations.
public struct AccessNoticeChip: View {
    public let count: Int
    public let symbolName: String
    public let label: String
    public let action: () -> Void

    public init(count: Int, symbolName: String, label: String, action: @escaping () -> Void) {
        self.count = count
        self.symbolName = symbolName
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xSmall) {
                Image(systemName: symbolName)
                    .font(DS.Icon.detail)
                Text("\(count)")
                    .font(DS.Typography.caption)
                    .monospacedDigit()
            }
            .foregroundStyle(DS.Color.secondaryText)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xxSmall)
            .background(DS.Color.controlBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint("Shows the access notice")
    }
}

/// One restricted/failed location. A permission denial is presented neutrally
/// (it is expected without Full Disk Access), not as a failure.
private struct AccessIssueRow: View {
    let issue: ScanIssue

    private var isAccessRestriction: Bool { issue.kind == .permissionDenied }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            Image(systemName: isAccessRestriction ? "lock.fill" : "exclamationmark.triangle")
                .font(DS.Icon.detail)
                .foregroundStyle(isAccessRestriction ? DS.Color.tertiaryText : DS.Color.warning)
                .frame(width: DS.Size.legendSwatch + DS.Spacing.xSmall)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(issue.path)
                    .font(DS.Typography.monospaced)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(issue.message)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
