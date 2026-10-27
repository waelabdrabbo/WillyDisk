import SwiftUI
import DiskCore
import DiskLocalization

/// Compares the recorded runs of one scanned location.
///
/// Two records are chosen from the list; the pane beside it states what the
/// later run measured against the earlier one. The sheet never claims that a
/// scan's growth or shrinkage is space gained or recovered — a smaller scan is a
/// smaller measurement, and the Trash is still where bytes are until it is
/// emptied.
@MainActor
public struct HistorySheet: View {
    private let history: ScanHistory
    private let root: URL
    private let rootName: String

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var isConfirmingClear = false

    public init(history: ScanHistory, root: URL, rootName: String) {
        self.history = history
        self.root = root
        self.rootName = rootName
    }

    private var records: [ScanRecord] {
        history.records(for: root)
    }

    private var comparison: ScanComparison? {
        let chosen = records.filter { selected.contains($0.id) }
        guard chosen.count == 2 else { return nil }
        // `records` is newest first, so the second of the pair is the earlier run.
        return ScanComparison.between(chosen[1], chosen[0])
    }

    /// The capacity both runs kept, when they agree, so the sheet can state a
    /// real number. A record written by a release with a different capacity is
    /// named without one instead of borrowing the wrong figure.
    private var entryCapacityPhrase: String {
        guard let comparison else {
            return L10n.format("each run's largest %lld", ScanRecord.currentEntryCapacity)
        }
        guard comparison.earlier.entryCapacity == comparison.later.entryCapacity else {
            return L10n.string("the largest entries each run recorded")
        }
        return L10n.format("each run's largest %lld", comparison.later.entryCapacity)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .dsFittedFrame(width: 900, height: 680)
        .background(DS.Color.windowBackground)
        .tint(DS.Color.signal)
        .task {
            await history.reload()
            ensureSelection()
        }
        .onChange(of: history.snapshot.records.map(\.id)) { _, _ in
            ensureSelection()
        }
        .confirmationDialog(L10n.string("Clear scan history?"), isPresented: $isConfirmingClear) {
            Button(L10n.string("Clear History"), role: .destructive) {
                Task {
                    await history.clear()
                    selected = []
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("Every recorded run, for every location, is removed. Your files are not touched."))
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: "clock.arrow.circlepath")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                Text(L10n.string("Scan History"))
                    .font(DS.Typography.title2)
                Text(rootName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xxLarge)
    }

    private var subtitle: String {
        guard !records.isEmpty else {
            return L10n.string("A scan is recorded when it finishes. Cancelled scans are not: their totals cover only part of the folder.")
        }
        return L10n.format(
            "%@. Choose two to compare. Records stay on this Mac.",
            L10n.format("%lld recorded runs", records.count)
        )
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.medium) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                if comparison != nil {
                    Text(L10n.format("Totals are exact. Folders and files are %@, matched by path. No savings are claimed.", entryCapacityPhrase))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = history.writeFailure {
                    Text(L10n.format("History could not be written: %@", failure))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if history.snapshot.skippedCount > 0 {
                    Text(skippedNote)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Button(L10n.string("Clear History…")) {
                isConfirmingClear = true
            }
            .disabled(records.isEmpty)
            .help(L10n.string("Removes every recorded run. Your files are not touched."))

            Button {
                dismiss()
            } label: {
                Text(L10n.string("Done"))
                    .frame(minWidth: DS.Size.actionMinWidth)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.xxLarge)
        .padding(.vertical, DS.Spacing.large)
    }

    private var skippedNote: String {
        return L10n.format(
            "%@ and are not shown.",
            L10n.format("%lld stored files could not be read", history.snapshot.skippedCount)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            if history.isLoading {
                loading
            } else {
                emptyState
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                runsList
                    .frame(width: 286)
                Divider()
                comparisonPane
            }
        }
    }

    private var loading: some View {
        VStack(spacing: DS.Spacing.medium) {
            ProgressView()
            Text(L10n.string("Reading the scan history…"))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "clock")
                .font(DS.Icon.large)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            Text(L10n.string("No recorded runs"))
                .font(DS.Typography.title2)
            Text(L10n.string("Scan this location again and its runs will be listed here, side by side."))
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.xxLarge)
    }

    // MARK: - Runs

    private var runsList: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionLabel(L10n.string("Runs"), rule: true)
            ScrollView {
                LazyVStack(spacing: DS.Spacing.xxSmall) {
                    ForEach(records) { record in
                        runRow(record)
                    }
                }
                .padding(.vertical, DS.Spacing.xxSmall)
            }
        }
        .padding(DS.Spacing.xLarge)
    }

    private func runRow(_ record: ScanRecord) -> some View {
        let isSelected = selected.contains(record.id)
        return Button {
            toggle(record.id)
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.small) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(DS.Typography.callout)
                    .foregroundStyle(isSelected ? DS.Color.signal : DS.Color.rule)
                    .padding(.top, DS.Spacing.xxSmall)
                VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                    Text(DateFormat.short(record.finishedAt))
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.primaryText)
                    Text(runDetail(record))
                        .font(DS.Typography.metadataFigures)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.small)
            .contentShape(Rectangle())
            .background(
                isSelected ? DS.Color.signal.opacity(DS.Opacity.rowSelection) : Color.clear,
                in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("Run from %@", DateFormat.short(record.finishedAt)))
        .accessibilityValue(L10n.format(
            "%@, %@. %@",
            ByteFormat.string(record.totalLogicalSize),
            CountFormat.files(record.fileCount),
            L10n.string(isSelected ? "Selected for comparison" : "Not selected")
        ))
        .help(L10n.string(isSelected ? "Click to remove this run from the comparison" : "Click to compare this run"))
    }

    private func runDetail(_ record: ScanRecord) -> String {
        L10n.format(
            "%@ · %@ · %@",
            ByteFormat.string(record.totalLogicalSize),
            CountFormat.files(record.fileCount),
            DateFormat.duration(record.duration)
        )
    }

    // MARK: - Comparison

    @ViewBuilder
    private var comparisonPane: some View {
        if let comparison {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xLarge) {
                    comparisonHeader(comparison)
                    if comparison.optionsDiffer {
                        optionsWarning
                    }
                    metricStrip(comparison)
                    entriesSection(
                        L10n.string("Folders that changed"),
                        entries: folderChanges(comparison),
                        unchanged: folderUnchanged(comparison),
                        dropped: comparison.droppedDirectoryCount,
                        uncompared: comparison.uncomparedDirectoryCount,
                        cutOff: comparison.earlierDirectoryCutOff
                    )
                    entriesSection(
                        L10n.string("Files that changed"),
                        entries: comparison.changedFiles,
                        unchanged: comparison.files.count - comparison.changedFiles.count,
                        dropped: comparison.droppedFileCount,
                        uncompared: comparison.uncomparedFileCount,
                        cutOff: comparison.earlierFileCutOff
                    )
                    categorySection(comparison)
                    caveat(comparison)
                }
                .padding(DS.Spacing.xLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            pickTwo
        }
    }

    private var pickTwo: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "rectangle.split.2x1")
                .font(DS.Icon.large)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            Text(L10n.string(records.count == 1 ? "One run recorded" : "Choose two runs"))
                .font(DS.Typography.title2)
            Text(L10n.string(records.count == 1
                 ? "A comparison needs two runs of this location. Scan it again and the two will be compared here."
                 : "Select two runs in the list to see what grew, what shrank, and what appeared."))
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.xxLarge)
    }

    private func comparisonHeader(_ comparison: ScanComparison) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
            Text(L10n.format("%@  →  %@", DateFormat.short(comparison.earlier.finishedAt), DateFormat.short(comparison.later.finishedAt)))
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Color.primaryText)
            Text(L10n.format(
                "%@ apart. The earlier run took %@, the later run %@.",
                apart(comparison),
                DateFormat.duration(comparison.earlier.duration),
                DateFormat.duration(comparison.later.duration)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func apart(_ comparison: ScanComparison) -> String {
        let interval = comparison.later.finishedAt.timeIntervalSince(comparison.earlier.finishedAt)
        if interval < 60 { return L10n.string("Under a minute") }
        if interval < 3_600 { return L10n.format("%lld minutes", Int(interval / 60)) }
        if interval < 86_400 { return L10n.format("%lld hours", Int(interval / 3_600)) }
        return L10n.format("%lld days", Int(interval / 86_400))
    }

    private var optionsWarning: some View {
        HStack(alignment: .top, spacing: DS.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Color.warning)
                .accessibilityHidden(true)
            Text(L10n.string("These runs used different scan options. Some of the difference may be what each scan included — hidden items, other volumes, or excluded paths — rather than a change on disk."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.warning.opacity(DS.Opacity.contentPanel), in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }

    // MARK: - Totals

    /// The exact answers, side by side: a scan measures everything it walks, so
    /// these differences need no cut-off notice.
    private func metricStrip(_ comparison: ScanComparison) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.large) {
            metricTile(
                L10n.string("Size"),
                earlier: ByteFormat.string(comparison.earlier.totalLogicalSize),
                later: ByteFormat.string(comparison.later.totalLogicalSize),
                delta: ByteFormat.string(abs(comparison.totalLogicalDelta)),
                direction: comparison.totalLogicalDelta
            )
            metricTile(
                L10n.string("Allocated"),
                earlier: ByteFormat.string(comparison.earlier.totalAllocatedSize),
                later: ByteFormat.string(comparison.later.totalAllocatedSize),
                delta: ByteFormat.string(abs(comparison.totalAllocatedDelta)),
                direction: comparison.totalAllocatedDelta
            )
            metricTile(
                L10n.string("Files"),
                earlier: comparison.earlier.fileCount.formatted(),
                later: comparison.later.fileCount.formatted(),
                delta: abs(comparison.fileCountDelta).formatted(),
                direction: Int64(comparison.fileCountDelta)
            )
            metricTile(
                L10n.string("Folders"),
                earlier: comparison.earlier.directoryCount.formatted(),
                later: comparison.later.directoryCount.formatted(),
                delta: abs(comparison.directoryCountDelta).formatted(),
                direction: Int64(comparison.directoryCountDelta)
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func metricTile(
        _ label: String,
        earlier: String,
        later: String,
        delta: String,
        direction: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Text(L10n.format("%@ → %@", earlier, later))
                .font(DS.Typography.metadataFigures)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(changeText(delta, direction: direction))
                .font(DS.Typography.metadataFigures)
                .foregroundStyle(direction == 0 ? DS.Color.secondaryText : DS.Color.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@: %@ earlier, %@ later, %@", label, earlier, later, changeText(delta, direction: direction)))
    }

    private var columnHeader: some View {
        HStack(spacing: DS.Spacing.medium) {
            Spacer(minLength: DS.Spacing.small)
            Text(L10n.string("Earlier")).frame(width: 84, alignment: .trailing)
            Text(L10n.string("Later")).frame(width: 84, alignment: .trailing)
            Text(L10n.string("Change")).frame(width: 104, alignment: .trailing)
        }
        .font(DS.Typography.caption)
        .foregroundStyle(DS.Color.secondaryText)
        .accessibilityHidden(true)
    }

    private func changeText(_ delta: String, direction: Int64) -> String {
        if direction == 0 { return L10n.string("No change") }
        return L10n.format(direction > 0 ? "+%@" : "−%@", delta)
    }

    // MARK: - Categories

    private func categorySection(_ comparison: ScanComparison) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionLabel(L10n.string("By category"), rule: true)
            columnHeader
            ForEach(comparison.categories) { change in
                HStack(spacing: DS.Spacing.medium) {
                    HStack(spacing: DS.Spacing.xSmall) {
                        Image(systemName: change.category.symbolName)
                            .accessibilityHidden(true)
                        Text(change.category.displayName)
                    }
                    .foregroundStyle(DS.Color.secondaryText)
                    Spacer(minLength: DS.Spacing.small)

                    Text(ByteFormat.string(change.earlier))
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(DS.Color.secondaryText)
                    Text(ByteFormat.string(change.later))
                        .frame(width: 84, alignment: .trailing)
                        .foregroundStyle(DS.Color.primaryText)
                    Text(changeText(ByteFormat.string(abs(change.delta)), direction: change.delta))
                        .frame(width: 104, alignment: .trailing)
                        .foregroundStyle(change.delta == 0 ? DS.Color.secondaryText : DS.Color.primaryText)
                }
                .font(DS.Typography.metadataFigures)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.format(
                    "%@: %@ earlier, %@ later, %@",
                    change.category.displayName,
                    ByteFormat.string(change.earlier),
                    ByteFormat.string(change.later),
                    changeText(ByteFormat.string(abs(change.delta)), direction: change.delta)
                ))
            }
        }
    }

    // MARK: - Entries

    private func entriesSection(
        _ title: String,
        entries: [ScanComparison.Entry],
        unchanged: Int,
        dropped: Int,
        uncompared: Int,
        cutOff: Int64?
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            SectionLabel(title, rule: true)
            if entries.isEmpty {
                Text(unchanged > 0
                     ? L10n.format("Nothing changed: all %@ in both lists are the same size.", CountFormat.entries(unchanged))
                     : L10n.string("No entry changed."))
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                ForEach(entries) { entry in
                    entryRow(entry, cutOff: cutOff)
                }
            }
            if unchanged > 0, !entries.isEmpty {
                Text(L10n.format("%lld entries are unchanged.", unchanged))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            if dropped > 0 {
                Text(L10n.format(
                    "%lld entries from the earlier list are not in the later one.",
                    dropped
                ))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            if uncompared > 0 {
                Text(L10n.format(
                    "%lld entries in the later list are at or below the earlier list's cut-off, so they are not compared.",
                    uncompared
                ))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The scanned root answers "how big is this location", which the strip above
    /// already states exactly; listing it again as a changed folder would repeat
    /// the same number under a second heading.
    private func folderChanges(_ comparison: ScanComparison) -> [ScanComparison.Entry] {
        let rootPath = root.standardizedFileURL.path
        return comparison.changedDirectories.filter { $0.path != rootPath }
    }

    private func folderUnchanged(_ comparison: ScanComparison) -> Int {
        let rootPath = root.standardizedFileURL.path
        let unchanged = comparison.directories.filter { $0.change == .unchanged && $0.path != rootPath }
        return unchanged.count
    }

    private func entryRow(_ entry: ScanComparison.Entry, cutOff: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
            changeChip(entry.change)
            Text(entry.name)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            let parent = parentPath(entry.path)
            if !parent.isEmpty {
                Text(parent)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Spacer(minLength: DS.Spacing.small)
            Text(sizeTransition(entry))
                .font(DS.Typography.metadataFigures)
                .foregroundStyle(DS.Color.secondaryText)
            Text(changeText(ByteFormat.string(abs(entry.delta)), direction: entry.delta))
                .font(DS.Typography.metadataFigures)
                .foregroundStyle(entry.change == .unchanged ? DS.Color.secondaryText : DS.Color.primaryText)
                .frame(width: 88, alignment: .trailing)
        }
        .help(entryHelp(entry, cutOff: cutOff))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format(
            "%@ %@, %@, %@",
            changeLabel(entry.change),
            entry.name,
            sizeTransition(entry),
            changeText(ByteFormat.string(abs(entry.delta)), direction: entry.delta)
        ))
    }

    private func entryHelp(_ entry: ScanComparison.Entry, cutOff: Int64?) -> String {
        guard entry.change == .new else { return entry.path }
        let earlierCapacity = comparison?.earlier.entryCapacity ?? ScanRecord.currentEntryCapacity
        if let cutOff {
            return L10n.format(
                "%@ — absent from the earlier run's top %lld, which held entries down to %@. It is larger than that cut-off, so it would have been listed had it existed.",
                entry.path,
                earlierCapacity,
                ByteFormat.string(cutOff)
            )
        }
        return L10n.format(
            "%@ — absent from the earlier run's list, which held every entry it found.",
            entry.path
        )
    }

    private func sizeTransition(_ entry: ScanComparison.Entry) -> String {
        guard let earlier = entry.earlierSize else { return ByteFormat.string(entry.laterSize) }
        return L10n.format("%@ → %@", ByteFormat.string(earlier), ByteFormat.string(entry.laterSize))
    }

    /// The English label on `ScanComparison.Change` is a data value; the chip
    /// spells it in the interface language here.
    private func changeLabel(_ change: ScanComparison.Change) -> String {
        switch change {
        case .new: L10n.string("New")
        case .grown: L10n.string("Grown")
        case .shrunk: L10n.string("Shrunk")
        case .unchanged: L10n.string("Unchanged")
        }
    }

    private func changeChip(_ change: ScanComparison.Change) -> some View {
        let tint: Color = switch change {
        case .new: DS.Color.signal
        case .grown, .shrunk: DS.Color.primaryText
        case .unchanged: DS.Color.mutedText
        }
        return Text(changeLabel(change))
            .font(DS.Typography.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xxSmall)
            .background(tint.opacity(DS.Opacity.rowHover), in: Capsule())
            .fixedSize()
    }

    private func parentPath(_ path: String) -> String {
        let rootPath = root.standardizedFileURL.path
        let relative: String
        if path == rootPath {
            relative = ""
        } else if path.hasPrefix(rootPath + "/") {
            relative = String(path.dropFirst(rootPath.count + 1))
        } else {
            relative = PathFormat.abbreviated(path, maxLength: 60)
        }
        guard let slash = relative.lastIndex(of: "/") else { return "" }
        return String(relative[..<slash])
    }

    // MARK: - Caveat

    private func caveat(_ comparison: ScanComparison) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Divider()
            Text(L10n.format("Totals and categories are exact: a scan measures every entry it scanned. Folders and files are %@, matched by path. An entry is marked New only when the earlier run would have recorded it: it is absent from a list that held everything it found, or larger than a truncated list's cut-off. A later entry at or below that cut-off is not compared.", entryCapacityPhrase))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.string("Nothing here saves space. A smaller scan means less was measured; space returns when the Trash is emptied."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Selection

    /// Keeps the comparison meaningful: when the newest record lands, or a
    /// stored one disappears, the two most recent runs are chosen and any
    /// selection that still exists is kept.
    private func ensureSelection() {
        let ids = Set(records.map(\.id))
        selected.formIntersection(ids)
        for record in records where selected.count < 2 {
            selected.insert(record.id)
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
            return
        }
        // A third choice replaces the older of the two already chosen, so the
        // run just clicked is always part of the pair.
        if selected.count >= 2 {
            let chosen = records.filter { selected.contains($0.id) }
            if let oldest = chosen.last {
                selected.remove(oldest.id)
            }
        }
        selected.insert(id)
    }
}
