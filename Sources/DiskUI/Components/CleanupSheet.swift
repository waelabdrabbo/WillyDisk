import SwiftUI
import DiskCore

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
    @State private var analysisTask: Task<CleanupReport?, Never>?
    @State private var duplicateCheck: DuplicateCheck

    /// `previewReport` skips the walk and shows a known report; the renderer
    /// uses it so a screenshot does not race a background analysis.
    /// `previewDuplicateReport` does the same for a finished content check.
    public init(
        root: ScanNode,
        rootName: String,
        scannedAt: Date,
        policy: CleanupPolicy = .standard,
        previewReport: CleanupReport? = nil,
        previewDuplicateReport: DuplicateReport? = nil,
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
                    content(report)
                }
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 600)
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
                Text("Cleanup candidates")
                    .font(DS.Typography.title2)
                Text(rootName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("From the scan of \(DateFormat.short(scannedAt)). Nothing moves until you confirm.")
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
            Text("Reading the scanned tree…")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.primaryText)
            Text("Looking for files of at least \(ByteFormat.string(policy.largeFileMinimum)) that have not changed in \(ageLabel(policy.largeFileAge)), cache folders, old downloads, and files that share a size.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Cancel") {
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
            Image(systemName: "checkmark.circle")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            Text("Nothing to review")
                .font(DS.Typography.headline)
            Text("No file is both at least \(ByteFormat.string(policy.largeFileMinimum)) and unchanged for \(ageLabel(policy.largeFileAge)), no Caches or Derived Data folder is inside this scan, no download is older than \(ageLabel(policy.downloadAge)), and no two files of at least \(ByteFormat.string(policy.duplicateMinimum)) share a size.")
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

    private func content(_ report: CleanupReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.section) {
                if report.stoppedAtLimit {
                    Label("Stopped after \(report.visitedCount.formatted()) items, so this is a sample of the scan rather than all of it.",
                          systemImage: "exclamationmark.triangle")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !report.duplicateGroups.isEmpty {
                    duplicatesSection(report)
                }

                ForEach(report.groups) { group in
                    if !group.candidates.isEmpty {
                        section(group)
                    }
                }
            }
            .padding(DS.Spacing.xxLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 420)
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
                    Button(allSelected(in: group) ? "Deselect All" : "Select All") {
                        toggleAll(in: group)
                    }
                    .buttonStyle(.borderless)
                    .font(DS.Typography.caption)
                    .controlSize(.small)
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
            return "\(size) across \(CountFormat.items(group.matchCount)) — showing the largest \(group.candidates.count)"
        }
        return "\(size) · \(CountFormat.items(group.matchCount))"
    }

    // MARK: - Duplicates

    /// Same-size files are only candidates. The check is explicit, and only a
    /// matching SHA-256 digest turns a size group into a duplicate group.
    private func duplicatesSection(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text("Possible duplicates")
                    .font(DS.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(duplicateGroupSummary(report))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
            }

            Text("Files of at least \(ByteFormat.string(policy.duplicateMinimum)) that share a size with another file. Same size is not a duplicate: Check Contents reads their bytes and compares SHA-256 digests.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if report.duplicateGroups.contains(where: { $0.isTruncated }) {
                Text("Each size group keeps at most \(policy.maxDuplicateFilesPerGroup) files; the rest are not compared.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            duplicateCheckBody(report)

            Text("Hard links stay separate paths here; moving one does not free space until every link is gone.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func duplicateGroupSummary(_ report: CleanupReport) -> String {
        let groups = sizeGroupLabel(report.duplicateGroupCount)
        let files = CountFormat.files(report.duplicateCandidateCount)
        guard report.duplicateGroupCount > report.duplicateGroups.count else {
            return "\(groups) · \(files)"
        }
        return "\(groups) · showing the largest \(report.duplicateGroups.count)"
    }

    private func sizeGroupLabel(_ count: Int) -> String {
        "\(count.formatted()) size \(count == 1 ? "group" : "groups")"
    }

    @ViewBuilder
    private func duplicateCheckBody(_ report: CleanupReport) -> some View {
        switch duplicateCheck.state {
        case .idle:
            Text("\(CountFormat.files(report.duplicateCandidateCount)) share a size with another file in this scan. Their contents have not been compared.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check Contents") {
                duplicateCheck.start(report.duplicateGroups)
            }
            .controlSize(.small)
            .accessibilityHint("Reads these files and compares their contents")
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
                Text("Comparing contents… \(Int((progress.fraction * 100).rounded()))%")
                Text("\(progress.completedFiles) of \(progress.totalFiles) files")
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                Button("Cancel") {
                    duplicateCheck.cancel()
                }
                .controlSize(.small)
            }
            .font(DS.Typography.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Comparing file contents")
        .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
    }

    @ViewBuilder
    private func duplicateResults(_ result: DuplicateReport) -> some View {
        if result.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                Label("No identical contents found", systemImage: "checkmark.circle")
                    .font(DS.Typography.callout)
                Text("Compared \(CountFormat.files(result.comparedFileCount)) of \(CountFormat.files(result.candidateFileCount)). The files that were read have different contents; the same size alone is not a duplicate.")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                unreadableNote(result)
            }
        } else {
            Text("Compared \(CountFormat.files(result.comparedFileCount)) of \(CountFormat.files(result.candidateFileCount)). The confirmed groups below have identical contents.")
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
            Text("\(CountFormat.files(result.unreadableFileCount)) could not be read and are not called duplicates.")
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
                Text("\(CountFormat.files(group.candidates.count)) with identical contents")
                    .font(DS.Typography.callout.weight(.medium))
                Text("\(ByteFormat.string(group.logicalSize)) each")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                Button(extrasSelected(in: group) ? "Clear Copies" : "Select All But One") {
                    toggleExtras(in: group)
                }
                .buttonStyle(.borderless)
                .font(DS.Typography.caption)
                .controlSize(.small)
                .help("Selects every copy except the first, so one copy stays in place")
            }

            Text("Select All But One leaves the first copy in place. Space returns only when the Trash is emptied.")
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
            return "Files of at least \(ByteFormat.string(policy.largeFileMinimum)) that have not been modified in \(ageLabel(policy.largeFileAge))."
        case .caches:
            return "Folders named Caches directly inside a Library, and Xcode's Derived Data, offered whole. The apps that made them rebuild them; moving one can cost a rebuild until they do."
        case .downloads:
            return "Files in a folder named Downloads that have not been modified in \(ageLabel(policy.downloadAge))."
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
                        .foregroundStyle(DS.Color.secondaryText)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.name), \(ByteFormat.string(candidate.logicalSize))")
        .accessibilityHint(candidate.isDirectory ? "A folder; moves everything inside it" : "A file")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text("Candidates are places to look, not a recommendation. A move goes through the same confirmation as everywhere else, and the space returns when the Trash is emptied.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(selectionSummary)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)

                Spacer()

                Button("Move to Trash…") {
                    onMove(selectedNodes)
                }
                .disabled(selected.isEmpty)
                .accessibilityHint("Opens the confirmation for the selected items")

                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, DS.Spacing.xxLarge)
        .padding(.vertical, DS.Spacing.large)
    }

    private var selectionSummary: String {
        guard !selected.isEmpty else { return "Nothing selected" }
        let bytes = selectedNodes.reduce(Int64(0)) { $0 + $1.logicalSize }
        return "\(CountFormat.items(selected.count)) selected · \(ByteFormat.string(bytes))"
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
            let years = max(1, days / 365)
            return years == 1 ? "a year" : "\(years) years"
        }
        if days >= 30 {
            let months = max(1, days / 30)
            return months == 1 ? "a month" : "\(months) months"
        }
        return days == 1 ? "a day" : "\(max(1, days)) days"
    }
}
