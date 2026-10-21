import SwiftUI
import DiskCore

/// The one access notice: the Full Disk Access explanation and the restricted
/// locations it accounts for, merged into a single row.
///
/// The row is always one line — a lock, the count, a `Details` affordance, and
/// a dismiss control. `Details` opens a popover that explains why the locations
/// were skipped, offers the one system action that fixes it, and lists a bounded
/// sample with the truthful total. The row is always present while the scan
/// reports anything; there is no dismiss control.
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

    public init(
        presentation: ScanIssuesPresentation,
        isFullDiskAccessGranted: Bool,
        isExpanded: Binding<Bool>
    ) {
        self.presentation = presentation
        self.isFullDiskAccessGranted = isFullDiskAccessGranted
        self._isExpanded = isExpanded
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
        header
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A hairline along the top edge marks the notice as a separate band
            // from the panes above it, rather than one more row of the content.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(DS.Color.separator)
                    .frame(height: DS.Stroke.hairline)
            }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: presentation.noticeSymbolName)
                .font(DS.Icon.inline)
                .foregroundStyle(isAccessRestriction ? DS.Color.secondaryText : DS.Color.warning)
                .accessibilityHidden(true)

            Text(presentation.noticeHeadline)
                .font(DS.Typography.body)
                .fontWeight(.light)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)

            Spacer(minLength: DS.Spacing.medium)

            // The notice's one action follows the app accent, like the other
            // inline affordances.
            InlineActionButton("Details") {
                isExpanded = true
            }
            .popover(isPresented: $isExpanded, arrowEdge: .top) {
                detailsPopover
            }
            .accessibilityLabel("Show \(detailNoun)")
            .accessibilityHint("Opens the explanation and the list of \(detailNoun)")
        }
        .accessibilityElement(children: .contain)
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(presentation.noticeHeadline)
                .font(DS.Typography.body)
                .fontWeight(.bold)
                .foregroundStyle(DS.Color.primaryText)

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
                .frame(maxHeight: DS.Size.accessListMaxHeight + DS.Spacing.xxLarge)

                // The truthful accounting, read from `ScanSummary` totals — the
                // list itself never claims to be complete.
                Text(presentation.listSummaryText)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .padding(DS.Spacing.large)
        .frame(width: 460)
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
                .foregroundStyle(isAccessRestriction ? DS.Color.secondaryText : DS.Color.warning)
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
