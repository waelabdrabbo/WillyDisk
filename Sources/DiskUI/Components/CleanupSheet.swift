import SwiftUI
import DiskCore
import DiskLocalization

/// The two views of the cleanup report.
public enum CleanupTab: String, CaseIterable, Identifiable, Sendable {
    case old
    case duplicates

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .old: L10n.string("Old")
        case .duplicates: L10n.string("Duplicates")
        }
    }
}

/// Candidates worth reviewing, grouped by why they were noticed.
///
/// The analysis runs off the main actor over the tree the finished scan already
/// carries; this sheet never touches the filesystem and never deletes anything.
/// A selection goes to the same reclaim confirmation every other move uses, so
/// the guard and the “the space returns when the Trash is emptied” wording stay
/// in one place.
@MainActor
public struct CleanupSheet: View {
    private let root: ScanNode
    private let rootName: String
    private let scannedAt: Date
    private let policy: CleanupPolicy
    private let previewReport: CleanupReport?
    private let onMove: ([ScanNode]) -> Void
    private let onClose: () -> Void

    @State private var report: CleanupReport?
    @State private var isAnalyzing: Bool
    @State private var selected: Set<URL> = []
    @State private var hoveredCandidate: URL?
    @State private var analysisTask: Task<CleanupReport?, Never>?
    @State private var duplicateCheck: DuplicateCheck
    @State private var tab: CleanupTab

    /// `previewReport` skips the walk and shows a known report; the renderer
    /// uses it so a screenshot does not race a background analysis.
    /// `previewDuplicateReport` does the same for a finished content check.
    /// `initialTab` lets a preview open the tab it needs to show.
    public init(
        root: ScanNode,
        rootName: String,
        scannedAt: Date,
        policy: CleanupPolicy = .standard,
        previewReport: CleanupReport? = nil,
        previewDuplicateReport: DuplicateReport? = nil,
        initialTab: CleanupTab = .old,
        onMove: @escaping ([ScanNode]) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.root = root
        self.rootName = rootName
        self.scannedAt = scannedAt
        self.policy = policy
        self.previewReport = previewReport
        self.onMove = onMove
        self.onClose = onClose
        _report = State(initialValue: previewReport)
        _isAnalyzing = State(initialValue: previewReport == nil)
        _duplicateCheck = State(initialValue: DuplicateCheck(preview: previewDuplicateReport))
        let previewTab: CleanupTab
        if initialTab == .old,
           let previewReport,
           previewReport.groups.allSatisfy({ $0.candidates.isEmpty }),
           !previewReport.duplicateGroups.isEmpty {
            previewTab = .duplicates
        } else {
            previewTab = initialTab
        }
        _tab = State(initialValue: previewTab)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if isAnalyzing {
                analyzing
            } else if let report {
                if report.isEmpty {
                    empty
                } else {
                    tabs(report)
                }
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .background(DS.Color.windowBackground)
        .tint(DS.Color.signal)
        .task { await analyzeIfNeeded() }
        .onDisappear {
            analysisTask?.cancel()
            duplicateCheck.cancel()
        }
    }

    // MARK: - Header and states

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: "sparkles")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                Text(L10n.string("Cleanup candidates"))
                    .font(DS.Typography.title2)
                Text(rootName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(L10n.format("From the scan of %@. Nothing moves until you confirm.", DateFormat.short(scannedAt)))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xxLarge)
    }

    private var analyzing: some View {
        VStack(spacing: DS.Spacing.medium) {
            ProgressView()
            Text(L10n.string("Reading the scanned tree…"))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.primaryText)
            Text(L10n.format(
                "Looking for files of at least %@ that have not changed in %@, cache folders, old downloads, and files that share a size.",
                ByteFormat.string(policy.largeFileMinimum),
                ageLabel(policy.largeFileAge)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(L10n.string("Cancel")) {
                analysisTask?.cancel()
                onClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.section)
    }

    private var empty: some View {
        VStack(spacing: DS.Spacing.small) {
            if let report {
                stoppedNotice(report)
            }
            Image(systemName: "checkmark.circle")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            Text(L10n.string("Nothing to review"))
                .font(DS.Typography.headline)
            Text(L10n.format(
                "No file is both at least %@ and unchanged for %@, no Caches or Derived Data folder is inside this scan, no download is older than %@, and no two files of at least %@ share a size.",
                ByteFormat.string(policy.largeFileMinimum),
                ageLabel(policy.largeFileAge),
                ageLabel(policy.downloadAge),
                ByteFormat.string(policy.duplicateMinimum)
            ))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.section)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Report

    private func tabs(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
                .padding(.horizontal, DS.Spacing.xxLarge)
                .padding(.vertical, DS.Spacing.medium)

            Divider()

            switch tab {
            case .old:
                oldContent(report)
            case .duplicates:
                duplicatesContent(report)
            }
        }
    }

    /// The sheet's two views, switched by the same native segmented control the
    /// explorer uses, so "choose one view" has one control across the app.
    private var tabBar: some View {
        HStack(spacing: 0) {
            Picker(L10n.string("Cleanup view"), selection: $tab) {
                ForEach(CleanupTab.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .dsSegmentedSwitch()
            .accessibilityLabel(L10n.string("Cleanup view"))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func oldContent(_ report: CleanupReport) -> some View {
        if report.groups.allSatisfy({ $0.candidates.isEmpty }) {
            VStack(spacing: DS.Spacing.small) {
                stoppedNotice(report)
                Image(systemName: "checkmark.circle")
                    .font(DS.Icon.medium)
                    .foregroundStyle(DS.Color.secondaryText)
                    .accessibilityHidden(true)
                Text(L10n.string("Nothing to review here"))
                    .font(DS.Typography.headline)
                Text(L10n.format(
                    "No file is both at least %@ and unchanged for %@, no Caches or Derived Data folder is inside this scan, and no download is older than %@.",
                    ByteFormat.string(policy.largeFileMinimum),
                    ageLabel(policy.largeFileAge),
                    ageLabel(policy.downloadAge)
                ))
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DS.Spacing.section)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    stoppedNotice(report)

                    ForEach(report.groups) { group in
                        if !group.candidates.isEmpty {
                            section(group)
                        }
                    }
                }
                .padding(DS.Spacing.xxLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)
        }
    }

    @ViewBuilder
    private func duplicatesContent(_ report: CleanupReport) -> some View {
        if report.duplicateGroups.isEmpty {
            VStack(spacing: DS.Spacing.small) {
                stoppedNotice(report)
                Image(systemName: "doc.on.doc")
                    .font(DS.Icon.medium)
                    .foregroundStyle(DS.Color.secondaryText)
                    .accessibilityHidden(true)
                Text(L10n.string("No possible duplicates"))
                    .font(DS.Typography.headline)
                Text(L10n.format(
                    "No two files of at least %@ share a size in this scan.",
                    ByteFormat.string(policy.duplicateMinimum)
                ))
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DS.Spacing.section)
            .accessibilityElement(children: .combine)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.large) {
                    stoppedNotice(report)
                    duplicatesSection(report)
                }
                .padding(DS.Spacing.xxLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)
        }
    }

    @ViewBuilder
    private func stoppedNotice(_ report: CleanupReport) -> some View {
        if report.stoppedAtLimit {
            Label(L10n.format(
                "Stopped after %@, so this is a sample of the scan rather than all of it.",
                CountFormat.items(report.visitedCount)
            ), systemImage: "exclamationmark.triangle")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ group: CleanupGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(group.kind.title)
                    .font(DS.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(groupSummary(group))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                if group.candidates.count > 1 {
                    InlineActionButton(L10n.string(allSelected(in: group) ? "Deselect All" : "Select All")) {
                        toggleAll(in: group)
                    }
                }
            }

            Text(explanation(for: group.kind))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Spacing.xSmall) {
                ForEach(group.candidates) { candidate in
                    row(candidate)
                }
            }
        }
    }

    private func groupSummary(_ group: CleanupGroup) -> String {
        let size = ByteFormat.string(group.totalLogicalSize)
        if group.isTruncated {
            return L10n.format(
                "%@ across %@ — showing the largest %lld",
                size,
                CountFormat.items(group.matchCount),
                group.candidates.count
            )
        }
        return L10n.format("%@ · %@", size, CountFormat.items(group.matchCount))
    }

    // MARK: - Duplicates

    /// Same-size files are only candidates. The check is explicit, and only a
    /// matching SHA-256 digest turns a size group into a duplicate group.
    private func duplicatesSection(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(duplicateSectionTitle)
                    .font(DS.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(duplicateGroupSummary(report))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
            }

            Text(L10n.format(
                "Files of at least %@ that share a size with another file. Same size is not a duplicate: Check Contents reads their bytes and compares SHA-256 digests.",
                ByteFormat.string(policy.duplicateMinimum)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if report.duplicateGroups.contains(where: { $0.isTruncated }) {
                Text(L10n.format(
                    "Each size group keeps at most %lld files; the rest are not compared.",
                    policy.maxDuplicateFilesPerGroup
                ))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            duplicateCheckBody(report)

            Text(L10n.string("Hard links stay separate paths here; moving one does not free space until every link is gone."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var duplicateSectionTitle: String {
        switch duplicateCheck.state {
        case .idle: L10n.string("Possible duplicates")
        case .checking: L10n.string("Checking contents")
        case .checked(let result): L10n.string(result.isEmpty ? "Checked contents" : "Identical contents")
        }
    }

    private func duplicateGroupSummary(_ report: CleanupReport) -> String {
        let groups = sizeGroupLabel(report.duplicateGroupCount)
        let files = CountFormat.files(report.duplicateCandidateCount)
        guard report.duplicateGroupCount > report.duplicateGroups.count else {
            return L10n.format("%@ · %@", groups, files)
        }
        return L10n.format("%@ · showing the largest %lld", groups, report.duplicateGroups.count)
    }

    private func sizeGroupLabel(_ count: Int) -> String {
        L10n.format("%lld size groups", count)
    }

    @ViewBuilder
    private func duplicateCheckBody(_ report: CleanupReport) -> some View {
        switch duplicateCheck.state {
        case .idle:
            Text(L10n.format(
                "%@ share a size with another file in this scan. Their contents have not been compared.",
                CountFormat.files(report.duplicateCandidateCount)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.string("Check Contents")) {
                duplicateCheck.start(report.duplicateGroups)
            }
            .controlSize(.small)
            .accessibilityHint(L10n.string("Reads these files and compares their contents"))
        case .checking(let progress):
            duplicateProgress(progress)
        case .checked(let result):
            duplicateResults(result)
        }
    }

    private func duplicateProgress(_ progress: DuplicateHashProgress) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            ProgressView(value: progress.fraction)
                .frame(maxWidth: 320)
            HStack(spacing: DS.Spacing.small) {
                Text(L10n.format(
                    "Comparing contents… %lld%%",
                    Int((progress.fraction * 100).rounded())
                ))
                Text(L10n.format(
                    "%@ of %@",
                    progress.completedFiles.formatted(),
                    CountFormat.files(progress.totalFiles)
                ))
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                Button(L10n.string("Cancel")) {
                    duplicateCheck.cancel()
                }
                .controlSize(.small)
            }
            .font(DS.Typography.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("Comparing file contents"))
        .accessibilityValue(L10n.format("%lld percent", Int((progress.fraction * 100).rounded())))
    }

    @ViewBuilder
    private func duplicateResults(_ result: DuplicateReport) -> some View {
        if result.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                Label(L10n.string("No identical contents found"), systemImage: "checkmark.circle")
                    .font(DS.Typography.callout)
                Text(L10n.format(
                    "Compared %@ of %@. The files that were read have different contents; the same size alone is not a duplicate.",
                    CountFormat.files(result.comparedFileCount),
                    CountFormat.files(result.candidateFileCount)
                ))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                unreadableNote(result)
            }
        } else {
            Text(L10n.format(
                "Compared %@ of %@. The confirmed groups below have identical contents.",
                CountFormat.files(result.comparedFileCount),
                CountFormat.files(result.candidateFileCount)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            unreadableNote(result)
            ForEach(result.groups) { group in
                duplicateContentGroup(group)
            }
        }
    }

    @ViewBuilder
    private func unreadableNote(_ result: DuplicateReport) -> some View {
        if result.unreadableFileCount > 0 {
            Text(L10n.format(
                "%@ could not be read and are not called duplicates.",
                CountFormat.files(result.unreadableFileCount)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One confirmed group. The copies are individually selectable; the bulk
    /// action leaves the first path unselected, so acting on it never takes every
    /// copy at once.
    private func duplicateContentGroup(_ group: DuplicateContentGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(L10n.format("%@ with identical contents", CountFormat.files(group.candidates.count)))
                    .font(DS.Typography.callout.weight(.medium))
                Text(L10n.format("%@ each", ByteFormat.string(group.logicalSize)))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                InlineActionButton(L10n.string(extrasSelected(in: group) ? "Clear Copies" : "Select All But One")) {
                    toggleExtras(in: group)
                }
                .help(L10n.string("Selects every copy except the first, so one copy stays in place"))
            }

            Text(L10n.string("Select All But One leaves the first copy in place. Space returns only when the Trash is emptied."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Spacing.xSmall) {
                ForEach(group.candidates) { candidate in
                    row(candidate)
                }
            }
        }
        .padding(DS.Spacing.small)
        .background(DS.Color.controlBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }

    private func extrasSelected(in group: DuplicateContentGroup) -> Bool {
        let extras = group.candidates.dropFirst().map(\.url)
        return !extras.isEmpty && extras.allSatisfy { selected.contains($0) }
    }

    private func toggleExtras(in group: DuplicateContentGroup) {
        let extras = group.candidates.dropFirst().map(\.url)
        if extrasSelected(in: group) {
            for url in extras { selected.remove(url) }
        } else {
            for url in extras { selected.insert(url) }
        }
    }

    private func explanation(for kind: CleanupKind) -> String {
        switch kind {
        case .largeAndOld:
            return L10n.format(
                "Files of at least %@ that have not been modified in %@.",
                ByteFormat.string(policy.largeFileMinimum),
                ageLabel(policy.largeFileAge)
            )
        case .caches:
            return L10n.string("Folders named Caches directly inside a Library, and Xcode's Derived Data, offered whole. The apps that made them rebuild them; moving one can cost a rebuild until they do.")
        case .downloads:
            return L10n.format(
                "Files in a folder named Downloads that have not been modified in %@.",
                ageLabel(policy.downloadAge)
            )
        }
    }

    private func row(_ candidate: CleanupCandidate) -> some View {
        let isSelected = selected.contains(candidate.url)
        return Button {
            if isSelected {
                selected.remove(candidate.url)
            } else {
                selected.insert(candidate.url)
            }
        } label: {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(DS.Typography.callout)
                    .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.secondaryText)
                    .accessibilityHidden(true)
                Image(systemName: candidate.isDirectory ? "folder.fill" : "doc.fill")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.graphite)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                    Text(candidate.name)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(PathFormat.abbreviated(candidate.url.path, maxLength: 72))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Spacing.small)
                if candidate.isDirectory {
                    Text(CountFormat.files(candidate.fileCount))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                } else if let modified = candidate.modifiedAt {
                    Text(DateFormat.dateOnly(modified))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                Text(ByteFormat.string(candidate.logicalSize))
                    .font(DS.Typography.figures)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xSmall)
            .dsHoverableRow(isHovered: hoveredCandidate == candidate.url, radius: DS.Radius.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredCandidate = candidate.url
            } else if hoveredCandidate == candidate.url {
                hoveredCandidate = nil
            }
        }
        .accessibilityLabel(L10n.format("%@, %@", candidate.name, ByteFormat.string(candidate.logicalSize)))
        .accessibilityHint(L10n.string(candidate.isDirectory ? "A folder; moves everything inside it" : "A file"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(L10n.string("Candidates are places to look, not a recommendation. A move goes through the same confirmation as everywhere else, and the space returns when the Trash is emptied."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(selectionSummary)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)

                Spacer()

                Button {
                    onMove(selectedNodes)
                } label: {
                    Text(L10n.string("Move to Trash…"))
                        .frame(minWidth: DS.Size.actionMinWidth)
                }
                .disabled(selected.isEmpty)
                .accessibilityHint(L10n.string("Opens the confirmation for the selected items"))

                Button(action: onClose) {
                    Text(L10n.string("Done"))
                        .frame(minWidth: DS.Size.secondaryActionMinWidth)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DS.Spacing.xxLarge)
        .padding(.vertical, DS.Spacing.large)
    }

    private var selectionSummary: String {
        guard !selected.isEmpty else { return L10n.string("Nothing selected") }
        let bytes = selectedNodes.reduce(Int64(0)) { $0 + $1.logicalSize }
        return L10n.format(
            "%@ selected · %@",
            CountFormat.items(selected.count),
            ByteFormat.string(bytes)
        )
    }

    private var selectedNodes: [ScanNode] {
        guard let report else { return [] }
        var candidates = report.groups.flatMap(\.candidates)
        if case .checked(let duplicateReport) = duplicateCheck.state {
            candidates += duplicateReport.groups.flatMap(\.candidates)
        }
        var seen = Set<URL>()
        return candidates
            .filter { selected.contains($0.url) && seen.insert($0.url).inserted }
            .map(\.node)
    }

    // MARK: - Actions

    private func analyzeIfNeeded() async {
        guard report == nil, isAnalyzing else { return }
        let root = root
        let policy = policy
        let task = Task.detached(priority: .userInitiated) {
            CleanupAnalysis.analyze(root: root, policy: policy, isCancelled: { Task.isCancelled })
        }
        analysisTask = task
        let result = await task.value
        guard !Task.isCancelled else { return }
        report = result
        isAnalyzing = false
        // A scan with no old-style candidates but some same-size groups opens on
        // the tab that has something to show.
        if let result,
           tab == .old,
           result.groups.allSatisfy({ $0.candidates.isEmpty }),
           !result.duplicateGroups.isEmpty {
            tab = .duplicates
        }
    }

    private func allSelected(in group: CleanupGroup) -> Bool {
        group.candidates.allSatisfy { selected.contains($0.url) }
    }

    private func toggleAll(in group: CleanupGroup) {
        if allSelected(in: group) {
            for candidate in group.candidates { selected.remove(candidate.url) }
        } else {
            for candidate in group.candidates { selected.insert(candidate.url) }
        }
    }

    private func ageLabel(_ interval: TimeInterval) -> String {
        let days = Int(interval / 86_400)
        if days >= 360 {
            return L10n.format("%lld years", max(1, days / 365))
        }
        if days >= 30 {
            return L10n.format("%lld months", max(1, days / 30))
        }
        return L10n.format("%lld days", max(1, days))
    }
}
