import SwiftUI
import AppKit
import DiskCore

/// Screen C — analysis results, and the live state while a scan runs.
///
/// One screen serves both roles, chart first. While a scan runs the top of the
/// screen shows the honest progress — a determinate bar with a percentage only
/// when the engine reports a reliable fraction, otherwise an indeterminate
/// indicator, never a fabricated number — and the results fill in as the
/// engine's progressive snapshots arrive. Once settled, the chart and explorer
/// take the whole screen: a compact header line names the scanned location and
/// its size, a directory explorer carries search/sort/filter and file details,
/// and the footer holds the single access notice, with its count chip when the
/// notice has been dismissed. An interactive sunburst (click a folder to drill
/// down, with the toolbar's location — title, path and Back — following the
/// depth), Reveal in Finder, rescan, and report export round it out.
@MainActor
public struct ResultsView: View {
    @State private var viewModel: ScanViewModel

    // Chart / explorer navigation
    @State private var breadcrumb: [ScanNode] = []
    @State private var selectedNode: ScanNode?

    // Explorer controls
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .size
    @State private var filterCategory: FileCategory?
    /// Which list the explorer shows: the folder in the chart, or the engine's
    /// largest files and folders across the whole scan.
    @State private var explorerMode: ExplorerMode = .folder

    /// Holds the visible rows between changes of the inputs that decide them.
    ///
    /// A view body can run many times a second — a hover, a click, a resize, a
    /// scan still streaming progress — while the list itself only changes when
    /// its inputs do. Memoising the derived rows keeps the filtering, ordering
    /// and formatting off the redraw path.
    @State private var rowsCache = ExplorerRowsCache()

    /// Holds the chart colour index between changes of the inputs that decide it.
    /// It is the chart's own layout of the focused directory, so a drill-down
    /// rebuilds it and the explorer's icons and the chart's wedges are always read
    /// off the same rings.
    @State private var nodeColorsCache = NodeColorsCache()

    /// The one hovered node, shared by the explorer rows and the chart, so
    /// hovering either side lights the other. Matched by URL, never by identity.
    ///
    /// It is held as an observed reference rather than as plain view state so that
    /// a pointer crossing the explorer's rows re-renders only what reads it — the
    /// list and the chart — and leaves the rest of the screen, from its toolbar to
    /// its footer, with the views it already has.
    @State private var hover = ChartHover()

    // Access notice
    @State private var accessNoticeExpanded = false
    @State private var accessNoticeDismissed = AccessNoticeDismissal.isDismissed
    /// Full Disk Access is assumed absent until the off-main probe says
    /// otherwise, so a slow probe fails toward informing rather than hiding.
    @State private var fullDiskAccessGranted = false

    // Reclaim
    @State private var reclaimCandidates: [ReclaimCandidate] = []
    @State private var reclaimRefusal: ReclaimRefusal?
    @State private var activeSheet: ResultsSheet?
    @State private var isCheckingReclaim = false
    @State private var isTrashing = false
    /// A token that makes a slow guard probe land only on the request that asked
    /// for it, never on a later selection the sheet is now about.
    @State private var reclaimRequestID = UUID()

    public init(viewModel: ScanViewModel = ScanViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    // MARK: - Derived data

    /// The results to render: the terminal summary once the scan has settled,
    /// otherwise the newest in-flight snapshot so the screen fills in while the
    /// scan runs.
    private var summary: ScanSummary? { viewModel.liveSummary }

    /// Whether a scan is still running and the visible results will keep growing.
    private var isLiveScan: Bool { viewModel.isScanning }

    /// The scanned root's own node, present once the traversal has finalized it.
    ///
    /// Matched by path rather than by URL equality: a node's URL records whether
    /// it is a directory, and the scanned location the summary carries is the
    /// request's own URL, which need not. Two URLs for the same folder would then
    /// compare unequal, and the screen would show an empty tree.
    private func rootNode(in summary: ScanSummary) -> ScanNode? {
        let rootPath = summary.root.standardizedFileURL.path
        return summary.largestDirectories.first { $0.url.standardizedFileURL.path == rootPath }
    }

    /// The scan root's own entries, as known right now.
    ///
    /// A settled summary carries the root node with its complete child list. A
    /// live one does not: the root's node is minted only once its whole subtree
    /// has finished, and the folders that take longest to walk are the ones the
    /// screen needs first. The engine therefore reports the root's entries itself
    /// from the moment they are discovered — each folder with the bytes counted
    /// under it so far — so the chart and the list fill in from the first
    /// snapshot instead of waiting for whole folders to complete.
    private var rootNodes: [ScanNode] {
        guard let s = summary else { return [] }
        if let root = rootNode(in: s) { return root.children }
        return s.rootChildren
    }

    /// The nodes currently shown by the chart / explorer (the drill-down target).
    private var currentChildren: [ScanNode] {
        guard let opened = breadcrumb.last else { return rootNodes }
        return resolvedFocus?.children ?? opened.children
    }

    /// The focused folder's entries that have something to show — the ones the
    /// explorer lists and the chart draws.
    private var presentableChildren: [ScanNode] {
        currentChildren.filter(\.isPresentable)
    }

    /// The nodes behind the two "largest" lists, straight from the engine's own
    /// ranking. A folder scan's root is the whole scan and is left out of the top
    /// folders, where it would only repeat the total above the list.
    private var topNodes: [ScanNode] {
        guard let summary else { return [] }
        switch explorerMode {
        case .folder:
            return []
        case .topFiles:
            return summary.largestFiles
        case .topFolders:
            let rootPath = summary.root.standardizedFileURL.path
            return summary.largestDirectories.filter { $0.url.standardizedFileURL.path != rootPath }
        }
    }

    /// The folder on screen, resolved against the results being rendered.
    ///
    /// The breadcrumb's own values are the snapshots the folders were opened
    /// from, and a folder opened while the scan is still walking it keeps filling
    /// in afterwards. Resolving it by URL from the scanned location down means
    /// the list inside it is the newest entries the engine has rather than the
    /// ones that were there at the click. A crumb that is no longer on screen
    /// resolves to nothing, and the folder keeps the entries it was opened with.
    private var resolvedFocus: ScanNode? {
        guard !breadcrumb.isEmpty else { return nil }
        var level = rootNodes
        var resolved: ScanNode?
        for crumb in breadcrumb {
            guard let match = level.first(where: { $0.url == crumb.url }) else { return nil }
            resolved = match
            level = match.children
        }
        return resolved
    }

    /// Each node's colour in the chart, keyed by path, across every ring the
    /// chart draws from the focused directory outwards.
    ///
    /// The chart colours a node by where it sits in the tree, and the icons in
    /// the explorer and the detail pane are the same node as a wedge, so they
    /// resolve their tint from here rather than from a palette of their own. The
    /// index is the chart's own layout of the focused directory, so it holds a
    /// colour for every entry a row or the detail pane can show — including the
    /// descendants the chart draws on its outer rings.
    ///
    /// Derived work — the chart's layout walk — so it is computed once per change
    /// of the inputs that decide it and reused while they hold.
    private var nodeColors: NodeColors {
        nodeColorsCache.colors(
            for: NodeColorsKey(
                revision: viewModel.resultsRevision,
                focused: breadcrumb.last?.url.path ?? ""
            ),
            build: { buildNodeColors(of: currentChildren) }
        )
    }

    /// The icons' colours, read off the very ring layout the chart draws.
    ///
    /// A node's colour follows its siblings and the ring it is drawn on, and the
    /// chart decides both — so the chart draws the index instead of the two
    /// deriving it separately. Drilling into a folder re-roots the chart, and the
    /// index with it: the folder's children open colour families of their own on
    /// ring 1 rather than keeping the family hue the folder wore one ring out.
    private func buildNodeColors(of children: [ScanNode]) -> NodeColors {
        NodeColors(colors: SunburstLayout.fillsByPath(roots: children))
    }

    /// The explorer's visible rows: the focused folder's entries, filtered,
    /// ordered and resolved for display.
    ///
    /// This is derived work — filtering, sorting and formatting every entry — so
    /// it is computed once per change of the inputs that decide it and reused
    /// while they hold. Hovering or selecting a row changes none of those inputs,
    /// so it never re-derives the list.
    private var visibleRows: [ExplorerRow] {
        let key = ExplorerRowsKey(
            revision: viewModel.resultsRevision,
            breadcrumb: breadcrumb.map(\.id),
            search: searchText,
            category: filterCategory,
            sort: sortOrder,
            mode: explorerMode
        )
        return rowsCache.rows(for: key) {
            let colors = nodeColors
            let nodes: [ScanNode]
            switch explorerMode {
            case .folder:
                nodes = ExplorerQuery.entries(in: currentChildren, search: searchText,
                                              category: filterCategory, sort: sortOrder)
            case .topFiles, .topFolders:
                nodes = ExplorerQuery.ranked(topNodes, search: searchText)
            }
            return nodes.map {
                ExplorerRow(node: $0, colors: colors, showsLocation: explorerMode != .folder)
            }
        }
    }

    private var isFiltering: Bool {
        explorerMode == .folder ? (!searchText.isEmpty || filterCategory != nil) : !searchText.isEmpty
    }

    /// The inputs that decide which rows are on screen. When any of them changes
    /// the list is reshuffled, so a hover is dropped rather than left pointing
    /// at a row that is no longer rendered.
    private var rowSetKey: ExplorerRowKey {
        ExplorerRowKey(search: searchText, category: filterCategory, sort: sortOrder, mode: explorerMode)
    }

    /// Honest copy for an empty chart — an empty result set means something
    /// different while a scan is still filling in than after it has settled.
    private var chartEmptyMessage: String {
        isLiveScan ? "Waiting for the first folders…" : "Nothing to show here"
    }

    /// Honest copy for an empty explorer list, in the same two situations.
    private var listEmptyMessage: String {
        if explorerMode != .folder {
            if isFiltering { return "No matches in the top items" }
            if isLiveScan { return "Waiting for the first items…" }
            return explorerMode == .topFiles ? "No files to rank" : "No folders to rank"
        }
        if isLiveScan && !isFiltering { return "Waiting for the first items…" }
        if isFiltering { return "No matches" }
        // The folder holds entries, but none of them has bytes to list.
        if !currentChildren.isEmpty { return "Nothing here has a size" }
        return "This folder is empty"
    }

    // MARK: - Access notice

    private var accessPresentation: ScanIssuesPresentation { viewModel.issuesPresentation }

    /// Whether the scan skipped anything worth accounting for: restricted
    /// locations, or other unreadable items. The notice is never silent.
    private var showsAccessNotice: Bool {
        accessPresentation.restrictedLocationCount > 0 || accessPresentation.hasRows
    }

    private var showsAccessRow: Bool { showsAccessNotice && !accessNoticeDismissed }
    private var showsAccessChip: Bool { showsAccessNotice && accessNoticeDismissed }

    // MARK: - Body

    public var body: some View {
        Group {
            if summary != nil || viewModel.isScanning {
                content
            } else {
                ContentUnavailableView("No results", systemImage: "chart.pie", description: Text("Run a scan to see storage analysis."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(hover)
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onChange(of: rowSetKey) { _, _ in
            // The row under the pointer can leave the screen without an exit
            // event when the visible set changes, so the shared hover is dropped
            // rather than left pointing at a row that is no longer rendered.
            hover.url = nil
        }
        .onChange(of: explorerMode) { _, newMode in
            // The list's scope changed, so a selection, a hover, and a search
            // that were about the old list would otherwise point at rows that are
            // no longer on screen.
            hover.url = nil
            selectedNode = nil
            searchText = ""
            filterCategory = nil
            // The chart shows a folder; the largest lists are about the whole
            // scan. Returning the chart to the scanned location keeps the map and
            // the list talking about the same thing.
            if newMode != .folder {
                breadcrumb.removeAll()
            }
        }
        .task(id: viewModel.scanRun) {
            // Re-run for every scan and on Rescan: grant Full Disk Access in
            // System Settings, hit Rescan, and the notice must disappear.
            fullDiskAccessGranted = await FullDiskAccessProbe.isGranted()
        }
        .overlay(alignment: .bottom) {
            if let notice = viewModel.reclaimNotice {
                ReclaimBanner(
                    tone: notice.tone,
                    message: notice.message,
                    showsShowTrash: notice.showsShowTrash,
                    onShowTrash: openTrash,
                    onRescan: rescan,
                    onDismiss: viewModel.dismissReclaimNotice
                )
                .padding(.horizontal, DS.Spacing.large)
                .padding(.bottom, DS.Spacing.small)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.reclaimNotice)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .reclaim:
                ReclaimSheet(
                    candidates: reclaimCandidates,
                    refusal: reclaimRefusal,
                    isChecking: isCheckingReclaim,
                    isWorking: isTrashing,
                    onCancel: { activeSheet = nil },
                    onConfirm: confirmReclaim
                )
            case .coverage:
                if let summary {
                    CoverageSheet(summary: summary, isLive: viewModel.isScanning)
                }
            }
        }
        .interactiveDismissDisabled(isTrashing)
        .toolbar {
            // One step back, wherever the screen is: out of the folder the chart
            // is drawn from, and from the scanned location itself to source
            // selection. There is no separate Home action because this is the
            // whole of what leaving the screen means.
            ToolbarItem(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .help(isDrilledIn ? "Show the enclosing folder" : "Back to source selection")
                .accessibilityLabel("Back")
                .accessibilityHint(isDrilledIn
                                   ? "Shows the folder that holds this one"
                                   : "Shows source selection; a scan that is running keeps running")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    activeSheet = .coverage
                } label: {
                    Label("Coverage", systemImage: "info.circle")
                }
                .help("What this scan counted, and what it did not")
                .disabled(summary == nil)

                Button {
                    rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.counterclockwise")
                }
                .help(viewModel.isScanning
                      ? "A scan is already running — cancel it first to start again"
                      : "Scan the current location again")
                .disabled(viewModel.isScanning)

                Menu {
                    Button("Export as JSON…") { if let s = summary { ReportExport.exportJSON(summary: s) } }
                    Button("Export as CSV…") { if let s = summary { ReportExport.exportCSV(summary: s) } }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export the analysis report")
                .disabled(summary == nil)
            }
        }
    }

    /// The scanned location's name — the root of the toolbar's trail. `nil` until
    /// a scan has a root to name.
    private var scannedRootName: String? {
        let root = summary?.root ?? viewModel.currentRoot
        guard let root else { return nil }
        return LocationName.of(root)
    }

    /// Whether the user has opened a folder below the scanned location, which is
    /// what a step back up is for.
    private var isDrilledIn: Bool { !breadcrumb.isEmpty }

    /// Window title — the folder on screen: the crumb the user opened, otherwise
    /// the scanned location, otherwise the app name.
    private var windowTitle: String {
        breadcrumb.last?.name ?? scannedRootName ?? "WillyDisk"
    }

    /// Window titlebar subtitle — the folder's full path, so the toolbar's trail
    /// follows a drill-down rather than staying on the scanned root.
    private var windowSubtitle: String {
        breadcrumb.last?.url.path ?? (summary?.root ?? viewModel.currentRoot)?.path ?? ""
    }

    /// The results layout: the split panes fill the screen, and the footer carries
    /// the dismissed notice's chip and then the access notice.
    ///
    /// Every band is present from the moment the screen appears — nothing is
    /// inserted above or below the panes as a scan starts, streams results in, or
    /// settles — so the panes hold one geometry throughout. The live scan's
    /// progress rides in the chart pane's own strip. The bands are told apart by
    /// their own spacing and fills, not by rules.
    private var content: some View {
        VStack(spacing: 0) {
            splitPanes
            noticeChipStrip
            if showsAccessRow {
                accessNoticeRow
            }
        }
    }

    /// The chart and explorer panes.
    ///
    /// The explorer holds a fixed share of the window and the chart takes the
    /// rest, so the map and the list keep their proportion at every window size:
    /// there is no divider between them to drag, and the panes meet with no seam
    /// because they are laid out edge to edge on one surface.
    private var splitPanes: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                chartPane
                explorerPane
                    .frame(width: geometry.size.width * DS.Size.explorerPaneWidthFraction)
            }
        }
    }

    // MARK: - Footer

    /// The dismissed notice's count chip, at the trailing edge of the footer.
    ///
    /// The band is always on screen, so the panes above it never resize: it holds
    /// its height whether or not the notice has been dismissed, and before a scan
    /// reports anything there is simply no chip.
    private var noticeChipStrip: some View {
        HStack(alignment: .bottom, spacing: DS.Spacing.large) {
            Spacer(minLength: 0)
            if showsAccessChip {
                AccessNoticeChip(
                    count: accessPresentation.noticeCount,
                    symbolName: accessPresentation.noticeSymbolName,
                    label: accessPresentation.noticeHeadline
                ) {
                    setAccessNotice(dismissed: false)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: DS.Size.storageStripMinHeight, alignment: .bottom)
    }

    /// The single merged access notice — the last row on screen.
    private var accessNoticeRow: some View {
        AccessNoticeRow(
            presentation: accessPresentation,
            isFullDiskAccessGranted: fullDiskAccessGranted,
            isExpanded: $accessNoticeExpanded
        ) {
            setAccessNotice(dismissed: true)
        }
    }

    private func setAccessNotice(dismissed: Bool) {
        accessNoticeDismissed = dismissed
        AccessNoticeDismissal.isDismissed = dismissed
        // Reopening always starts collapsed, so the notice gives back the most
        // space until the user asks for the detail.
        if !dismissed { accessNoticeExpanded = false }
    }

    // MARK: - Scan-status strip

    /// The slim strip along the bottom of the chart pane that carries the scan's
    /// honest progress.
    ///
    /// The strip holds its height whether or not a scan is running — only its
    /// contents fade in and out — so starting or finishing a scan never resizes
    /// the chart above it. Cancel Scan lives here, reachable for the whole scan.
    ///
    /// The readout sits in a capsule centered under the chart, never stretched
    /// across the pane: a status line reaching both of the wide chart's edges
    /// reads as a band of its own instead of belonging to the chart above it. The
    /// capsule hugs its contents, so it leaves nothing behind once the scan ends.
    ///
    /// The capsule is drawn only while there is a readout to hold. The strip
    /// keeps its height either way, so the chart above never resizes; an empty
    /// capsule would just be a grey pill with nothing in it.
    ///
    /// The capsule wears a grey of its own rather than `DS.Color.controlBackground`,
    /// which resolves to within a few percent of the window background and all but
    /// disappears behind the status it is meant to group.
    private var scanStatusStrip: some View {
        HStack(spacing: 0) {
            if isLiveScan {
                scanStatusBanner
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(Self.stripFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.scanStatusStripHeight)
        .animation(.easeInOut(duration: 0.2), value: isLiveScan)
    }

    /// The scan-status capsule's own grey, resolved per appearance.
    ///
    /// Dark enough to read as a surface behind the status, and dark enough in the
    /// dark appearance to sit above the window rather than sink into it. Both
    /// values hold better than 1.3:1 against `windowBackground`, which is the
    /// difference the eye needs to see a boundary with no edge of its own.
    private static let stripFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.24, green: 0.24, blue: 0.26, alpha: 1)
            : NSColor(srgbRed: 0.86, green: 0.86, blue: 0.87, alpha: 1)
    })

    /// The in-progress readout: an honest status indicator, the work counted so
    /// far, and the cancel action. Deliberately small — no running path, no
    /// elapsed clock.
    ///
    /// The group is sized to its contents, so the strip's capsule frames the
    /// readout and the cancel action together rather than leaving a run of empty
    /// fill between them.
    private var scanStatusBanner: some View {
        HStack(spacing: DS.Spacing.medium) {
            scanStatusIndicator
            Text("\(CountFormat.files(viewModel.filesScanned)) · \(ByteFormat.string(viewModel.displayedTotal))")
                .font(DS.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            cancelScanButton
        }
        .accessibilityElement(children: .contain)
    }

    /// Cancel Scan, as an inset chip inside the strip's capsule.
    ///
    /// A `.bordered` button on the capsule takes the window's control fill, which
    /// is the capsule's own fill at this size, leaving the label to read as bare
    /// text on the strip. The chip fills with `windowBackground` instead, so it
    /// separates from the capsule the way a bordered control separates from a
    /// toolbar.
    private var cancelScanButton: some View {
        Button(role: .cancel) {
            viewModel.cancel()
        } label: {
            Label("Cancel Scan", systemImage: "stop.fill")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.primaryText)
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.xxSmall)
                .background(DS.Color.windowBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("Stop the scan; the results gathered so far are kept")
    }

    /// Progress read straight from the engine.
    ///
    /// A percentage appears only when `fractionCompleted` is present; otherwise
    /// the indicator is honestly indeterminate, because the engine reports no
    /// reliable total and we do not fabricate one.
    @ViewBuilder
    private var scanStatusIndicator: some View {
        if let fraction = viewModel.progress?.fractionCompleted {
            HStack(spacing: DS.Spacing.small) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: DS.Size.rowProgressWidth)
                Text(percentText(fraction))
                    .font(DS.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.primaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scan \(percentText(fraction)) complete")
        } else {
            HStack(spacing: DS.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning, progress not yet measurable")
        }
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    // MARK: - Chart pane

    private var chartPane: some View {
        VStack(spacing: 0) {
            if currentChildren.isEmpty {
                emptyChart
            } else {
                SunburstView(
                    nodes: currentChildren,
                    centerLabel: breadcrumb.last?.name ?? scannedRootName ?? "Root",
                    selectedNodeURL: selectedNode?.url,
                    hoveredURL: $hover.url
                ) { node in
                    select(node)
                }
                .padding(DS.Spacing.medium)
            }
            scanStatusStrip
        }
    }

    /// What the chart pane shows before there is anything to draw, which is a
    /// live scan's first moments or a scan that found nothing.
    private var emptyChart: some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: isLiveScan ? "hourglass" : "chart.pie")
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.tertiaryText)
            Text(chartEmptyMessage)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Explorer pane

    private var explorerPane: some View {
        VStack(spacing: 0) {
            compactHeader
            explorerModeBar
            topListCaption
            explorerToolbar

            ScrollView {
                contentsList
            }

            if let node = selectedNode {
                detailPane(node)
            }
        }
    }

    /// The switch between the folder in the chart and the two largest lists.
    private var explorerModeBar: some View {
        Picker("Explorer view", selection: $explorerMode) {
            ForEach(ExplorerMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.xSmall)
        .accessibilityLabel("Explorer view")
    }

    /// Says what the list is ranked by, and — while a search is on — that the
    /// search covers the top items rather than every file on the disk.
    @ViewBuilder
    private var topListCaption: some View {
        if let text = topListCaptionText {
            Text(text)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.small)
                .padding(.bottom, DS.Spacing.xSmall)
        }
    }

    private var topListCaptionText: String? {
        guard explorerMode != .folder else { return nil }
        guard let s = summary else { return nil }
        let n = topNodes.count
        if n == 0 {
            return isLiveScan ? "Ranking items by size…" : nil
        }
        let searching = !searchText.isEmpty
        switch explorerMode {
        case .folder:
            return nil
        case .topFiles:
            if searching { return "Matches in the \(n) largest files by size" }
            if n == s.fileCount { return "All \(n) files, largest first" }
            return "The largest \(n) files by size · \(s.fileCount) files scanned"
        case .topFolders:
            let folders = max(0, s.directoryCount - 1)
            if searching { return "Matches in the \(n) largest folders by size" }
            if n == folders { return "All \(n) folders, largest first" }
            return "The largest \(n) folders by size · \(folders) folders scanned"
        }
    }

    /// The location and its total on the first line, the honest counts on the
    /// second, and — for a scan that stopped early — the warning on a third, so
    /// it shares a row with nothing and can be read at a glance.
    ///
    /// It is always present — before a scan's first snapshot the location and
    /// totals come from the engine's live counters — so its values tick up in
    /// place and nothing appears or disappears under the chart.
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.medium) {
                Text(windowTitle)
                    .font(DS.Typography.title2)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Spacing.small)
                Text(ByteFormat.string(viewModel.displayedTotal))
                    .font(DS.Typography.title2)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.primaryText)
            }
            // Counted the way the list counts: an entry with nothing in it is one
            // the explorer does not list, so it does not read as an item here.
            Text(countsText)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
            provenanceLine
            if viewModel.resultsAreStale {
                StaleResultsBadge(onRescan: rescan)
            }
            if viewModel.stoppedEarly { stoppedEarlyNote }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Counts for the list's scope: the folder's own entries while the chart and
    /// list agree on a folder, and the whole scan's counts while the list is one
    /// of the largest lists.
    private var countsText: String {
        if explorerMode == .folder {
            return "\(CountFormat.files(viewModel.filesScanned)) · \(CountFormat.items(presentableChildren.count))"
        }
        guard let s = summary else { return CountFormat.files(viewModel.filesScanned) }
        // The scan root is a folder in the summary, but it is the scan itself and
        // never one of its own subfolders, so the largest-list counts leave it out.
        return "\(CountFormat.files(s.fileCount)) · \(CountFormat.folders(max(0, s.directoryCount - 1)))"
    }

    /// When the results were gathered and how long the scan took, so the numbers
    /// are never read as current. A live scan states its start and keeps the
    /// elapsed time moving; a settled one states both and stops.
    @ViewBuilder
    private var provenanceLine: some View {
        if isLiveScan, let started = viewModel.scanStartedAt ?? summary?.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                provenanceText(ScanProvenance.live(startedAt: started, now: context.date))
            }
        } else if let s = summary {
            provenanceText(ScanProvenance.settled(startedAt: s.startedAt, finishedAt: s.finishedAt))
        }
    }

    private func provenanceText(_ text: String) -> some View {
        Text(text)
            .font(DS.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(DS.Color.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The settled notice for a scan that stopped before it had covered the whole
    /// root. The totals above it are real, but only part of the picture, so the
    /// notice names that before the numbers are read.
    ///
    /// The toolbar already carries Rescan for every state, so the warning is a
    /// statement rather than a control.
    private var stoppedEarlyNote: some View {
        HStack(spacing: DS.Spacing.xSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Icon.detail)
                .foregroundStyle(DS.Color.warning)
                .accessibilityHidden(true)
            Text("Stopped early — these results are partial")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.warning)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var explorerToolbar: some View {
        HStack(spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.xSmall) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DS.Color.secondaryText)
                TextField(searchPrompt, text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DS.Color.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, 5)
            .background(DS.Color.controlBackground, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))

            if explorerMode == .folder {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Menu {
                    Button("All Categories") { filterCategory = nil }
                    Divider()
                    ForEach(FileCategory.allCases, id: \.self) { category in
                        Button(category.displayName) { filterCategory = category }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter by category")
            }
        }
        .padding(DS.Spacing.small)
    }

    private var searchPrompt: String {
        switch explorerMode {
        case .folder: "Search"
        case .topFiles: "Search top files"
        case .topFolders: "Search top folders"
        }
    }

    private var contentsList: some View {
        // The list reads the shared hover itself, so a pointer crossing its rows
        // rebuilds the rows that changed and the chart, and leaves the rest of the
        // screen where it is.
        ContentsList(
            rows: visibleRows,
            emptyMessage: listEmptyMessage,
            selectedURL: selectedNode?.url,
            onSelect: { node in select(node) },
            onReclaim: { node in requestReclaim([node]) },
            onReveal: revealInFinder
        )
    }

    // MARK: - Detail pane

    private func detailPane(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    // Drawn at the wedge's own opacity so a node's icon and its
                    // wedge land on the very same colour, background included.
                    .foregroundStyle(nodeColors.color(for: node.url).color)
                    .opacity(DS.Sunburst.fillOpacity)
                Text(node.name)
                    .font(DS.Typography.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    revealInFinder(node)
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            detailRow("Path", node.url.path)
            detailRow("Kind", node.category.displayName)
            detailRow("Size", ByteFormat.exact(node.logicalSize))
            detailRow("On disk", ByteFormat.exact(node.allocatedSize))
            if node.isDirectory {
                detailRow("Contents", "\(CountFormat.files(node.fileCount)) · \(CountFormat.folders(node.directoryCount))")
            }
            if let modified = node.modifiedAt {
                detailRow("Modified", DateFormat.short(modified))
            }
            if node.isSymlink {
                detailRow("Type", "Symbolic link")
            }
            if !node.isAccessible {
                detailRow("Access", node.errorMessage ?? "Inaccessible")
                    .foregroundStyle(DS.Color.warning)
            }

            Button(role: .destructive) {
                requestReclaim([node])
            } label: {
                Label("Move to Trash…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, DS.Spacing.xSmall)
        }
        .padding(DS.Spacing.medium)
        .background(DS.Color.controlBackground.opacity(0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.medium) {
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .frame(width: DS.Size.detailLabelWidth, alignment: .leading)
            Text(value)
                .font(DS.Typography.callout)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
        }
    }

    // MARK: - Actions

    private func select(_ node: ScanNode) {
        if node.isDirectory {
            hover.url = nil
            breadcrumb.append(node)
            selectedNode = nil
            explorerMode = .folder
        } else {
            selectedNode = node
        }
    }

    /// Steps back one place: out of the folder the chart is drawn from, and from
    /// the scanned location itself to source selection. The crumb that is dropped
    /// is the one the chart is drawn from, so the chart, the explorer and the
    /// toolbar trail move together.
    private func goBack() {
        guard isDrilledIn else {
            goHome()
            return
        }
        hover.url = nil
        selectedNode = nil
        breadcrumb.removeLast()
    }

    private func revealInFinder(_ node: ScanNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    /// Opens the confirmation sheet for the items just chosen.
    ///
    /// The guard's answer is asked off the main thread and arrives with the
    /// sheet already up: a refused item still gets an explanation rather than a
    /// context menu entry that silently does nothing.
    private func requestReclaim(_ nodes: [ScanNode]) {
        let candidates = nodes.map(ReclaimCandidate.init)
        guard !candidates.isEmpty else { return }

        let requestID = UUID()
        reclaimRequestID = requestID
        reclaimCandidates = candidates
        reclaimRefusal = nil
        isCheckingReclaim = true
        activeSheet = .reclaim

        Task {
            var refusal: ReclaimRefusal?
            for candidate in candidates {
                if let answer = await viewModel.reclaimRefusal(for: candidate.url) {
                    refusal = answer
                    break
                }
            }
            guard reclaimRequestID == requestID else { return }
            reclaimRefusal = refusal
            isCheckingReclaim = false
        }
    }

    private func confirmReclaim() {
        guard !isTrashing else { return }
        isTrashing = true
        let candidates = reclaimCandidates
        Task {
            await viewModel.reclaim(candidates)
            isTrashing = false
            activeSheet = nil
        }
    }

    private func openTrash() {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(trash)
    }

    private func rescan() {
        hover.url = nil
        breadcrumb.removeAll()
        selectedNode = nil
        searchText = ""
        filterCategory = nil
        explorerMode = .folder
        viewModel.rescan()
    }

    private func goHome() {
        // Only the screen changes. A scan that is still running keeps running in
        // the background and its results stay on the engine's slot, so the source
        // screen can show it and View can open it again; the scan is untouched.
        hover.url = nil
        breadcrumb.removeAll()
        selectedNode = nil
        searchText = ""
        filterCategory = nil
        explorerMode = .folder
        viewModel.showHome()
    }
}

// MARK: - Supporting types

/// The one hovered node, shared by the explorer rows and the chart.
///
/// It is a reference the two panes observe rather than a value the screen holds,
/// so a pointer crossing the explorer's rows re-renders the list and the chart and
/// leaves every other part of the screen as it was. Matched by URL, never by
/// identity: the engine rebuilds every node value on each progressive snapshot.
@MainActor
@Observable
final class ChartHover {
    var url: URL?

    /// Publishes the row under the pointer as the one hovered node. Only the row
    /// that is still hovered clears it, so moving between rows never leaves the
    /// highlight stuck on the wrong one.
    func set(_ url: URL, _ hovering: Bool) {
        if hovering {
            if self.url != url { self.url = url }
        } else if self.url == url {
            self.url = nil
        }
    }
}

/// The explorer's rows.
///
/// The list is the one part of the screen that reads the shared hover, so it lives
/// in a view of its own: a pointer crossing a row rebuilds this list — and the
/// chart that shares the hover — and nothing else the screen shows.
private struct ContentsList: View {
    let rows: [ExplorerRow]
    let emptyMessage: String
    let selectedURL: URL?
    let onSelect: (ScanNode) -> Void
    let onReclaim: (ScanNode) -> Void
    let onReveal: (ScanNode) -> Void

    @Environment(ChartHover.self) private var hover

    var body: some View {
        LazyVStack(spacing: 0) {
            if rows.isEmpty {
                VStack(spacing: DS.Spacing.small) {
                    Text(emptyMessage)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xxLarge)
            } else {
                ForEach(rows, id: \.url) { row in
                    NodeRow(
                        row: row,
                        isSelected: selectedURL == row.url,
                        isHovered: hover.url == row.url,
                        action: { onSelect(row.node) },
                        onHover: { hovering in hover.set(row.url, hovering) }
                    )
                    // Opting the row into equatable rendering is what makes its
                    // `Equatable` conformance do anything: without it SwiftUI
                    // rebuilds every row on each pass, so a hover or a selection
                    // would re-render the whole list.
                    .equatable()
                    .contextMenu {
                        Button("Move to Trash…", role: .destructive) {
                            onReclaim(row.node)
                        }
                        Button("Reveal in Finder") {
                            onReveal(row.node)
                        }
                    }
                }
            }
        }
    }
}

/// The one sheet this screen can present. Keeping it single avoids stacking
/// two presentations on the same view, where only the last one is reliable.
private enum ResultsSheet: String, Identifiable {
    case reclaim
    case coverage

    var id: String { rawValue }
}

/// Which list the explorer is showing.
private enum ExplorerMode: String, CaseIterable, Identifiable {
    case folder
    case topFiles
    case topFolders

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: "This Folder"
        case .topFiles: "Top Files"
        case .topFolders: "Top Folders"
        }
    }
}

/// The explorer inputs that decide which rows are on screen.
private struct ExplorerRowKey: Equatable {
    var search: String
    var category: FileCategory?
    var sort: SortOrder
    var mode: ExplorerMode
}

/// The inputs the visible rows are derived from.
///
/// A change to any of them — new scan data, a different folder, a search, filter
/// or ordering, or a different list — is what makes the list stale. Nothing else
/// is.
private struct ExplorerRowsKey: Equatable {
    var revision: Int
    var breadcrumb: [UUID]
    var search: String
    var category: FileCategory?
    var sort: SortOrder
    var mode: ExplorerMode
}

/// Keeps the explorer's visible rows while their inputs stay the same.
///
/// Deriving the rows is the costly part of drawing the explorer — every entry is
/// filtered, ordered and resolved for display — yet it is pure work on inputs a
/// view body rarely changes. Holding the last result beside the key that produced
/// it leaves the redraw path with nothing to do but draw the rows already in hand.
@MainActor
private final class ExplorerRowsCache {
    private var key: ExplorerRowsKey?
    private var rows: [ExplorerRow] = []

    func rows(for key: ExplorerRowsKey, build: () -> [ExplorerRow]) -> [ExplorerRow] {
        if key == self.key { return rows }
        let fresh = build()
        self.key = key
        self.rows = fresh
        return fresh
    }
}

/// What makes the chart colour index stale: new scan data, or a different
/// directory focused in the chart. Nothing else.
private struct NodeColorsKey: Equatable {
    var revision: Int
    var focused: String
}

/// Keeps the chart colour index while its inputs stay the same.
///
/// Laying out the chart's rings is pure work on inputs a view body rarely
/// changes, so the result is held beside the key that produced it and reused for
/// as long as they hold.
@MainActor
private final class NodeColorsCache {
    private var key: NodeColorsKey?
    private var colors = NodeColors(colors: [:])

    func colors(for key: NodeColorsKey, build: () -> NodeColors) -> NodeColors {
        if key == self.key { return colors }
        let fresh = build()
        self.key = key
        self.colors = fresh
        return fresh
    }
}

/// Every node the chart draws, keyed by path.
///
/// A node the chart does not draw — an entry with no bytes, or one below the
/// chart's density limits — has no entry here and is drawn neutral, so the icons
/// never claim a colour the chart does not show.
private struct NodeColors {
    var colors: [String: ChartFill]

    func color(for url: URL) -> ChartFill {
        colors[url.path] ?? .neutral
    }
}

/// One explorer row, resolved from a node once per list change.
///
/// The row body draws these values directly, so the comparatively costly work —
/// resolving the node's chart colour, composing its subtitle, formatting its size
/// — happens when the list is rebuilt rather than on every redraw.
private struct ExplorerRow: Equatable {
    /// The node, carried so the row's action can drill into a folder or open a
    /// file's details. Only the fields the row draws take part in equality: the
    /// subtree it carries is not drawn, and walking it here would put a whole
    /// folder back on the redraw path.
    let node: ScanNode
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isAccessible: Bool
    /// The colour of the node's wedge in the chart, so a row's icon and its wedge
    /// always read as the same thing.
    let iconColor: Color
    let subtitle: String
    let sizeText: String

    init(node: ScanNode, colors: NodeColors, showsLocation: Bool = false) {
        self.node = node
        url = node.url
        name = node.name
        isDirectory = node.isDirectory
        isSymlink = node.isSymlink
        isAccessible = node.isAccessible
        iconColor = colors.color(for: node.url).color
        if showsLocation {
            subtitle = PathFormat.abbreviated(node.url.path)
        } else if node.isDirectory {
            subtitle = "\(CountFormat.files(node.fileCount)) · \(CountFormat.folders(node.directoryCount))"
        } else {
            subtitle = node.category.displayName
        }
        sizeText = ByteFormat.string(node.logicalSize)
    }

    static func == (lhs: ExplorerRow, rhs: ExplorerRow) -> Bool {
        lhs.url == rhs.url
            && lhs.name == rhs.name
            && lhs.isDirectory == rhs.isDirectory
            && lhs.isSymlink == rhs.isSymlink
            && lhs.isAccessible == rhs.isAccessible
            && lhs.iconColor == rhs.iconColor
            && lhs.subtitle == rhs.subtitle
            && lhs.sizeText == rhs.sizeText
    }
}

/// One explorer row.
///
/// Hover is a light emphasis surface plus a hairline stroke, deliberately
/// quieter than the selection fill, so "where the pointer is" and "what I
/// clicked" never read the same. The row publishes its URL to the shared hover
/// state while the pointer is over it, which is what lights the matching wedge.
///
/// The row compares equal to itself while the values it draws, its selection and
/// its hover state are unchanged, so a change to one row — or to anything else on
/// the screen — does not re-render the rest of the list. Its separator is drawn
/// inside the row for the same reason: a divider of its own would double the
/// number of children a lazy list has to place.
private struct NodeRow: View, Equatable {
    let row: ExplorerRow
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    nonisolated static func == (lhs: NodeRow, rhs: NodeRow) -> Bool {
        lhs.row == rhs.row && lhs.isSelected == rhs.isSelected && lhs.isHovered == rhs.isHovered
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: DS.Spacing.small) {
                    Image(systemName: row.isDirectory ? "folder.fill" : "doc.fill")
                        .foregroundStyle(row.iconColor)
                        .opacity(DS.Sunburst.fillOpacity)
                    VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                        Text(row.name)
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Color.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.subtitle)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(row.sizeText)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Color.secondaryText)
                    if row.isSymlink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(DS.Icon.detail)
                            .foregroundStyle(DS.Color.tertiaryText)
                    }
                    if !row.isAccessible {
                        Image(systemName: "lock.fill")
                            .font(DS.Icon.detail)
                            .foregroundStyle(DS.Color.warning)
                    }
                }
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.xSmall)
                .background(rowBackground)
                .overlay(rowStroke)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover(perform: onHover)
            .accessibilityLabel("\(row.name), \(row.sizeText)")
            Divider()
        }
    }

    private var rowBackground: SwiftUI.Color {
        if isSelected { return DS.Color.accent.opacity(DS.Opacity.rowSelection) }
        if isHovered { return DS.Color.accent.opacity(DS.Opacity.rowHover) }
        return .clear
    }

    /// A hairline stroke marks the hovered row. The selection keeps its fill
    /// alone, so the two states stay distinct.
    @ViewBuilder
    private var rowStroke: some View {
        if isHovered && !isSelected {
            Rectangle().strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline)
        } else {
            SwiftUI.Color.clear
        }
    }
}
