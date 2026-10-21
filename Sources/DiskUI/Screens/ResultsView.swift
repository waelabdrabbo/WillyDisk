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
/// and the inspector's foot holds the single access notice. An interactive
/// sunburst (click a folder to drill
/// down, with the toolbar's location — title, path and Back — following the
/// depth), Reveal in Finder, rescan, and report export round it out.
@MainActor
public struct ResultsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: ScanViewModel

    // Chart / explorer navigation
    @State private var breadcrumb: [ScanNode] = []
    @State private var selection = ExplorerSelection()
    @FocusState private var listFocused: Bool
    @State private var quickLook = QuickLookPreview()

    // Explorer controls
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    @State private var sortOrder: SortOrder = .size
    /// Which list the explorer shows: the folder in the chart, the engine's
    /// largest files and folders, or the scan cut by file category.
    @State private var explorerMode: ExplorerMode = .folder
    /// The category the Categories mode is inside, if any. Opening one keeps the
    /// mode: the ring stays as the map back out and the list becomes its files.
    @State private var drilledCategory: FileCategory?
    /// The largest files of the open category, once the off-main walk lands.
    @State private var categoryFiles: CategoryFiles?
    @State private var categoryFilesTask: Task<CategoryFiles?, Never>?
    /// The category under the pointer, shared by the ring and the category list
    /// so hovering either lights the other.
    @State private var hoveredCategory: FileCategory?
    /// Only this many rows are built at first; the list offers Show More at its
    /// foot. This is a rendering budget, not a filter, so selection, search and
    /// the chart still see the whole list.
    @State private var visibleItemLimit = DS.Size.explorerPageSize

    /// Holds the visible rows between changes of the inputs that decide them.
    ///
    /// A view body can run many times a second — a hover, a click, a resize, a
    /// scan still streaming progress — while the list itself only changes when
    /// its inputs do. Memoising the derived rows keeps the filtering, ordering
    /// and formatting off the redraw path.
    @State private var rowsCache = ExplorerRowsCache()

    /// The one hovered node, shared by the explorer rows and the chart, so
    /// hovering either side lights the other. Matched by URL, never by identity.
    ///
    /// It is held as an observed reference rather than as plain view state so that
    /// a pointer crossing the explorer's rows re-renders only what reads it — the
    /// list and the chart — and leaves the rest of the screen, from its toolbar to
    /// its inspector, with the views it already has.
    @State private var hover = ChartHover()

    // Access notice
    @State private var accessNoticeExpanded = false
    /// Full Disk Access is assumed absent until the off-main probe says
    /// otherwise, so a slow probe fails toward informing rather than hiding.
    @State private var fullDiskAccessGranted = false

    // Reclaim
    @State private var reclaimCandidates: [ReclaimCandidate] = []
    @State private var reclaimRefusal: ReclaimRefusal?
    @State private var activeSheet: ResultsSheet?
    @State private var isCheckingReclaim = false
    @State private var isTrashing = false
    /// A selection chosen in the cleanup sheet, held until that sheet has
    /// finished dismissing so the confirmation can be presented on its own.
    @State private var pendingReclaimNodes: [ScanNode] = []
    /// A token that makes a slow guard probe land only on the request that asked
    /// for it, never on a later selection the sheet is now about.
    @State private var reclaimRequestID = UUID()

    public init(viewModel: ScanViewModel = ScanViewModel(), initialMode: ExplorerMode = .folder) {
        _viewModel = State(initialValue: viewModel)
        _explorerMode = State(initialValue: initialMode)
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
        case .folder, .categories:
            return []
        case .topFiles:
            return summary.largestFiles
        case .topFolders:
            let rootPath = summary.root.standardizedFileURL.path
            return summary.largestDirectories.filter { $0.url.standardizedFileURL.path != rootPath }
        }
    }

    /// The scan's bytes by category, for the Categories mode and its ring.
    private var categoryBreakdown: CategoryBreakdown {
        guard let summary else {
            return CategoryBreakdown(categoryBreakdown: [:], totalLogicalSize: 0)
        }
        return CategoryBreakdown(summary: summary)
    }

    /// Opens a category in place, or closes it when it is already open. The mode
    /// does not change: the ring keeps the category outlined and the crumb above
    /// the list leads back to every category.
    private func selectCategory(_ category: FileCategory) {
        guard drilledCategory != category else {
            closeCategory()
            return
        }
        clearSelection()
        hoveredCategory = nil
        // A category opens on its first page, like a folder entered from the chart.
        visibleItemLimit = DS.Size.explorerPageSize
        drilledCategory = category
        loadFiles(of: category)
    }

    private func closeCategory() {
        drilledCategory = nil
        categoryFilesTask?.cancel()
        categoryFilesTask = nil
        categoryFiles = nil
        clearSelection()
    }

    /// The category's files come from the tree the finished scan already carries,
    /// walked off the main actor and capped like the cleanup analysis. A live scan
    /// has no final root node yet, so it falls back to the engine's ranked list and
    /// the header says it is the largest files so far.
    private func loadFiles(of category: FileCategory) {
        categoryFilesTask?.cancel()
        categoryFiles = nil
        guard let summary else { return }

        if let root = rootNode(in: summary) {
            let task = Task.detached(priority: .userInitiated) {
                CategoryFileIndex.largest(
                    filesOf: category,
                    in: root,
                    isCancelled: { Task.isCancelled }
                )
            }
            categoryFilesTask = task
            Task { @MainActor in
                let result = await task.value
                guard drilledCategory == category else { return }
                categoryFiles = result
            }
        } else {
            let files = summary.largestFiles.filter { $0.category == category }
            categoryFiles = CategoryFiles(
                category: category,
                files: files,
                matchCount: files.count,
                totalLogicalSize: files.reduce(0) { $0 + max(0, $1.logicalSize) },
                visitedCount: 0,
                stoppedAtLimit: false
            )
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

    /// The explorer's visible rows: the focused folder's entries, filtered,
    /// ordered and resolved for display.
    ///
    /// This is derived work — filtering, sorting and formatting every entry — so
    /// it is computed once per change of the inputs that decide it and reused
    /// while they hold. Hovering or selecting a row changes none of those inputs,
    /// so it never re-derives the list.
    private var visibleRows: [ExplorerRow] {
        // The category detail is the bounded list of the files the walk returned,
        // so it is built directly rather than through the folder cache.
        if explorerMode == .categories {
            return (categoryFiles?.files ?? []).map {
                ExplorerRow(node: $0, showsLocation: true)
            }
        }
        let key = ExplorerRowsKey(
            revision: viewModel.resultsRevision,
            breadcrumb: breadcrumb.map(\.id),
            search: searchText,
            sort: sortOrder,
            mode: explorerMode,
            maxChildren: chartChildLimit
        )
        return rowsCache.rows(for: key) {
            let nodes: [ScanNode]
            switch explorerMode {
            case .folder:
                nodes = ExplorerQuery.entries(in: currentChildren, search: searchText,
                                              sort: sortOrder)
            case .topFiles, .topFolders:
                nodes = ExplorerQuery.ranked(topNodes, search: searchText)
            case .categories:
                nodes = []
            }
            return nodes.map {
                ExplorerRow(node: $0, showsLocation: explorerMode != .folder)
            }
        }
    }

    /// The rows the current scope can select: every entry in the folder, the
    /// engine's ranked lists, or the open category's files. Filtering narrows what
    /// the list draws, not what a selection may hold, so typing in the search
    /// field does not throw away a choice made before the typing started.
    private var scopeNodes: [ScanNode] {
        switch explorerMode {
        case .folder:
            return currentChildren
        case .topFiles, .topFolders:
            return topNodes
        case .categories:
            return categoryFiles?.files ?? []
        }
    }

    /// The selected nodes, resolved against the live results rather than the
    /// values captured at click time. They follow the order the rows are shown,
    /// so Quick Look pages and batch details read in the order the user clicked
    /// through. A node's size and error state keep changing while a scan is
    /// still walking it; the URL is what was chosen.
    ///
    /// Rows a search or filter hides are still selected and still acted on; they
    /// follow the visible rows in scope order.
    private var selectedNodes: [ScanNode] {
        let visible = visibleRows.compactMap { row in
            selection.contains(row.url) ? row.node : nil
        }
        let shown = Set(visible.map(\.url))
        let hidden = scopeNodes.filter { selection.contains($0.url) && !shown.contains($0.url) }
        return visible + hidden
    }

    /// The order clicks, Shift ranges and the arrow keys count through. The
    /// list's keyboard cursor only visits rendered rows.
    private var rowOrder: [URL] { visibleRows.map(\.url) }

    private var displayedRows: [ExplorerRow] {
        Array(visibleRows.prefix(visibleItemLimit))
    }

    private var displayedRowOrder: [URL] { displayedRows.map(\.url) }
    private var hasMoreRows: Bool {
        visibleRows.count > visibleItemLimit
    }

    /// Where the spindle hole leads: up one folder, or back to all categories.
    private var chartCenterAction: (() -> Void)? {
        if explorerMode == .categories {
            return drilledCategory == nil ? nil : { closeCategory() }
        }
        return breadcrumb.isEmpty ? nil : { goToBreadcrumb(depth: breadcrumb.count - 1) }
    }

    private var chartCenterHint: String {
        if explorerMode == .categories { return "Show all categories" }
        guard !breadcrumb.isEmpty else { return "The scanned location" }
        return breadcrumb.count == 1
            ? "Return to the scanned location"
            : "Go up to \(breadcrumb[breadcrumb.count - 2].name)"
    }

    /// The explorer's page is also the chart's density: a page of 15 items shows
    /// those 15 children in the chart rather than 12 plus a remainder, and Show
    /// More therefore spends more chart slots, within the chart's ceiling.
    private var chartChildLimit: Int {
        switch explorerMode {
        case .folder, .categories:
            return min(max(visibleItemLimit, DS.Sunburst.maxChildrenPerNode), DS.Sunburst.maxSegments)
        case .topFiles, .topFolders:
            return DS.Sunburst.maxChildrenPerNode
        }
    }
    private var remainingRowCount: Int { max(visibleRows.count - visibleItemLimit, 0) }

    private var isFiltering: Bool {
        !searchText.isEmpty
    }

    /// The inputs that decide which rows are on screen. When any of them changes
    /// the list is reshuffled, so a hover is dropped rather than left pointing
    /// at a row that is no longer rendered.
    private var rowSetKey: ExplorerRowKey {
        ExplorerRowKey(search: searchText, sort: sortOrder, mode: explorerMode)
    }

    /// Honest copy for an empty chart — an empty result set means something
    /// different while a scan is still filling in than after it has settled.
    private var chartEmptyMessage: String {
        isLiveScan ? "Reading the first folders…" : "This folder has nothing big enough to draw."
    }

    /// Honest copy for an empty explorer list, in the same two situations.
    private var listEmptyMessage: String {
        if explorerMode == .categories {
            if let category = drilledCategory {
                return isLiveScan
                    ? "No \(category.displayName) files yet"
                    : "No \(category.displayName) files in this scan"
            }
            return "No categories"
        }
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

    /// Whether the scan skipped anything worth accounting for: restricted
    /// locations, or other unreadable items. The notice is never silent.
    ///
    /// Read from the snapshot's own totals rather than from the issue rows:
    /// the rows arrive one event at a time while scanning, and gating on them
    /// would redraw the whole screen for each one. The snapshot's counts move
    /// at the screen's rendering cadence, and the notice resolves its rows in
    /// its own body.
    private var showsAccessNotice: Bool {
        guard let summary else { return false }
        return summary.permissionDeniedCount > 0 || summary.surfacedIssueCount > 0
    }

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
        .onChange(of: rowSetKey) { _, _ in
            // The row under the pointer can leave the screen without an exit
            // event when the visible set changes, so the shared hover is dropped
            // rather than left pointing at a row that is no longer rendered.
            hover.url = nil
            visibleItemLimit = DS.Size.explorerPageSize
        }
        .onChange(of: explorerMode) { _, newMode in
            // The list's scope changed, so a selection, a hover, and a search
            // that were about the old list would otherwise point at rows that are
            // no longer on screen.
            hover.url = nil
            clearSelection()
            searchText = ""
            hoveredCategory = nil
            closeCategory()
            // The chart shows a folder; the largest lists are about the whole
            // scan. Returning the chart to the scanned location keeps the map and
            // the list talking about the same thing.
            if newMode != .folder {
                breadcrumb.removeAll()
            }
            visibleItemLimit = DS.Size.explorerPageSize
        }
        .onChange(of: isLiveScan) { _, live in
            // A category opened while the walk was still running listed the
            // engine's ranked files; once the root node exists, the full walk over
            // the tree replaces that list.
            guard !live, let category = drilledCategory else { return }
            loadFiles(of: category)
        }
        .onChange(of: breadcrumb.map(\.id)) { _, _ in
            visibleItemLimit = DS.Size.explorerPageSize
        }
        .onChange(of: viewModel.resultsRevision) { _, _ in
            // Starting, settling or cancelling a scan can replace the rows under
            // a selection. The URLs still in the list keep their selection; the
            // ones that have gone do not, so no action is ever aimed at a row the
            // screen no longer has.
            pruneSelection()
        }
        .onChange(of: selection) { _, _ in
            // An open panel follows the selection; a closed one stays closed.
            quickLook.updateIfVisible(selectedNodes.map(\.url))
        }
        .onDisappear {
            // The panel belongs to the window, not to this view; leaving the
            // results must not leave a preview of them on screen.
            quickLook.close()
            // A list that leaves the screen mid-scroll sends no further phase,
            // and a held snapshot must not stay held for the next scan.
            viewModel.setResultsScrolling(false)
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: viewModel.reclaimNotice)
        .sheet(item: $activeSheet, onDismiss: presentPendingReclaim) { sheet in
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
            case .cleanup:
                if let summary, let root = rootNode(in: summary) {
                    CleanupSheet(
                        root: root,
                        rootName: root.name,
                        scannedAt: summary.finishedAt,
                        onMove: { nodes in
                            pendingReclaimNodes = nodes
                            activeSheet = nil
                        },
                        onClose: { activeSheet = nil }
                    )
                }
            case .history:
                if let history = viewModel.history, let root = summary?.root ?? viewModel.currentRoot {
                    HistorySheet(history: history, root: root, rootName: LocationName.of(root))
                }
            }
        }
        .interactiveDismissDisabled(isTrashing)
        .resultsToolbarTitleHidden()
        // The chart intentionally runs under the titlebar; the toolbar has no
        // backing of its own on this screen.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusedSceneValue(\.resultsCommands, resultsCommands)
        .toolbar {
            // Home leaves the results for source selection. Moving up one folder is
            // what the trail's ancestor crumbs are for, so there is no Back action.
            ToolbarItem(placement: .navigation) {
                Button {
                    goHome()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Return to source selection")
                .accessibilityLabel("Home")
                .accessibilityHint("Shows source selection; a scan that is running keeps running")
            }
            // The trail sits immediately after Home. With no title in the window
            // chrome it is the only place that names the folder on screen; it stays
            // present at the scanned root as plain text, and every ancestor before
            // the current folder is a button.
            ToolbarItem(placement: .navigation) {
                breadcrumbTrail
            }
            // A flexible spacer keeps Coverage, Rescan, and Export trailing while
            // Home and the trail stay grouped at the leading edge.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            } else if #available(macOS 15.0, *) {
                ToolbarItem(placement: .principal) { Spacer() }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHistory()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("Compare this location's recorded scans")
                .disabled(summary == nil || viewModel.history == nil)

                Button {
                    showCleanup()
                } label: {
                    Label("Cleanup", systemImage: "sparkles")
                }
                .help("Large, old, and cache items worth reviewing")
                .disabled(summary == nil || viewModel.isScanning)

                Button {
                    showCoverage()
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
                    Button("Export as JSON…") { exportJSON() }
                    Button("Export as CSV…") { exportCSV() }
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

    /// The folder on screen: the crumb the user opened, otherwise the scanned
    /// location, otherwise the app name. The explorer header names it; the toolbar
    /// trail is the navigation path.
    private var folderTitle: String {
        breadcrumb.last?.name ?? scannedRootName ?? "WillyDisk"
    }

    /// The size the header states: the focused folder's, not the whole scan's.
    ///
    /// The chart's centre disc sums the same children, so the header and the disc
    /// agree at every depth. While a scan is running this is the folder's size as
    /// known so far; the status strip carries the scan's own progress, which is
    /// the number that moves.
    private var focusedTotal: Int64 {
        if let node = breadcrumb.last { return node.logicalSize }
        if viewModel.isScanning {
            return currentChildren.reduce(Int64(0)) { $0 + max($1.logicalSize, 0) }
        }
        return viewModel.displayedTotal
    }

    /// The results layout: the chart owns the canvas and the inspector holds the
    /// item list with the access notice at its foot.
    ///
    /// The inspector is attached to the chart band, never to the whole screen, so
    /// the notice can never reclaim the window's full height.
    /// The bands are told apart by their own spacing and fills, not by rules.
    private var content: some View {
        chartPane
            // The item list is a primary surface, not an optional accessory:
            // keep it present for every result state and let the user size it
            // with the inspector divider. Do not add a collapse control.
            .inspector(isPresented: .constant(true)) {
                explorerPane
                    .dsGlassControl(cornerRadius: DS.Radius.panel)
                    .padding(DS.Spacing.medium)
                    .inspectorColumnWidth(min: 300, ideal: 362, max: 560)
            }
    }

    // MARK: - Access notice

    /// The single merged access notice, at the foot of the inspector.
    private var accessNoticeRow: some View {
        LiveAccessNotice(
            viewModel: viewModel,
            isFullDiskAccessGranted: fullDiskAccessGranted,
            isExpanded: $accessNoticeExpanded
        )
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
    /// The capsule is a functional floating control, so it uses the shared glass
    /// surface rather than a hand-picked grey that drifts between appearances.
    private var scanStatusStrip: some View {
        HStack(spacing: 0) {
            if isLiveScan {
                LiveScanStatusBanner(viewModel: viewModel, onCancel: { viewModel.cancel() })
                    .padding(.horizontal, DS.Spacing.large)
                    .padding(.vertical, DS.Spacing.small)
                    .frame(width: DS.Size.scanStatusWidth)
                    .dsGlassControl(cornerRadius: DS.Size.scanStatusStripHeight / 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DS.Size.scanStatusStripHeight)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isLiveScan)
    }

    // MARK: - Chart pane

    private var chartPane: some View {
        VStack(spacing: 0) {
            if explorerMode == .categories {
                if let category = drilledCategory, let files = categoryFiles, !files.files.isEmpty {
                    // The category's node is its files, so the chart is the same
                    // sunburst the folder view uses: one wedge per listed file,
                    // hover and selection shared with the rows below.
                    SunburstView(
                        nodes: files.files,
                        centerLabel: category.displayName,
                        selectedNodeURL: selectedNodes.count == 1 ? selectedNodes[0].url : nil,
                        maxChildren: chartChildLimit,
                        hoveredURL: $hover.url,
                        onCenterTap: chartCenterAction,
                        centerHint: chartCenterHint
                    ) { node in
                        chartSelect(node)
                    }
                    .padding(DS.Spacing.medium)
                } else if let category = drilledCategory, categoryFiles?.files.isEmpty == true {
                    categoryEmptyChart(category)
                } else {
                    // Before the walk lands (or at the top level) the ring is the
                    // chart: the categories, with the open one outlined.
                    CategoryRingView(
                        breakdown: categoryBreakdown,
                        centerLabel: scannedRootName ?? "This scan",
                        selected: drilledCategory,
                        hovered: $hoveredCategory,
                        onSelect: selectCategory
                    )
                    .padding(DS.Spacing.medium)
                }
            } else if currentChildren.isEmpty {
                emptyChart
            } else {
                SunburstView(
                    nodes: currentChildren,
                    centerLabel: breadcrumb.last?.name ?? scannedRootName ?? "Root",
                    selectedNodeURL: selectedNodes.count == 1 ? selectedNodes[0].url : nil,
                    maxChildren: chartChildLimit,
                    hoveredURL: $hover.url,
                    onCenterTap: chartCenterAction,
                    centerHint: chartCenterHint
                ) { node in
                    chartSelect(node)
                }
                .padding(DS.Spacing.medium)
            }
            scanStatusStrip
                .padding(.bottom, DS.Spacing.medium)
        }
    }

    /// What the chart pane shows before there is anything to draw, which is a
    /// live scan's first moments or a scan that found nothing.
    private var emptyChart: some View {
        VStack(spacing: DS.Spacing.small) {
            WillyDiskMark(size: 44)
            Text(chartEmptyMessage)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A category with nothing to draw says so in its own words, rather than
    /// borrowing the folder chart's "nothing big enough" line.
    private func categoryEmptyChart(_ category: FileCategory) -> some View {
        VStack(spacing: DS.Spacing.small) {
            WillyDiskMark(size: 44)
            Text(isLiveScan
                 ? "No \(category.displayName) files yet"
                 : "No \(category.displayName) files to draw")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Explorer pane

    private var explorerPane: some View {
        VStack(spacing: 0) {
            compactHeader
            explorerModeBar
            if explorerMode == .categories {
                if let category = drilledCategory {
                    categoryDetailHeader(category)

                    if categoryFiles != nil {
                        contentsList
                            .frame(maxHeight: .infinity)
                    } else {
                        categoryFilesLoading(category)
                    }
                } else {
                    categoryModeCaption

                    CategoryShareList(
                        shares: categoryBreakdown.shares,
                        hovered: $hoveredCategory,
                        onSelect: selectCategory
                    )
                    .frame(maxHeight: .infinity)
                }
            } else {
                explorerToolbar

                contentsList
                    // The list is the flexible band: it gives up height to the
                    // detail pane and the access notice at the inspector's foot.
                    .frame(maxHeight: .infinity)
            }

            if !selectedNodes.isEmpty {
                Rectangle()
                    .fill(DS.Color.rule)
                    .frame(height: DS.Stroke.hairline)
                detailPane
            }

            if showsAccessNotice {
                accessNoticeRow
            }
        }
        // The inspector is a fixed-height column, not a stack that grows to its
        // content: its list is the part that scrolls. Without this frame an
        // expanded notice can make the pane report its ideal content height and
        // push the whole window's content out of view.
        .frame(maxHeight: .infinity, alignment: .top)
        // Match the notice's vertical inset so the pane does not read tight at
        // the top while the notice at its foot has breathing room.
        .padding(.top, DS.Spacing.small)
    }

    /// What the category list is, in one line. The search, sort, and category
    /// filter controls belong to the node lists and are not shown here: there is
    /// nothing to search among nine categories.
    private var categoryModeCaption: some View {
        Text("Share of this scan's logical size. Choose a category to see its largest files.")
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.bottom, DS.Spacing.small)
    }

    /// The way back out of a category, and what its list is showing.
    private func categoryDetailHeader(_ category: FileCategory) -> some View {
        HStack(spacing: DS.Spacing.xSmall) {
            InlineActionButton("All Categories", systemImage: "chevron.left") {
                closeCategory()
            }
            .help("Show every category")
            .accessibilityLabel("All Categories")
            .accessibilityHint("Closes this category and shows the whole breakdown")

            Text(category.displayName)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)

            Spacer(minLength: DS.Spacing.small)

            if let files = categoryFiles {
                Text(categorySummary(files))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .help(files.isTruncated
                          ? "Showing the largest \(files.files.count) of \(CountFormat.files(files.matchCount))"
                          : CountFormat.files(files.matchCount))
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.small)
    }

    private func categorySummary(_ files: CategoryFiles) -> String {
        let size = ByteFormat.string(files.totalLogicalSize)
        if isLiveScan {
            return "\(size) · largest \(files.files.count) so far"
        }
        if files.stoppedAtLimit {
            return "\(size) · sample of \(CountFormat.files(files.matchCount))"
        }
        if files.isTruncated {
            return "\(size) · largest \(files.files.count) of \(files.matchCount)"
        }
        return "\(size) · \(CountFormat.files(files.matchCount))"
    }

    private func categoryFilesLoading(_ category: FileCategory) -> some View {
        VStack(spacing: DS.Spacing.small) {
            ProgressView()
            Text("Reading the \(category.displayName) files…")
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The switch between the folder in the chart and the two largest lists.
    private var explorerModeBar: some View {
        HStack(spacing: 0) {
            Picker("Explorer view", selection: $explorerMode) {
                ForEach(ExplorerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .dsSegmentedSwitch()
            .accessibilityLabel("Explorer view")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.top, DS.Spacing.small)
        .padding(.bottom, DS.Spacing.xSmall)
    }

    /// The path to the folder the chart is drawn from, with every ancestor
    /// clickable. The current folder is text, not a button that would do nothing.
    ///
    /// The trail sits at the toolbar's leading edge, immediately after Home. It
    /// always names the scanned location; at that root it is plain text, while
    /// drilling adds clickable ancestors before the current folder. Choosing a
    /// crumb re-roots the chart at that folder, and the crumbs after it are dropped.
    private var breadcrumbTrail: some View {
        HStack(spacing: DS.Spacing.small) {
            crumb(
                scannedRootName ?? "Scanned Folder",
                isCurrent: breadcrumb.isEmpty,
                action: { goToBreadcrumb(depth: 0) }
            )
            .layoutPriority(1)

            ForEach(Array(breadcrumb.enumerated()), id: \.element.url) { index, node in
                Image(systemName: "chevron.right")
                    .font(DS.Icon.inline)
                    .foregroundStyle(DS.Color.secondaryText)
                crumb(
                    node.name,
                    isCurrent: index == breadcrumb.count - 1,
                    action: { goToBreadcrumb(depth: index + 1) }
                )
                .layoutPriority(index == breadcrumb.count - 1 ? 2 : 0)
            }
        }
        // The system insets the Home item but not a custom item that follows it;
        // reserve the same breathing room before the capsule closes.
        .padding(.trailing, DS.Spacing.small)
        .frame(maxWidth: DS.Size.toolbarBreadcrumbMaxWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    @ViewBuilder
    private func crumb(_ name: String, isCurrent: Bool = false, action: @escaping () -> Void) -> some View {
        if isCurrent {
            Text(name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        } else {
            BreadcrumbCrumb(name: name, action: action)
        }
    }

    /// One ancestor crumb. The trail stays quiet at rest; hovering raises the
    /// secondary name to the accent and reserves the standard hit target.
    /// The folder already on screen is plain text, not a button that would do
    /// nothing.
    private struct BreadcrumbCrumb: View {
        let name: String
        let action: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(name)
                    .font(DS.Typography.body)
                    .foregroundStyle(isHovered ? DS.Color.accent : DS.Color.secondaryText)
                    .lineLimit(1)
                    .frame(minHeight: DS.Size.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help("Show “\(name)”")
        }
    }

    /// The location and its total on the first line, the honest counts and
    /// compact provenance together on the second, and — for a scan that stopped
    /// early — the warning below them, so it shares a row with nothing.
    ///
    /// It is always present — before a scan's first snapshot the location and
    /// totals come from the engine's live counters — so its values tick up in
    /// place and nothing appears or disappears under the chart.
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.medium) {
                Text(folderTitle)
                    .font(DS.Typography.title2)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Spacing.small)
                Text(ByteFormat.string(focusedTotal))
                    .font(DS.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.primaryText)
            }
            // The full timestamp would push the line past the inspector's
            // width; the compact form keeps the counts and recency together and
            // the full provenance stays in the tooltip and accessibility label.
            HStack(spacing: DS.Spacing.small) {
                Text(countsText)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xSmall)
                provenanceMetadata
            }
            .lineLimit(1)
            if viewModel.resultsAreStale {
                StaleResultsBadge(onRescan: rescan)
            }
            if viewModel.stoppedEarly { stoppedEarlyNote }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Counts for the list's scope: the folder's own entries while the chart and
    /// list agree on a folder, and the whole scan's counts while the list is one
    /// of the largest lists.
    private var countsText: String {
        if explorerMode == .folder {
            return "\(CountFormat.files(summary?.fileCount ?? 0)) across \(CountFormat.items(presentableChildren.count))"
        }
        guard let s = summary else { return CountFormat.files(0) }
        // The scan root is a folder in the summary, but it is the scan itself and
        // never one of its own subfolders, so the largest-list counts leave it out.
        return "\(CountFormat.files(s.fileCount)) in \(CountFormat.folders(max(0, s.directoryCount - 1)))"
    }

    /// When the results were gathered and how long the scan took, so the numbers
    /// are never read as current. A live scan states its start and keeps the
    /// elapsed time moving; a settled one states both and stops.
    @ViewBuilder
    private var provenanceMetadata: some View {
        if isLiveScan, let started = viewModel.scanStartedAt ?? summary?.startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let full = ScanProvenance.live(startedAt: started, now: context.date)
                provenanceText(ScanProvenance.compactLive(startedAt: started, now: context.date), full: full)
            }
        } else if let s = summary {
            let full = ScanProvenance.settled(startedAt: s.startedAt, finishedAt: s.finishedAt)
            provenanceText(ScanProvenance.compactSettled(startedAt: s.startedAt, finishedAt: s.finishedAt), full: full)
        }
    }

    private func provenanceText(_ compact: String, full: String) -> some View {
        Text(compact)
            .font(DS.Typography.caption)
            .monospacedDigit()
            .foregroundStyle(DS.Color.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(full)
            .accessibilityLabel(full)
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
            SearchField(
                text: $searchText,
                prompt: searchPrompt,
                focusRequest: searchFocusRequest
            )
            .frame(maxWidth: .infinity)

            if explorerMode == .folder {
                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            if sortOrder == order {
                                Label(order.label, systemImage: "checkmark")
                            } else {
                                Text(order.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xSmall) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortOrder.label)
                    }
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(minHeight: DS.Size.iconButton)
                .help("Sort by \(sortOrder.label)")
                .accessibilityLabel("Sort")
                .accessibilityValue(sortOrder.label)
            }
        }
        .padding(DS.Spacing.small)
    }

    private var searchPrompt: String {
        switch explorerMode {
        case .folder, .categories: "Search"
        case .topFiles: "Search top files"
        case .topFolders: "Search top folders"
        }
    }

    private var contentsList: some View {
        // The list reads the shared hover itself, so a pointer crossing its rows
        // rebuilds the rows that changed and the chart, and leaves the rest of the
        // screen where it is.
        ContentsList(
            rows: displayedRows,
            hasMoreRows: hasMoreRows,
            remainingCount: remainingRowCount,
            emptyMessage: listEmptyMessage,
            selection: selection,
            selectedCount: selectedNodes.count,
            isFocused: $listFocused,
            onClick: handleClick,
            onOpen: activate,
            onMove: { offset, extending in
                selection.move(by: offset, in: displayedRowOrder, extending: extending)
            },
            onJump: { index, extending in
                selection.jump(to: index, in: displayedRowOrder, extending: extending)
            },
            onShowMore: {
                visibleItemLimit += DS.Size.explorerPageSize
            },
            onQuickLook: { node in
                if let node {
                    quickLook.toggle(contextTargets(for: node).map(\.url))
                } else {
                    quickLook.toggle(selectedNodes.map(\.url))
                }
            },
            onReveal: { node in
                revealInFinder(contextTargets(for: node))
            },
            onReclaim: { node in
                requestReclaim(contextTargets(for: node))
            },
            onEscape: clearSelection,
            onScrollActivity: { scrolling in
                viewModel.setResultsScrolling(scrolling)
                hover.setSuspended(scrolling)
            }
        )
    }

    // MARK: - Detail pane

    /// What the explorer says about what is selected: one item's own details, or
    /// the whole selection's shared facts. A folder shows its own size and
    /// contents here without being entered; browsing is a separate action.
    @ViewBuilder
    private var detailPane: some View {
        Group {
            if selectedNodes.count == 1, let node = selectedNodes.first {
                singleDetailPane(node)
            } else {
                multiDetailPane
            }
        }
        .padding(DS.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func singleDetailPane(_ node: ScanNode) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(DS.Color.graphite)
                Text(node.name)
                    .font(DS.Typography.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                detailHeaderActions([node])
            }

            detailRow("Path", node.url.path)
            detailRow("Kind", node.isDirectory ? "Folder" : node.category.displayName)
            detailRow("Size", ByteFormat.exact(node.logicalSize))
            detailRow("On disk", ByteFormat.exact(node.allocatedSize))
            if node.name.hasPrefix(".") {
                detailRow("Visibility", "Hidden")
            }
            if node.isDirectory {
                detailRow("Contents", "\(CountFormat.files(node.fileCount)) in \(CountFormat.folders(node.directoryCount))")
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

            if node.isDirectory {
                Button {
                    activate(node)
                } label: {
                    Label("Browse This Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
    }

    private var multiDetailPane: some View {
        let nodes = selectedNodes
        let logical = nodes.reduce(Int64(0)) { $0 + $1.logicalSize }
        let allocated = nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let kind: String
        if nodes.allSatisfy({ $0.isDirectory }) {
            kind = "Folders"
        } else if nodes.allSatisfy({ !$0.isDirectory }) {
            kind = "Files"
        } else {
            kind = "Files and folders"
        }
        let parents = Set(nodes.map { $0.url.deletingLastPathComponent() })
        let commonParent = parents.count == 1 ? parents.first : nil

        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: "square.stack.fill")
                    .foregroundStyle(DS.Color.accent)
                Text("\(nodes.count) Items Selected")
                    .font(DS.Typography.headline)
                Spacer()
                detailHeaderActions(nodes)
            }

            detailRow("Kind", kind)
            detailRow("Size", ByteFormat.exact(logical))
            detailRow("On disk", ByteFormat.exact(allocated))
            if let commonParent {
                detailRow("Location", PathFormat.abbreviated(commonParent.path))
            }

            Text("Actions apply to the whole selection.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .padding(.top, DS.Spacing.xSmall)

            Button(role: .destructive) {
                requestReclaim(nodes)
            } label: {
                Label("Move \(nodes.count) Items to Trash…", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    /// One of a detail pane's icon-only header actions.
    private func detailAction(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        IconActionButton(symbol: symbol, help: help, action: action)
    }

    /// The actions every detail pane's header carries, each applied to the whole
    /// selection. Closing clears the selection: the pane exists only while there
    /// is something selected to describe, so dismissing it is deselecting.
    private func detailHeaderActions(_ nodes: [ScanNode]) -> some View {
        HStack(spacing: DS.Spacing.small) {
            detailAction("eye", "Quick Look") {
                quickLook.toggle(nodes.map(\.url))
            }
            detailAction("arrow.up.forward.square", "Reveal in Finder") {
                revealInFinder(nodes)
            }
            detailAction("xmark", "Close Details") {
                clearSelection()
            }
        }
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

    /// A click selects the row. The modifiers are read at click time because a
    /// SwiftUI button's action does not carry them.
    private func handleClick(_ url: URL) {
        let click = ExplorerClick.current
        selection.click(url, in: rowOrder, toggling: click.toggling, extending: click.extending)
        listFocused = true
    }

    /// A chart click that lands on a folder enters it — the chart is the map of
    /// the current folder, so a wedge is a way in. A file click selects the file
    /// so its row and details can be shown without leaving the chart.
    private func chartSelect(_ node: ScanNode) {
        if node.isDirectory {
            enter(node)
        } else {
            selection.selectOnly(node.url)
            // The chart draws every entry, but the list may still be on its
            // first page. Reveal the chart-picked row rather than selecting
            // something the list cannot show.
            if let index = visibleRows.firstIndex(where: { $0.url == node.url }),
               index >= visibleItemLimit {
                visibleItemLimit = index + 1
            }
            listFocused = true
        }
    }

    /// Double-click, Return and the detail pane's Browse button: folders are
    /// entered, files open in their default application.
    private func activate(_ node: ScanNode) {
        if node.isDirectory {
            enter(node)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    private func enter(_ node: ScanNode) {
        hover.url = nil
        breadcrumb.append(node)
        clearSelection()
        explorerMode = .folder
    }

    /// Re-roots the chart at an ancestor. `depth` is how many crumbs are kept,
    /// so zero returns to the scanned location.
    private func goToBreadcrumb(depth: Int) {
        guard depth < breadcrumb.count else { return }
        hover.url = nil
        clearSelection()
        breadcrumb = Array(breadcrumb.prefix(depth))
    }

    private func revealInFinder(_ nodes: [ScanNode]) {
        let urls = nodes.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The rows an action on `node` applies to: the whole selection when the
    /// action was invoked from one of its rows, and only that row otherwise.
    private func contextTargets(for node: ScanNode) -> [ScanNode] {
        if selection.contains(node.url) {
            let targets = selectedNodes
            if !targets.isEmpty { return targets }
        }
        selection.selectOnly(node.url)
        return [node]
    }

    private func clearSelection() {
        selection.clear()
    }

    /// Keeps the selection to the URLs still in the list's scope, so a row that a
    /// new snapshot retires cannot stay selected and cannot be acted on.
    private func pruneSelection() {
        // Visible rows first so a cursor that must move lands on something the
        // user can see; filtered-out rows stay available so their selection is
        // not lost while a search is active.
        let visible = rowOrder
        let shown = Set(visible)
        let hidden = scopeNodes.map(\.url).filter { !shown.contains($0) }
        selection.prune(to: visible + hidden)
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
            // A moved row is still in the settled results until the next scan, so
            // the selection must not keep pointing at it.
            if viewModel.resultsAreStale {
                clearSelection()
            }
        }
    }

    private func openTrash() {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(trash)
    }

    private var resultsCommands: ResultsCommands {
        ResultsCommands(
            canRescan: !viewModel.isScanning,
            rescan: { rescan() },
            canExport: summary != nil,
            exportJSON: { exportJSON() },
            exportCSV: { exportCSV() },
            canShowCoverage: summary != nil,
            showCoverage: { showCoverage() },
            canShowCleanup: summary != nil && !viewModel.isScanning,
            showCleanup: { showCleanup() },
            canShowHistory: summary != nil && viewModel.history != nil,
            showHistory: { showHistory() },
            focusSearch: { searchFocusRequest += 1 }
        )
    }

    private func showCoverage() {
        activeSheet = .coverage
    }

    private func showCleanup() {
        guard summary != nil, !viewModel.isScanning else { return }
        activeSheet = .cleanup
    }

    private func showHistory() {
        guard summary != nil, viewModel.history != nil else { return }
        activeSheet = .history
    }

    /// Opens the reclaim confirmation for a selection the cleanup sheet made,
    /// once that sheet has actually gone. Swapping one sheet for another in the
    /// same update makes the second presentation unreliable.
    private func presentPendingReclaim() {
        guard !pendingReclaimNodes.isEmpty else { return }
        let nodes = pendingReclaimNodes
        pendingReclaimNodes = []
        requestReclaim(nodes)
    }

    private func exportJSON() {
        guard let summary else { return }
        ReportExport.exportJSON(summary: summary)
    }

    private func exportCSV() {
        guard let summary else { return }
        ReportExport.exportCSV(summary: summary)
    }

    private func rescan() {
        hover.url = nil
        breadcrumb.removeAll()
        clearSelection()
        searchText = ""
        closeCategory()
        explorerMode = .folder
        viewModel.rescan()
    }

    private func goHome() {
        // Only the screen changes. A scan that is still running keeps running in
        // the background and its results stay on the engine's slot, so the source
        // screen can show it and View can open it again; the scan is untouched.
        hover.url = nil
        breadcrumb.removeAll()
        clearSelection()
        searchText = ""
        closeCategory()
        explorerMode = .folder
        viewModel.showHome()
    }
}

// MARK: - Supporting types

/// Where the pointer sits in the explorer when a scroll ends.
///
/// Rows are uniform, so the pointer's place in the scroll view plus the content
/// offset names the row without reading a frame per row. The caller checks the
/// index against the rows it is actually showing; a pointer past the last row
/// (over Show More, or the notice) resolves to nothing.
enum ExplorerHoverRow {
    static func index(pointerY: CGFloat, contentOffset: CGFloat, rowHeight: CGFloat) -> Int? {
        guard rowHeight > 0 else { return nil }
        let y = pointerY + contentOffset
        guard y >= 0 else { return nil }
        return Int(y / rowHeight)
    }
}

/// What restoring the hover needs: the pointer, the content offset and one row's
/// height.
///
/// Held in a reference box rather than view state: the scroll view reports the
/// offset on every frame of a scroll, and storing that in `@State` would redraw
/// the list on every frame for a value read once, when the scroll ends.
private final class ScrollHoverMetrics {
    var pointer: CGPoint?
    var contentOffset: CGFloat = 0
    var rowHeight: CGFloat = 0
}

/// Whether a press that began in the list is still down.
///
/// Focus moves to the list on mouse-down, before the pressed row's action runs,
/// so the focus change alone cannot say whether the keyboard brought focus here
/// or a click is about to select a row.
private final class PointerPress {
    var isPressed = false
}

/// The one hovered node, shared by the explorer rows and the chart.
///
/// It is a reference the two panes observe rather than a value the screen holds,
/// so a pointer crossing the explorer's rows re-renders the list and the chart and
/// leaves every other part of the screen as it was. Matched by URL, never by
/// identity: the engine rebuilds every node value on each progressive snapshot.
///
/// Hover is suspended while the list scrolls. Rows pass under a still pointer as
/// the content moves, and lighting each one on the way past is neither useful
/// nor cheap: it would re-render the list and the chart's emphasis for every row
/// that crosses. Suspending drops the current hover too, so no row stays lit
/// while its content slides out from under the pointer; when the scroll ends the
/// list names the row under the pointer and asks for it again, so the highlight
/// returns in the same frame.
@MainActor
@Observable
final class ChartHover {
    var url: URL?

    /// Whether row hover is being ignored because the list is scrolling.
    private(set) var isSuspended = false

    /// Suspends or resumes row hover. The scroll's own phases decide both, so
    /// there is no timer to keep: hover stops with the movement and resumes when
    /// the list settles.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { url = nil }
    }

    /// Publishes the row under the pointer as the one hovered node. Only the row
    /// that is still hovered clears it, so moving between rows never leaves the
    /// highlight stuck on the wrong one.
    func set(_ url: URL, _ hovering: Bool) {
        guard !isSuspended else { return }
        if hovering {
            if self.url != url { self.url = url }
        } else if self.url == url {
            self.url = nil
        }
    }
}

/// The selection modifiers of the click being handled.
///
/// A SwiftUI button's action does not carry the event that triggered it, so the
/// current AppKit modifier flags are read when the action runs. Shift wins over
/// Command, matching the extended range a Command-Shift click draws.
private enum ExplorerClick {
    static var current: (toggling: Bool, extending: Bool) {
        let flags = NSEvent.modifierFlags
        let extending = flags.contains(.shift)
        return (toggling: !extending && flags.contains(.command), extending: extending)
    }
}

/// The in-progress readout: an honest status indicator, the work counted so far,
/// and the cancel action.
///
/// It resolves the engine's live counters in its own body. Progress events
/// arrive far faster than the results change, and this is the only part of the
/// screen they redraw: the strip updates while the chart, the list and the
/// header stay on the snapshot cadence.
private struct LiveScanStatusBanner: View {
    let viewModel: ScanViewModel
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.medium) {
            indicator
            Text("\(CountFormat.files(viewModel.filesScanned)), \(ByteFormat.string(viewModel.displayedTotal))")
                .font(DS.Typography.caption)
                .monospacedDigit()
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: DS.Spacing.large)
            cancelButton
        }
        .accessibilityElement(children: .contain)
    }

    /// Progress read straight from the engine.
    ///
    /// A percentage appears only when `fractionCompleted` is present; otherwise
    /// the indicator is honestly indeterminate, because the engine reports no
    /// reliable total and we do not fabricate one.
    @ViewBuilder
    private var indicator: some View {
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
                Text("Reading files…")
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning, progress not yet measurable")
        }
    }

    /// Cancel Scan, as an inset chip inside the strip's capsule.
    ///
    /// A `.bordered` button on the capsule takes the window's control fill, which
    /// is the capsule's own fill at this size, leaving the label to read as bare
    /// text on the strip. The chip fills with `windowBackground` instead, so it
    /// separates from the capsule the way a bordered control separates from a
    /// toolbar.
    private var cancelButton: some View {
        Button(role: .cancel, action: onCancel) {
            Label("Cancel Scan", systemImage: "stop.fill")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.primaryText)
                .padding(.horizontal, DS.Spacing.small)
                .padding(.vertical, DS.Spacing.xxSmall)
                .background(DS.Color.windowBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline))
                .frame(minHeight: DS.Size.iconButton)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop the scan; the results gathered so far are kept")
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

/// The access notice, resolving its rows from the live view model in its own
/// body so that a surfaced issue redraws the notice rather than the screen.
private struct LiveAccessNotice: View {
    let viewModel: ScanViewModel
    let isFullDiskAccessGranted: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        AccessNoticeRow(
            presentation: viewModel.issuesPresentation,
            isFullDiskAccessGranted: isFullDiskAccessGranted,
            isExpanded: $isExpanded
        )
    }
}

/// The explorer's rows.
///
/// The list is the one part of the screen that reads the shared hover, so it lives
/// in a view of its own: a pointer crossing a row rebuilds this list — and the
/// chart that shares the hover — and nothing else the screen shows.
private struct ContentsList: View {
    let rows: [ExplorerRow]
    let hasMoreRows: Bool
    let remainingCount: Int
    let emptyMessage: String
    let selection: ExplorerSelection
    let selectedCount: Int
    @FocusState.Binding var isFocused: Bool
    let onClick: (URL) -> Void
    let onOpen: (ScanNode) -> Void
    let onMove: (Int, Bool) -> Void
    let onJump: (Int, Bool) -> Void
    let onShowMore: () -> Void
    let onQuickLook: (ScanNode?) -> Void
    let onReveal: (ScanNode) -> Void
    let onReclaim: (ScanNode) -> Void
    let onEscape: () -> Void
    let onScrollActivity: (Bool) -> Void

    @Environment(ChartHover.self) private var hover
    /// Survives body passes without invalidating the list as the scroll moves.
    @State private var metrics = ScrollHoverMetrics()
    /// Whether a press that began in the list is still down.
    @State private var press = PointerPress()

    var body: some View {
        // The scroll view is the keyboard focus holder: the rows decline focus
        // themselves so the arrow keys, Home/End and Space reach this one handler
        // instead of moving between the rows' buttons.
        ScrollViewReader { proxy in
            ScrollView {
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
                            let targets = selection.contains(row.url) ? max(selectedCount, 1) : 1
                            NodeRow(
                                row: row,
                                isSelected: selection.contains(row.url),
                                isHovered: hover.url == row.url,
                                action: { onClick(row.url) },
                                onHover: { hovering in hover.set(row.url, hovering) }
                            )
                            // Opting the row into equatable rendering is what makes
                            // its `Equatable` conformance do anything: without it
                            // SwiftUI rebuilds every row on each pass, so a hover or
                            // a selection would re-render the whole list.
                            .equatable()
                            // One row's height stands for all of them; it is what
                            // maps the pointer back to a row when a scroll ends.
                            .modifier(RowHeightReader(metrics: metrics,
                                                      isSampled: row.url == rows.first?.url))
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { onOpen(row.node) }
                            )
                            .id(row.url)
                            .contextMenu {
                                Button(targets == 1 ? "Quick Look" : "Quick Look \(targets) Items") {
                                    onQuickLook(row.node)
                                }
                                Button(targets == 1 ? "Reveal in Finder" : "Reveal \(targets) Items in Finder") {
                                    onReveal(row.node)
                                }
                                Divider()
                                Button(
                                    targets == 1 ? "Move to Trash…" : "Move \(targets) Items to Trash…",
                                    role: .destructive
                                ) {
                                    onReclaim(row.node)
                                }
                            }
                        }

                        if hasMoreRows {
                            InlineActionButton(
                                "Show More",
                                systemImage: "chevron.down",
                                fillsWidth: true,
                                action: onShowMore
                            )
                            .padding(.vertical, DS.Spacing.xSmall)
                            .help("Show the next \(min(DS.Size.explorerPageSize, remainingCount)) items")
                            .accessibilityLabel("Show more items")
                            .accessibilityHint("Shows the next \(min(DS.Size.explorerPageSize, remainingCount)) items")
                        }
                    }
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .modifier(ScrollActivityReporter(onChange: { scrolling in
                onScrollActivity(scrolling)
                // The pointer has not moved, but the rows under it have: restore
                // the highlight the moment the list settles.
                if !scrolling { restoreHover() }
            }))
            .modifier(ScrollMetricsReader(metrics: metrics))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): metrics.pointer = point
                case .ended: metrics.pointer = nil
                }
            }
            .onKeyPress(phases: .down) { press in key(press) }
            .onChange(of: isFocused) { _, focused in
                guard focused else {
                    press.isPressed = false
                    return
                }
                // Tabbing into the list puts the cursor on the first row, so the
                // list has a visible focus rather than being focused invisibly.
                // A click focuses the list on mouse-down, before the row's own
                // action runs, so it must not be mistaken for that.
                if !press.isPressed && selection.focused == nil && !rows.isEmpty {
                    onJump(0, false)
                }
            }
            // Recorded before the focus change that the same event causes, which
            // is why this is a plain reference type rather than view state: the
            // focus handler must see the press immediately, not on the next pass.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in press.isPressed = true }
                    .onEnded { _ in press.isPressed = false }
            )
            .onChange(of: selection.focused) { _, focused in
                guard let focused else { return }
                reveal(focused, with: proxy)
            }
            // The detail pane below the list claims its own height, so a click on
            // a row at the list's foot can select a row that the smaller viewport
            // then hides. Reacting to the list's height catches that change after
            // layout and scrolls the focused row clear of the pane.
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onChange(of: geometry.size.height) { oldHeight, newHeight in
                            guard newHeight < oldHeight,
                                  let focused = selection.focused else { return }
                            reveal(focused, with: proxy)
                        }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Files and folders")
            .accessibilityHint("Use the arrow keys to move through the list, Space to preview, and Return to open.")
        }
    }

    /// Scrolls the focused row just clear of the list's edges. The default anchor
    /// moves the list no further than the row needs, so a row already on screen
    /// stays where it is.
    ///
    /// This is immediate rather than animated: it runs as the detail pane takes
    /// its height, and the row should be in view in that pass rather than after
    /// an animation.
    private func reveal(_ url: URL, with proxy: ScrollViewProxy) {
        proxy.scrollTo(url)
    }

    /// Lights whichever row the pointer is over, once the list has settled.
    ///
    /// Hover is suspended for the duration of a scroll, and rows moving under a
    /// still pointer do not produce a new hover event, so the row that ended up
    /// under it would stay unlit until the pointer moved. This resolves it from
    /// the pointer's place and the content offset instead.
    private func restoreHover() {
        guard let pointer = metrics.pointer,
              let index = ExplorerHoverRow.index(pointerY: pointer.y,
                                                 contentOffset: metrics.contentOffset,
                                                 rowHeight: metrics.rowHeight),
              rows.indices.contains(index) else { return }
        hover.set(rows[index].url, true)
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        // Command, Option and Control belong to the system or the app's menus.
        // Only plain keys and Shift are the list's own.
        if press.modifiers.contains(.command)
            || press.modifiers.contains(.option)
            || press.modifiers.contains(.control) {
            return .ignored
        }
        let extending = press.modifiers.contains(.shift)
        if press.key == .upArrow {
            onMove(-1, extending)
            return .handled
        }
        if press.key == .downArrow {
            onMove(1, extending)
            return .handled
        }
        if press.key == .home {
            onJump(0, extending)
            return .handled
        }
        if press.key == .end {
            onJump(rows.count - 1, extending)
            return .handled
        }
        if press.key == .space {
            guard !selection.isEmpty else { return .ignored }
            onQuickLook(nil)
            return .handled
        }
        if press.key == .return {
            guard let focused = selection.focused,
                  let node = rows.first(where: { $0.url == focused })?.node else { return .ignored }
            onOpen(node)
            return .handled
        }
        if press.key == .escape {
            guard !selection.isEmpty else { return .ignored }
            onEscape()
            return .handled
        }
        return .ignored
    }
}

/// Reports the list's scroll activity to the view model.
///
/// A snapshot applied mid-scroll rebuilds the chart and the list under the
/// user's hand, so the model holds progressive snapshots while the list moves.
/// `ScrollPhase` arrives with macOS 15; on macOS 14 the list simply keeps its
/// earlier cadence.
private struct ScrollActivityReporter: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                onChange(phase.isScrolling)
            }
        } else {
            content
        }
    }
}

/// Reports the content offset into the metrics box without touching view state.
private struct ScrollMetricsReader: ViewModifier {
    let metrics: ScrollHoverMetrics

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                metrics.contentOffset = offset
            }
        } else {
            content
        }
    }
}

/// Measures one row's height, which is every row's height.
private struct RowHeightReader: ViewModifier {
    let metrics: ScrollHoverMetrics
    let isSampled: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), isSampled {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                metrics.rowHeight = height
            }
        } else {
            content
        }
    }
}

/// The one sheet this screen can present. Keeping it single avoids stacking
/// two presentations on the same view, where only the last one is reliable.
private enum ResultsSheet: String, Identifiable {
    case reclaim
    case coverage
    case cleanup
    case history

    var id: String { rawValue }
}

/// Which list the explorer is showing.
///
/// `categories` is the odd one out by design: the other three list nodes, while it
/// lists the scan's own category tallies and has no rows to select. It is public
/// so the app and the offscreen renderer can open the results in it.
public enum ExplorerMode: String, CaseIterable, Identifiable {
    case folder
    case topFiles
    case topFolders
    case categories

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: "This Folder"
        case .topFiles: "Top Files"
        case .topFolders: "Top Folders"
        case .categories: "Categories"
        }
    }
}

/// The explorer inputs that decide which rows are on screen.
private struct ExplorerRowKey: Equatable {
    var search: String
    var sort: SortOrder
    var mode: ExplorerMode
}

/// The inputs the visible rows are derived from.
///
/// A change to any of them — new scan data, a different folder, a search, or
/// ordering, or a different list — is what makes the list stale. Nothing else
/// is.
private struct ExplorerRowsKey: Equatable {
    var revision: Int
    var breadcrumb: [UUID]
    var search: String
    var sort: SortOrder
    var mode: ExplorerMode
    var maxChildren: Int
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

/// One explorer row, resolved from a node once per list change.
///
/// The row body draws these values directly, so the comparatively costly work —
/// composing the subtitle and formatting the size — happens when the list is
/// rebuilt rather than on every redraw.
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
    /// A dot-leading name is the bundle-visible convention for a hidden item.
    /// The scan can include these, so the row and detail pane name them rather
    /// than presenting them as ordinary entries.
    let isHiddenName: Bool
    let subtitle: String
    let subtitleIsPath: Bool
    let sizeText: String

    init(node: ScanNode, showsLocation: Bool = false) {
        self.node = node
        url = node.url
        name = node.name
        isDirectory = node.isDirectory
        isSymlink = node.isSymlink
        isAccessible = node.isAccessible
        isHiddenName = node.name.hasPrefix(".")
        subtitleIsPath = showsLocation
        if showsLocation {
            subtitle = PathFormat.abbreviated(node.url.path)
        } else if node.isDirectory {
            subtitle = "\(CountFormat.files(node.fileCount)) in \(CountFormat.folders(node.directoryCount))"
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
            && lhs.isHiddenName == rhs.isHiddenName
            && lhs.subtitle == rhs.subtitle
            && lhs.subtitleIsPath == rhs.subtitleIsPath
            && lhs.sizeText == rhs.sizeText
    }
}

/// One explorer row.
///
/// Hover is the same accent wash the category list uses, deliberately quieter
/// than the selection fill, so "where the pointer is" and "what I clicked" never
/// read the same. The row publishes its URL to the shared hover state while the
/// pointer is over it, which is what lights the matching wedge.
///
/// The row compares equal to itself while the values it draws, its selection and
/// its hover state are unchanged, so a change to one row — or to anything else on
/// the screen — does not re-render the rest of the list. It draws no divider of
/// its own: spacing separates the list, matching the category list.
private struct NodeRow: View, Equatable {
    @Environment(\.controlActiveState) private var controlActiveState

    let row: ExplorerRow
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    nonisolated static func == (lhs: NodeRow, rhs: NodeRow) -> Bool {
        lhs.row == rhs.row
            && lhs.isSelected == rhs.isSelected
            && lhs.isHovered == rhs.isHovered
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: row.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(DS.Color.graphite)
                VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                    Text(row.name)
                        .font(DS.Typography.body)
                        .foregroundStyle(row.isHiddenName ? DS.Color.mutedText : DS.Color.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.subtitle)
                        .font(DS.Typography.caption)
                        .foregroundStyle(row.subtitleIsPath ? DS.Color.mutedText : DS.Color.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(row.sizeText)
                    .font(DS.Typography.figures)
                    .foregroundStyle(DS.Color.secondaryText)
                if row.isSymlink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(DS.Icon.detail)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                if !row.isAccessible {
                    Image(systemName: "lock.fill")
                        .font(DS.Icon.detail)
                        .foregroundStyle(DS.Color.warning)
                }
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.small)
            .background(
                rowBackground,
                in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
            )
            .dsHoverableRow(isHovered: isHovered && !isSelected, radius: DS.Radius.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover(perform: onHover)
        .accessibilityLabel("\(row.name)\(row.isHiddenName ? ", hidden item" : ""), \(row.subtitle), \(row.sizeText)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var rowBackground: SwiftUI.Color {
        if isSelected {
            return controlActiveState == .key
                ? DS.Color.accent.opacity(DS.Opacity.rowSelection)
                : DS.Color.primaryText.opacity(DS.Opacity.rowSelectionInactive)
        }
        return .clear
    }
}

private extension View {
    /// Removes the system title item where available, so the results toolbar shows
    /// only Home and the folder trail.
    @ViewBuilder
    func resultsToolbarTitleHidden() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}
