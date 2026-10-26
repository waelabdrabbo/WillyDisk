import SwiftUI
import DiskCore
import DiskLocalization

/// The one hovered cleanup row.
///
/// The rows observe this reference rather than the sheet holding the URL as view
/// state, so a pointer crossing one row re-renders the rows and leaves the
/// sheet's header, tabs and footer where they are. A scroll suspends the hover:
/// rows passing under a still pointer do not light as they go by, and the row
/// under the pointer is named again when the content settles.
@MainActor
@Observable
final class CleanupHover {
    var url: URL?

    private(set) var isSuspended = false

    /// Clears the hover when the content it named is replaced.
    func reset() {
        isSuspended = false
        url = nil
    }

    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { url = nil }
    }

    func set(_ url: URL, _ hovering: Bool) {
        guard !isSuspended else { return }
        if hovering {
            if self.url != url { self.url = url }
        } else if self.url == url {
            self.url = nil
        }
    }
}

/// The fraction of the tree a cleanup walk has accounted for.
///
/// `CleanupAnalysis` runs off the main actor, so it publishes through this box
/// instead of touching the sheet's state. Updates only move forward: a late
/// report from an older walk cannot pull the bar back.
@MainActor
@Observable
private final class CleanupWalkProgress {
    private(set) var fraction: Double = 0

    func advance(to value: Double) {
        fraction = max(fraction, min(max(value, 0), 1))
    }

    func reset() {
        fraction = 0
    }
}

/// The cleanup row under the pointer once a scroll settles.
///
/// Cleanup rows are not uniform, so each reports its own frame in the scroll
/// content's coordinate space; the content offset turns the pointer's place in
/// the viewport into a place in that content.
enum CleanupHoverTarget {
    static func row(in frames: [URL: CGRect], pointer: CGPoint, contentOffset: CGFloat) -> URL? {
        let point = CGPoint(x: pointer.x, y: pointer.y + contentOffset)
        return frames.first { $0.value.contains(point) }?.key
    }
}

/// The views of the cleanup report.
public enum CleanupTab: String, CaseIterable, Identifiable, Sendable {
    case candidates
    case duplicates
    case moved

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .candidates: L10n.string("Candidates")
        case .duplicates: L10n.string("Duplicates")
        case .moved: L10n.string("Moved")
        }
    }

    /// The glyph beside the title, so the three destinations read apart before
    /// the labels are read.
    var symbol: String {
        switch self {
        case .candidates: "checklist"
        case .duplicates: "doc.on.doc"
        case .moved: "trash"
        }
    }
}

/// Candidates worth reviewing, grouped by why they were noticed.
///
/// The analysis runs off the main actor over the tree the finished scan already
/// carries, and re-runs when the watched tree changes; this sheet never touches
/// the filesystem and never deletes anything.
/// A selection goes to the same reclaim confirmation every other move uses, so
/// the guard and the “the space returns when the Trash is emptied” wording stay
/// in one place.
@MainActor
public struct CleanupSheet: View {
    private let tree: LiveTree
    private let rootName: String
    private let scannedAt: Date
    private let policy: CleanupPolicy
    private let refresh: CleanupRefresh
    private let previewReport: CleanupReport?
    /// The live move log, when the app has one. The sheet reads it in its body,
    /// so a Put Back updates the rows without reopening the sheet.
    private let reclaimLog: ReclaimLog?
    /// Sample moves for a preview, which has no log.
    private let previewMoves: [ReclaimMove]
    /// The confirmation the sheet shows over itself. The results screen owns
    /// the flow; the sheet only presents it, so confirming or cancelling comes
    /// back to the same list instead of closing the sheet.
    private let reclaimCandidates: [ReclaimCandidate]
    private let reclaimRefusal: ReclaimRefusal?
    private let isCheckingReclaim: Bool
    private let isTrashing: Bool
    /// The outcome of a move made from this sheet, shown at its foot.
    private let notice: ReclaimNotice?
    private let onDismissNotice: () -> Void
    private let onBeginReclaim: ([ScanNode]) -> Void
    private let onConfirmReclaim: () -> Void
    private let onCancelReclaim: () -> Void
    private let onRestore: (ReclaimMove) async -> String?
    private let onClose: () -> Void

    @State private var report: CleanupReport?
    @State private var isAnalyzing: Bool
    @State private var walkProgress = CleanupWalkProgress()
    @State private var selected: Set<URL> = []
    @State private var hover = CleanupHover()
    @State private var scrollMetrics = CleanupScrollMetrics()
    @State private var analysisTask: Task<CleanupReport?, Never>?
    @State private var duplicateCheck: DuplicateCheck
    @State private var tab: CleanupTab
    @State private var restoringMoveID: UUID?
    @State private var restoreFailures: [UUID: String] = [:]
    /// The logged items whose Trash copy the filesystem no longer has.
    @State private var missingItemIDs: Set<UUID> = []
    /// Set when the tree changes while a walk is running; the loop takes it
    /// after the walk finishes, so a busy folder cannot cancel every walk.
    @State private var needsRefresh = false

    /// `previewReport` skips the walk and shows a known report; the renderer
    /// uses it so a screenshot does not race a background analysis.
    /// `previewDuplicateReport` does the same for a finished content check.
    /// `initialTab` lets a preview open the tab it needs to show.
    /// `tree` is the live results tree the sheet analyses: the candidates are
    /// what it holds now, not what the scan measured.
    public init(
        tree: LiveTree,
        rootName: String,
        scannedAt: Date,
        policy: CleanupPolicy = .standard,
        refresh: CleanupRefresh = CleanupRefresh(),
        previewReport: CleanupReport? = nil,
        reclaimLog: ReclaimLog? = nil,
        previewMoves: [ReclaimMove] = [],
        previewDuplicateReport: DuplicateReport? = nil,
        initialTab: CleanupTab = .candidates,
        reclaimCandidates: [ReclaimCandidate] = [],
        reclaimRefusal: ReclaimRefusal? = nil,
        isCheckingReclaim: Bool = false,
        isTrashing: Bool = false,
        notice: ReclaimNotice? = nil,
        onDismissNotice: @escaping () -> Void = {},
        onBeginReclaim: @escaping ([ScanNode]) -> Void = { _ in },
        onConfirmReclaim: @escaping () -> Void = {},
        onCancelReclaim: @escaping () -> Void = {},
        onRestore: @escaping (ReclaimMove) async -> String? = { _ in nil },
        onClose: @escaping () -> Void
    ) {
        self.tree = tree
        self.rootName = rootName
        self.scannedAt = scannedAt
        self.policy = policy
        self.refresh = refresh
        self.previewReport = previewReport
        self.reclaimLog = reclaimLog
        self.previewMoves = previewMoves
        self.reclaimCandidates = reclaimCandidates
        self.reclaimRefusal = reclaimRefusal
        self.isCheckingReclaim = isCheckingReclaim
        self.isTrashing = isTrashing
        self.notice = notice
        self.onDismissNotice = onDismissNotice
        self.onBeginReclaim = onBeginReclaim
        self.onConfirmReclaim = onConfirmReclaim
        self.onCancelReclaim = onCancelReclaim
        self.onRestore = onRestore
        self.onClose = onClose
        _report = State(initialValue: previewReport)
        _isAnalyzing = State(initialValue: previewReport == nil)
        _duplicateCheck = State(initialValue: DuplicateCheck(preview: previewDuplicateReport))
        let previewTab: CleanupTab
        if initialTab == .candidates,
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
        ZStack {
            content
                .frame(width: 720, height: 640)
                .background(DS.Color.windowBackground)
                .tint(DS.Color.signal)
                .environment(hover)
                .task { await analysisLoop() }
                .task(id: moves) { await refreshTrashPresence() }
                .onChange(of: refresh.revision) { _, _ in
                    needsRefresh = true
                }
                .onChange(of: tab) { _, newTab in
                    hover.reset()
                    scrollMetrics.contentOffset = 0
                    if newTab == .moved {
                        Task { await refreshTrashPresence() }
                    }
                }
                .onDisappear {
                    analysisTask?.cancel()
                    duplicateCheck.cancel()
                }
                .disabled(hasConfirmation)
                .accessibilityHidden(hasConfirmation)

            if hasConfirmation {
                confirmation
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if isAnalyzing {
                analyzing
            } else if let report {
                tabs(report)
            }

            if let notice {
                ReclaimBanner(
                    tone: notice.tone,
                    message: notice.message,
                    action: notice.showsShowTrash ? .showMoved : nil,
                    onAction: {
                        tab = .moved
                        onDismissNotice()
                    },
                    onDismiss: onDismissNotice
                )
                .padding(.horizontal, DS.Spacing.xxLarge)
                .padding(.bottom, DS.Spacing.medium)
            }

            Divider()
            footer
        }
    }

    private var hasConfirmation: Bool { !reclaimCandidates.isEmpty }

    /// The move confirmation, over the sheet rather than instead of it: the
    /// list stays where it was, and both buttons come back to it.
    ///
    /// Its surface is the window background a native sheet gets, so the same
    /// confirmation does not change colour when it is opened from cleanup
    /// instead of from the results list. A shadow lifts it off the dimmed sheet
    /// behind it; there is no card border.
    private var confirmation: some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture {}

            ReclaimSheet(
                candidates: reclaimCandidates,
                refusal: reclaimRefusal,
                isChecking: isCheckingReclaim,
                isWorking: isTrashing,
                onCancel: onCancelReclaim,
                onConfirm: onConfirmReclaim
            )
            .background {
                // The shadow belongs to the sheet's own surface. Applying it to
                // the whole confirmation would shadow the item list inside it
                // too, because the list is part of the same composited view.
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(DS.Color.windowBackground)
                    .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
            }
            .padding(DS.Spacing.xxLarge)
        }
        .transition(.opacity)
    }

    /// The moves to show: the app's log when there is one, a preview's samples
    /// otherwise.
    private var moves: [ReclaimMove] {
        reclaimLog?.moves ?? previewMoves
    }

    // MARK: - Header and states

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: "sparkles")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                HStack(alignment: .center, spacing: DS.Spacing.large) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                        Text(L10n.string("Cleanup"))
                            .font(DS.Typography.title2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(rootName)
                            .font(DS.Typography.callout)
                            .foregroundStyle(DS.Color.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: DS.Spacing.small)
                    if let report {
                        tabBar(report)
                            .layoutPriority(1)
                    }
                }
                Text(L10n.format("Current contents. This scan finished %@. Nothing moves until you confirm.", DateFormat.short(scannedAt)))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .padding(DS.Spacing.xxLarge)
    }

    private var analyzing: some View {
        VStack(spacing: DS.Spacing.medium) {
            ProgressView(value: walkProgress.fraction)
                .progressViewStyle(.linear)
                .frame(width: DS.Size.progressBarMaxWidth)
                .accessibilityLabel(L10n.string("Reading the scanned tree…"))
                .accessibilityValue(L10n.format(
                    "%lld percent",
                    Int((walkProgress.fraction * 100).rounded())
                ))
            Text(L10n.string("Reading the scanned tree…"))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.primaryText)
            Text(L10n.format(
                "Looking for files that take at least %@ on disk and have not changed in %@, Xcode support and simulator folders, caches, logs, old downloads, and files that share a size.",
                ByteFormat.string(policy.largeFileMinimum),
                cleanupAgeLabel(policy.largeFileAge)
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

    // MARK: - Report

    /// The selected destination owns the space between the header and the
    /// footer. Its scroll view fills that space, so the header and footer stay
    /// where they are when the content changes.
    private func tabs(_ report: CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch tab {
            case .candidates:
                candidatesContent(report)
            case .duplicates:
                duplicatesContent(report)
            case .moved:
                movedContent()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The report's three destinations, sized for the header.
    ///
    /// The count and the bytes are the whole view, not just the rows a cap
    /// shows, so the strip and the section headers agree. The selected
    /// destination is the one signal fill on the sheet; the others stay quiet
    /// until the pointer or the keyboard reaches them.
    private func tabBar(_ report: CleanupReport) -> some View {
        HStack(spacing: DS.Spacing.xxSmall) {
            ForEach(CleanupTab.allCases) { option in
                CleanupTabButton(
                    tab: option,
                    detail: tabDetail(option, report: report),
                    isSelected: tab == option
                ) {
                    guard tab != option else { return }
                    tab = option
                }
            }
        }
        .padding(DS.Spacing.xxSmall)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(DS.Color.primaryText.opacity(DS.Opacity.controlSurface))
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Cleanup view"))
    }

    /// What a destination holds, under its name.
    ///
    /// Candidates carry every match and its bytes. Duplicates carry the number
    /// of files that share a size with another file, and after a content check
    /// how many of those were confirmed identical ("2 of 8 files"); their bytes
    /// are not shown because two copies share one reclaimable amount, and that
    /// amount is not known until the contents are compared. Moved carries only
    /// the items the Trash still holds; a restored or removed item stays in the
    /// log but not in the count.
    private func tabDetail(_ option: CleanupTab, report: CleanupReport) -> String {
        switch option {
        case .candidates:
            let count = report.groups.reduce(0) { $0 + $1.matchCount }
            let bytes = report.groups.reduce(Int64(0)) { $0 + $1.totalAllocatedSize }
            return countAndSize(count, bytes)
        case .duplicates:
            return duplicateCountSummary(report)
        case .moved:
            let items = moves.flatMap { pendingItems(in: $0) }
            let bytes = items.reduce(Int64(0)) { $0 + max(0, $1.allocatedSize) }
            return inTrashDetail(items.count, bytes)
        }
    }

    private func countAndSize(_ count: Int, _ bytes: Int64) -> String {
        let countText = CountFormat.items(count)
        guard count > 0, bytes > 0 else { return countText }
        return L10n.format("%@ · %@", countText, ByteFormat.string(bytes))
    }

    /// The Moved tab counts what Put Back can still act on, not the log's
    /// history, so its detail says where those items are.
    private func inTrashDetail(_ count: Int, _ bytes: Int64) -> String {
        let countText = L10n.format("%lld in the Trash", count)
        guard count > 0, bytes > 0 else { return countText }
        return L10n.format("%@ · %@", countText, ByteFormat.string(bytes))
    }

    @ViewBuilder
    private func candidatesContent(_ report: CleanupReport) -> some View {
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
                    "No file takes at least %@ on disk and has not changed for %@, no Caches, Device Support, Simulators, or Logs folder is inside this scan, and no download is older than %@.",
                    ByteFormat.string(policy.largeFileMinimum),
                    cleanupAgeLabel(policy.largeFileAge),
                    cleanupAgeLabel(policy.downloadAge)
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

                    ForEach(CleanupTier.allCases, id: \.self) { tier in
                        let groups = report.groups.filter {
                            $0.rule.tier == tier && !$0.candidates.isEmpty
                        }
                        if !groups.isEmpty {
                            VStack(alignment: .leading, spacing: DS.Spacing.section) {
                                tierHeader(tier)
                                ForEach(groups) { group in
                                    section(group)
                                }
                            }
                        }
                    }
                }
                .padding(DS.Spacing.xxLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: CleanupScrollSpace.content)
                .onPreferenceChange(CleanupRowFramesKey.self) { frames in
                    scrollMetrics.rowFrames = frames
                }
            }
            .modifier(CleanupScrollHover(hover: hover, metrics: scrollMetrics))
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
                    "No two files on this Mac of at least %@ share a size in this scan.",
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
                .coordinateSpace(name: CleanupScrollSpace.content)
                .onPreferenceChange(CleanupRowFramesKey.self) { frames in
                    scrollMetrics.rowFrames = frames
                }
            }
            .modifier(CleanupScrollHover(hover: hover, metrics: scrollMetrics))
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

    /// A tier's own heading, above the rules that belong to it.
    private func tierHeader(_ tier: CleanupTier) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
            Text(tier.title)
                .font(DS.Typography.headline)
                .accessibilityAddTraits(.isHeader)
            Text(tier.explanation)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ group: CleanupGroup) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(group.rule.title)
                    .font(DS.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(groupSummary(group))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                // A whole section can only be taken at once when the app that
                // made those files makes them again; a personal rule is chosen
                // row by row.
                if group.rule.tier == .rebuildable, group.candidates.count > 1 {
                    InlineActionButton(L10n.string(allSelected(in: group) ? "Deselect All" : "Select All")) {
                        toggleAll(in: group)
                    }
                }
            }

            Text(group.rule.explanation(policy: policy))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Spacing.xSmall) {
                ForEach(group.candidates) { candidate in
                    CleanupCandidateRow(
                        candidate: candidate,
                        isSelected: selected.contains(candidate.url),
                        onToggle: { toggle(candidate.url) }
                    )
                }
            }
        }
    }

    private func groupSummary(_ group: CleanupGroup) -> String {
        let size = ByteFormat.string(group.totalAllocatedSize)
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

        }
    }

    private var duplicateSectionTitle: String {
        switch duplicateCheck.state {
        case .idle: L10n.string("Possible duplicates")
        case .checking: L10n.string("Checking contents")
        case .checked(let result): L10n.string(result.isEmpty ? "Checked contents" : "Identical contents")
        }
    }

    /// How many same-size files a check confirmed identical, out of the whole
    /// candidate set. While the check is idle or running, the summary is the
    /// candidate set itself.
    private func duplicateCountSummary(_ report: CleanupReport) -> String {
        if case .checked(let result) = duplicateCheck.state {
            let confirmed = result.groups.reduce(0) { $0 + $1.candidates.count }
            return L10n.format(
                "%lld of %@",
                confirmed,
                CountFormat.files(report.duplicateFileCount)
            )
        }
        return CountFormat.files(report.duplicateFileCount)
    }

    private func duplicateGroupSummary(_ report: CleanupReport) -> String {
        if case .checked = duplicateCheck.state {
            return duplicateCountSummary(report)
        }
        let groups = sizeGroupLabel(report.duplicateGroupCount)
        guard report.duplicateGroupCount > report.duplicateGroups.count else {
            return L10n.format("%@ · %@", groups, CountFormat.files(report.duplicateFileCount))
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
                "%@ stored on this Mac share a size with another file in this scan. Their contents have not been compared.",
                CountFormat.files(report.duplicateFileCount)
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
                if result.comparedFileCount > 0 {
                    Text(L10n.format(
                        "Compared %@ of %@. The files that were read have different contents; the same size alone is not a duplicate.",
                        CountFormat.files(result.comparedFileCount),
                        CountFormat.files(result.candidateFileCount)
                    ))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                checkNotes(result)
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
            checkNotes(result)
            ForEach(result.groups) { group in
                duplicateContentGroup(group)
            }
        }
    }

    @ViewBuilder
    private func checkNotes(_ result: DuplicateReport) -> some View {
        unreadableNote(result)
        hardLinkNote(result)
        cloneNote(result)
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

    @ViewBuilder
    private func hardLinkNote(_ result: DuplicateReport) -> some View {
        if result.hardLinkFileCount > 0 {
            Text(L10n.format(
                "Paths that are hard links to another file are not offered as copies, because moving one frees nothing until every link is gone: %@.",
                CountFormat.files(result.hardLinkFileCount)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cloneNote(_ result: DuplicateReport) -> some View {
        if result.cloneFileCount > 0 {
            Text(L10n.format(
                "Paths that share storage with another file are not offered as copies, because moving one frees nothing until the others go: %@.",
                CountFormat.files(result.cloneFileCount)
            ))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
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
                Text(L10n.format("%@ each", ByteFormat.string(group.localSize)))
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
                    CleanupCandidateRow(
                        candidate: candidate,
                        isSelected: selected.contains(candidate.url),
                        onToggle: { toggle(candidate.url) }
                    )
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

    private func toggle(_ url: URL) {
        if selected.contains(url) {
            selected.remove(url)
        } else {
            selected.insert(url)
        }
    }

    // MARK: - Moves

    @ViewBuilder
    private func movedContent() -> some View {
        if moves.isEmpty {
            VStack(spacing: DS.Spacing.small) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(DS.Icon.medium)
                    .foregroundStyle(DS.Color.secondaryText)
                    .accessibilityHidden(true)
                Text(L10n.string("Nothing moved yet"))
                    .font(DS.Typography.headline)
                Text(L10n.string("Moves made with this app appear here until the Trash is emptied."))
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
                    Text(L10n.string("These are moves this app made. Put Back returns an item to where it came from while the Trash still holds it."))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(moves) { move in
                        moveCard(move)
                    }
                }
                .padding(DS.Spacing.xxLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The log's pending items that the Trash still holds.
    private func pendingItems(in move: ReclaimMove) -> [ReclaimMove.Item] {
        move.items.filter { $0.isPending && !missingItemIDs.contains($0.id) }
    }

    /// The log's pending items whose Trash copy is gone.
    private func missingItems(in move: ReclaimMove) -> [ReclaimMove.Item] {
        move.items.filter { $0.isPending && missingItemIDs.contains($0.id) }
    }

    private func moveCard(_ move: ReclaimMove) -> some View {
        let allRestored = move.restoredItems == move.items.count
        let pending = pendingItems(in: move)
        let missing = missingItems(in: move)
        let allMissing = !move.items.isEmpty && missing.count == move.items.count
        return VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(DateFormat.short(move.date))
                    .font(DS.Typography.callout.weight(.medium))
                Text(L10n.format(
                    "%@ · %@",
                    CountFormat.items(move.items.count),
                    ByteFormat.string(move.totalAllocatedSize)
                ))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                Spacer(minLength: DS.Spacing.small)
                if !pending.isEmpty {
                    if restoringMoveID == move.id {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(L10n.string("Put Back")) {
                        restore(move)
                    }
                    .controlSize(.small)
                    .disabled(restoringMoveID != nil)
                    .accessibilityHint(L10n.string("Moves these items out of the Trash, back to where they came from"))
                } else if allRestored {
                    Text(L10n.string("Restored"))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                } else if allMissing {
                    Text(L10n.string("Not in the Trash"))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }

            VStack(spacing: DS.Spacing.xSmall) {
                ForEach(move.items) { item in
                    let isMissing = item.isPending && missingItemIDs.contains(item.id)
                    HStack(spacing: DS.Spacing.small) {
                        Image(systemName: itemSymbol(item))
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                            Text(item.name)
                                .font(DS.Typography.callout)
                                .foregroundStyle(DS.Color.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(PathFormat.abbreviated(item.originalPath, maxLength: 72))
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Color.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: DS.Spacing.small)
                        if item.isRestored, !allRestored {
                            Text(L10n.string("Restored"))
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Color.secondaryText)
                        } else if isMissing, !allMissing {
                            Text(L10n.string("Not in the Trash"))
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Color.secondaryText)
                        }
                        Text(ByteFormat.string(item.allocatedSize))
                            .font(DS.Typography.figures)
                            .foregroundStyle(DS.Color.secondaryText)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }

            if let failure = restoreFailures[move.id] {
                Text(failure)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.small)
        .background(
            DS.Color.controlBackground,
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
    }

    private func itemSymbol(_ item: ReclaimMove.Item) -> String {
        if item.isRestored { return "arrow.uturn.backward.circle" }
        if item.isPending, missingItemIDs.contains(item.id) { return "trash.slash" }
        return "trash"
    }

    private func restore(_ move: ReclaimMove) {
        guard restoringMoveID == nil else { return }
        restoringMoveID = move.id
        restoreFailures[move.id] = nil
        Task {
            // The Trash may have changed since the tab opened; ask again before
            // offering anything to the restorer.
            await refreshTrashPresence()
            guard let current = moves.first(where: { $0.id == move.id }) else {
                restoringMoveID = nil
                return
            }
            let pending = pendingItems(in: current)
            guard !pending.isEmpty else {
                restoringMoveID = nil
                return
            }
            let request = ReclaimMove(
                id: current.id,
                date: current.date,
                rootPath: current.rootPath,
                items: pending
            )
            let failure = await onRestore(request)
            restoreFailures[move.id] = failure
            restoringMoveID = nil
        }
    }

    /// Checks the Trash for the items the log still calls pending.
    ///
    /// A Finder restore or an emptied Trash leaves the log untouched; the
    /// filesystem is the source of truth. Only missing copies are recorded here:
    /// a copy that is gone may have been put back or deleted, so it is not called
    /// restored.
    private func refreshTrashPresence() async {
        guard let reclaimLog else {
            missingItemIDs = []
            return
        }
        let moves = reclaimLog.moves
        let missing = await ReclaimTrash.missingItemIDs(in: moves)
        // A log change during the check starts another check; this result
        // describes the old snapshot.
        guard !Task.isCancelled, moves == reclaimLog.moves else { return }
        missingItemIDs = missing
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            Text(tab == .moved
                 ? L10n.string("Put Back takes an item out of the Trash; it does not empty it. Space returns when the Trash is emptied.")
                 : L10n.string("Candidates are places to look, not a recommendation. A move goes through the same confirmation as everywhere else, and the space returns when the Trash is emptied."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if tab == .moved {
                    Spacer()
                } else {
                    Text(selectionSummary)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)

                    Spacer()

                    Button {
                        onBeginReclaim(selectedNodes)
                    } label: {
                        Text(L10n.string("Move to Trash…"))
                            .frame(minWidth: DS.Size.actionMinWidth)
                    }
                    // A refresh can drop every selected path from the list; the
                    // button then has nothing to confirm.
                    .disabled(selectedNodes.isEmpty)
                    .accessibilityHint(L10n.string("Opens the confirmation for the selected items"))
                }

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
        let nodes = selectedNodes
        guard !nodes.isEmpty else { return L10n.string("Nothing selected") }
        let bytes = nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }
        return L10n.format(
            "%@ selected · %@",
            CountFormat.items(nodes.count),
            ByteFormat.string(bytes)
        )
    }

    /// What a move would take: the selected rows, reduced to the outermost
    /// paths, so a file inside a selected folder is not counted twice.
    private var selectedNodes: [ScanNode] {
        guard let report else { return [] }
        var candidates = report.groups.flatMap(\.candidates)
        if case .checked(let duplicateReport) = duplicateCheck.state {
            candidates += duplicateReport.groups.flatMap(\.candidates)
        }
        var seen = Set<URL>()
        let unique = candidates.filter { selected.contains($0.url) && seen.insert($0.url).inserted }
        let byURL = Dictionary(unique.map { ($0.url, $0.node) }, uniquingKeysWith: { first, _ in first })
        return ReclaimSelection.outermost(unique.map(\.url)).compactMap { byURL[$0] }
    }

    // MARK: - Actions

    /// Follows the tree while the sheet is open.
    ///
    /// One walk runs at a time. A watcher batch that arrives during a walk only
    /// sets `needsRefresh`: the walk is never cancelled for it, because a busy
    /// folder — the home folder is full of caches and logs — would otherwise
    /// keep cancelling the first walk forever and leave the sheet with no report.
    /// When a walk finishes, a pending refresh waits for the burst to settle and
    /// runs.
    private func analysisLoop() async {
        guard previewReport == nil else { return }
        await walk()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard needsRefresh else { continue }
            // Let a burst of changes settle, then take whatever is pending.
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            needsRefresh = false
            await walk()
        }
    }

    /// Runs one walk. Only the sheet disappearing cancels it.
    private func walk() async {
        let isFirstWalk = report == nil
        if isFirstWalk { isAnalyzing = true }

        let tree = tree
        let policy = policy
        // Only the first walk shows the bar; a refresh keeps the report up, so
        // it has no use for a hundred updates to a hidden view.
        let progress: @Sendable (Double) -> Void
        if isFirstWalk {
            walkProgress.reset()
            progress = { [walkProgress] fraction in
                Task { @MainActor in
                    walkProgress.advance(to: fraction)
                }
            }
        } else {
            progress = { _ in }
        }
        let task = Task.detached(priority: .userInitiated) {
            CleanupAnalysis.analyze(
                in: tree,
                policy: policy,
                isCancelled: { Task.isCancelled },
                progress: progress
            )
        }
        analysisTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return }
        guard let result else {
            isAnalyzing = false
            return
        }

        // A checked duplicate list describes the candidates it read. Keep it
        // while that set is unchanged; drop it when the walk found a different
        // one.
        let previousCandidates = report.map { Set($0.duplicateGroups.flatMap { $0.candidates.map(\.url) }) }
        report = result
        isAnalyzing = false
        hover.reset()

        let candidates = Set(result.duplicateGroups.flatMap { $0.candidates.map(\.url) })
        if let previousCandidates, previousCandidates != candidates {
            duplicateCheck.cancel()
        }

        // A scan with no candidates but some same-size groups opens on the tab
        // that has something to show.
        if isFirstWalk,
           tab == .candidates,
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
}

/// One destination in the cleanup header: its glyph, its name, and what the
/// view holds.
///
/// The selected destination is a signal fill with the one `onSignal` ink; the
/// rest are quiet until hovered or focused.
private struct CleanupTabButton: View {
    let tab: CleanupTab
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xSmall) {
                Image(systemName: tab.symbol)
                    .font(DS.Icon.detail)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tab.title)
                        .font(DS.Typography.caption.weight(.semibold))
                    Text(detail)
                        .font(DS.Typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            isSelected
                                ? DS.Color.onSignal.opacity(0.86)
                                : DS.Color.secondaryText
                        )
                }
                .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DS.Color.onSignal : DS.Color.primaryText)
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xSmall)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(background)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .strokeBorder(
                        isSelected ? DS.Color.onSignal : DS.Color.signal,
                        lineWidth: DS.Stroke.focus
                    )
                    .opacity(isFocused ? 1 : 0)
                    .padding(DS.Spacing.hairline)
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .focused($isFocused)
        .focusEffectDisabled()
        .accessibilityLabel(tab.title)
        .accessibilityValue(detail)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var background: Color {
        if isSelected { return DS.Color.signal }
        return DS.Color.primaryText.opacity(isHovered ? DS.Opacity.rowHover : 0)
    }
}

/// The coordinate space of a cleanup tab's scroll content.
private enum CleanupScrollSpace {
    static let content = "cleanup-content"
}

/// What restoring a cleanup row's hover needs: the pointer, the content offset,
/// and each row's place in the scroll content.
///
/// Held in a reference box rather than view state: the offset changes on every
/// frame of a scroll and is read once, when the scroll settles.
private final class CleanupScrollMetrics {
    var pointer: CGPoint?
    var contentOffset: CGFloat = 0
    var rowFrames: [URL: CGRect] = [:]
}

/// Each candidate row's place in the scroll content, keyed by its URL.
private struct CleanupRowFramesKey: PreferenceKey {
    static let defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// The explorer's hover rule on a cleanup scroll view: no row lights while the
/// content moves, and the row under the pointer is named again when it settles.
private struct CleanupScrollHover: ViewModifier {
    let hover: CleanupHover
    let metrics: CleanupScrollMetrics

    func body(content: Content) -> some View {
        content
            .modifier(ScrollActivityReporter(onChange: { scrolling in
                hover.setSuspended(scrolling)
                if !scrolling { restore() }
            }))
            .modifier(ScrollOffsetReader { offset in
                metrics.contentOffset = offset
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): metrics.pointer = point
                case .ended: metrics.pointer = nil
                }
            }
    }

    private func restore() {
        guard let pointer = metrics.pointer,
              let url = CleanupHoverTarget.row(
                  in: metrics.rowFrames,
                  pointer: pointer,
                  contentOffset: metrics.contentOffset
              ) else { return }
        hover.set(url, true)
    }
}

/// One cleanup candidate.
///
/// The row reads the shared hover itself, so the pointer crossing it re-renders
/// the rows rather than the sheet, and publishes its place in the scroll content
/// so the hover can return to it when a scroll settles.
private struct CleanupCandidateRow: View {
    let candidate: CleanupCandidate
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(CleanupHover.self) private var hover

    var body: some View {
        let isHovered = hover.url == candidate.url
        Button(action: onToggle) {
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
                Text(ByteFormat.string(candidate.allocatedSize))
                    .font(DS.Typography.figures)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xSmall)
            .dsHoverableRow(isHovered: isHovered, radius: DS.Radius.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hover.set(candidate.url, inside) }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CleanupRowFramesKey.self,
                    value: [candidate.url: proxy.frame(in: .named(CleanupScrollSpace.content))]
                )
            }
        }
        .accessibilityLabel(L10n.format("%@, %@", candidate.name, ByteFormat.string(candidate.allocatedSize)))
        .accessibilityHint(L10n.string(candidate.isDirectory ? "A folder; moves everything inside it" : "A file"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
