import SwiftUI
import DiskCore

/// Explains what a scan counted, what it skipped, and why its total is not the
/// volume's used space.
///
/// The sheet is deliberately an explanation, not a percentage: reconciling a
/// folder scan to a volume by subtraction would invent a number the engine never
/// measured. The volume's own facts and the scan's own facts sit next to each
/// other, labelled.
struct CoverageSheet: View {
    let summary: ScanSummary
    let isLive: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var volume: VolumeFacts?
    @State private var snapshots: LocalSnapshots?
    @State private var didLoad = false

    /// Provenance for previews and tests: supplying the system's answers skips
    /// the probe instead of showing "Checking…" forever under a static renderer.
    init(
        summary: ScanSummary,
        isLive: Bool,
        volume: VolumeFacts? = nil,
        snapshots: LocalSnapshots? = nil
    ) {
        self.summary = summary
        self.isLive = isLive
        _volume = State(initialValue: volume)
        _snapshots = State(initialValue: snapshots)
        _didLoad = State(initialValue: volume != nil || snapshots != nil)
    }

    private var report: CoverageReport {
        CoverageReport(
            summary: summary,
            volume: volume,
            snapshots: snapshots,
            isLive: isLive
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            header

            HStack(alignment: .top, spacing: DS.Spacing.xxLarge) {
                VStack(alignment: .leading, spacing: DS.Spacing.xLarge) {
                    section("Scanned", rows: report.scanned)
                    section("This volume", rows: report.volume)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: DS.Spacing.xLarge) {
                    snapshotSection
                    section("Counted more than once, or not at all", rows: report.limits)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The limit of the comparison belongs on screen, not below a scroll.
            scopeSection

            Divider()

            HStack {
                if isLive {
                    Label("Totals are still growing", systemImage: "hourglass")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .frame(minWidth: DS.Size.actionMinWidth)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Spacing.xxLarge)
        .frame(width: 780)
        .tint(DS.Color.signal)
        .task {
            guard !didLoad else { return }
            didLoad = true
            async let facts = VolumeFactsProbe.facts(for: summary.root)
            async let snapshotList = SnapshotProbe.list(onVolumeAt: summary.root)
            volume = await facts
            snapshots = await snapshotList
        }
    }

    /// The scan's own age, so the live volume facts below are never mistaken
    /// for a measurement taken at the same moment as the totals.
    private var provenance: String {
        if isLive {
            return "Scan started \(DateFormat.short(summary.startedAt)); the totals are still growing"
        }
        return ScanProvenance.settled(startedAt: summary.startedAt, finishedAt: summary.finishedAt)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: "info.circle")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                Text("What this scan counted")
                    .font(DS.Typography.title2)
                Text(PathFormat.abbreviated(summary.root.path, maxLength: 90))
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(provenance)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
    }

    private func section(_ title: String, rows: [CoverageRow]) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        }
    }

    private func rowView(_ row: CoverageRow) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.medium) {
                Text(row.label)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 152, alignment: .leading)
                Text(row.value)
                    .font(DS.Typography.callout)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            if let detail = row.detail {
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionLabel("Snapshots")
            rowView(report.snapshots)
            if !report.snapshotNames.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                    ForEach(report.snapshotNames.prefix(3), id: \.self) { name in
                        Text(name)
                            .font(DS.Typography.monospaced)
                            .foregroundStyle(DS.Color.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if report.snapshotNames.count > 3 {
                        Text("and \(report.snapshotNames.count - 3) more")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
            }
        }
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Divider()
            Text(report.scopeNote)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let note = report.startupDiskNote {
                Text(note)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
