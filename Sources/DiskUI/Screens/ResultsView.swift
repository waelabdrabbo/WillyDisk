import SwiftUI
import AppKit
import DiskCore
import DiskLocalization

/// Screen C — analysis results, and the live state while a scan runs.
///
/// One screen serves both roles. While a scan runs the top of the
/// screen shows the honest progress — a determinate bar with a percentage only
/// when the engine reports a reliable fraction, otherwise an indeterminate
/// indicator, never a fabricated number — and the results fill in as the
/// engine's progressive snapshots arrive. Once settled, the explorer and chart
/// take the whole screen: the explorer column leads with a compact header that
/// names the scanned location and its size, search/sort/filter, and file
/// details, the chart takes the rest, and the explorer's foot holds the single
/// access notice. An interactive
/// sunburst (click a folder to drill
/// down, with the chart's own path bar following the depth), Reveal in
/// Finder, rescan, and report export round it out.
@MainActor
public struct ResultsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var viewModel: ScanViewModel

    // Chart / explorer navigation
    @State private var breadcrumb: [ScanNode] = []
    @State private var selection = ExplorerSelection()
    @FocusState private var listFocused: Bool
    @State private var quickLook = QuickLookPreview()

    /// The explorer column's width. The seam keeps it inside the band the chart
    /// can spare.
    @State private var explorerWidth: CGFloat = 362
    /// The width the drag started from, so every change applies the gesture's
    /// total translation to the width the pointer went down on.
    @State private var explorerResizeStart: CGFloat?

    // Explorer controls
    @State private var searchText = ""
    @State private var searchFocusRequest = 0
    /// What the last whole-scan search found. The list presents it instead of the
    /// folder while the field has a query; clearing the field is what puts the
    /// folder back.
    @State private var searchResults: ScanSearchResults?
    /// The search in flight, held so the next keystroke can cancel its walk.
    @State private var searchRun: Task<ScanSearchResults?, Never>?
    @State private var isSearching = false
    /// Bumped when a search lands, so the rows rebuild once for a new result set
    /// rather than once per redraw.
    @State private var searchRevision = 0
    /// The selection a search drill carries across the mode switch that shows its
    /// folder; the mode-change handler applies it after clearing the old one.
    @State private var drillSelection: URL?
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
    /// its explorer column, with the views it already has.
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

    public init(
        viewModel: ScanViewModel = ScanViewModel(),
        initialMode: ExplorerMode = .folder,
        initialSearch: String = ""
    ) {
        _viewModel = State(initialValue: viewModel)
        _explorerMode = State(initialValue: initialMode)
        _searchText = State(initialValue: initialSearch)
    }

    // MARK: - Derived data

    /// The results to render: the terminal summary once the scan has settled,
    /// otherwise the newest in-flight snapshot so the screen fills in while the
    /// scan runs.
    private var summary: ScanSummary? { viewModel.liveSummary }

    /// Whether a scan is still running and the visible results will keep growing.
    /// A quiet refresh is not a live scan: it measures in the background while
    /// the screen keeps showing the previous summary.
    private var isLiveScan: Bool { viewModel.isScanning && !viewModel.isRefreshing }

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

    // MARK: - Whole-scan search

    /// The query the search field holds, without surrounding whitespace. A field
    /// holding only spaces is not a search.
    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the list is a search's results rather than a folder or a ranked
    /// list. The mode and the breadcrumb are untouched by a search, so clearing
    /// the field restores the scope that was on screen before it.
    private var isSearchActive: Bool { !searchQuery.isEmpty }

    /// The entries a search walks: the finished root's folder tree, or, while a
    /// scan is still walking, the root's entries as known so far. The root itself
    /// is the scope, not a result, so it is never searched.
    private var searchForest: [ScanNode] {
        guard let summary else { return [] }
        if let root = rootNode(in: summary) { return root.children }
        return summary.rootChildren
    }

    /// The matches in the list's current order.
    ///
    /// Search holds the largest matches and counts every one; the list applies
    /// the same ordering as a folder, so the sort control means the same thing in
    /// both scopes.
    private var searchRows: [ExplorerRow] {
        guard let results = searchResults else { return [] }
        return ExplorerQuery.ordered(results.matches, sort: sortOrder).map {
            ExplorerRow(node: $0, location: .containingFolder)
        }
    }

    /// Starts the search for what the field now holds.
    ///
    /// The walk happens off the main actor and behind a short quiet period, so a
    /// keystroke neither blocks the screen nor starts a walk that the next
    /// keystroke immediately replaces. Every new query cancels the one before it,
    /// and the walk checks cancellation between nodes.
    private func startSearch(_ text: String, debounce: Bool = true) {
        searchRun?.cancel()
        searchRun = nil

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, summary != nil else {
            isSearching = false
            searchResults = nil
            return
        }

        isSearching = true
        let forest = searchForest
        let task: Task<ScanSearchResults?, Never> = Task.detached(priority: .userInitiated) {
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return nil }
            }
            return ScanSearch.results(
                for: query,
                searching: forest,
                isCancelled: { Task.isCancelled }
            )
        }
        searchRun = task
        Task { @MainActor in
            let results = await task.value
            guard !task.isCancelled, searchText == text else { return }
            searchResults = results
            searchRevision &+= 1
            isSearching = false
        }
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
        let key = ExplorerRowsKey(
            revision: viewModel.resultsRevision,
            breadcrumb: breadcrumb.map(\.id),
            search: searchText,
            // A new search result set has the same query as the one it replaces,
            // so the revision is what makes the rows rebuild exactly once.
            searchResults: isSearchActive ? searchRevision : -1,
            sort: sortOrder,
            mode: explorerMode,
            maxChildren: chartChildLimit
        )
        switch ExplorerListSource.resolve(isSearchActive: isSearchActive, mode: explorerMode) {
        case .searchMatches:
            return rowsCache.rows(for: key) { searchRows }
        case .categoryFiles:
            // The category detail is the bounded list of the files the walk
            // returned, so it is built directly rather than through the cache.
            return (categoryFiles?.files ?? []).map {
                ExplorerRow(node: $0, location: .itemPath)
            }
        case .nodeList:
            return rowsCache.rows(for: key) {
                let nodes: [ScanNode]
                switch explorerMode {
                case .folder:
                    nodes = ExplorerQuery.entries(in: currentChildren, sort: sortOrder)
                case .topFiles, .topFolders:
                    nodes = ExplorerQuery.ranked(topNodes)
                case .categories:
                    nodes = []
                }
                return nodes.map {
                    ExplorerRow(node: $0, location: explorerMode != .folder ? .itemPath : .none)
                }
            }
        }
    }

    /// The rows the current scope can select: every entry in the folder, the
    /// engine's ranked lists, the open category's files, or the whole scan's
    /// matches while a search is active. Filtering narrows what the list draws,
    /// not what a selection may hold, so typing in the search field does not
    /// throw away a choice made before the typing started.
    private var scopeNodes: [ScanNode] {
        if isSearchActive {
            return searchResults?.matches ?? []
        }
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

    /// How many rows the list draws. A folder pages so a huge directory never
    /// builds every row at once; a search's result set is already bounded, so it
    /// is shown whole and stays virtualized by the list itself.
    private var rowLimit: Int {
        isSearchActive ? visibleRows.count : visibleItemLimit
    }

    private var displayedRows: [ExplorerRow] {
        Array(visibleRows.prefix(rowLimit))
    }

    private var displayedRowOrder: [URL] { displayedRows.map(\.url) }
    private var hasMoreRows: Bool {
        visibleRows.count > rowLimit
    }

    /// Where the spindle hole leads: up one folder, or back to all categories.
    private var chartCenterAction: (() -> Void)? {
        if explorerMode == .categories {
            return drilledCategory == nil ? nil : { closeCategory() }
        }
        return breadcrumb.isEmpty ? nil : { goToBreadcrumb(depth: breadcrumb.count - 1) }
    }

    private var chartCenterHint: String {
        if explorerMode == .categories { return L10n.string("Show all categories") }
        guard !breadcrumb.isEmpty else { return L10n.string("The scanned location") }
        return breadcrumb.count == 1
            ? L10n.string("Return to the scanned location")
            : L10n.format("Go up to %@", breadcrumb[breadcrumb.count - 2].name)
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
    private var remainingRowCount: Int { max(visibleRows.count - rowLimit, 0) }

    /// The inputs that decide which rows are on screen. When any of them changes
    /// the list is reshuffled, so a hover is dropped rather than left pointing
    /// at a row that is no longer rendered.
    private var rowSetKey: ExplorerRowKey {
        ExplorerRowKey(search: searchText, sort: sortOrder, mode: explorerMode)
    }

    /// Honest copy for an empty chart — an empty result set means something
    /// different while a scan is still filling in than after it has settled.
    private var chartEmptyMessage: String {
        isLiveScan ? L10n.string("Reading the first folders…") : L10n.string("This folder has nothing big enough to draw.")
    }

    /// Honest copy for an empty explorer list, in the same two situations.
    private var listEmptyMessage: String {
        if isSearchActive {
            if isSearching || searchResults == nil {
                return L10n.string("Searching every file and folder…")
            }
            return L10n.format(
                isLiveScan ? "No matches so far for “%@”" : "No matches for “%@”",
                searchQuery
            )
        }
        if explorerMode == .categories {
            if let category = drilledCategory {
                return L10n.format(
                    isLiveScan ? "No %@ files yet" : "No %@ files in this scan",
                    category.displayName
                )
            }
            return L10n.string("No categories")
        }
        if explorerMode != .folder {
            if isLiveScan { return L10n.string("Waiting for the first items…") }
            return L10n.string(explorerMode == .topFiles ? "No files to rank" : "No folders to rank")
        }
        if isLiveScan { return L10n.string("Waiting for the first items…") }
        // The folder holds entries, but none of them has bytes to list.
        if !currentChildren.isEmpty { return L10n.string("Nothing here has a size") }
        return L10n.string("This folder is empty")
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
                ContentUnavailableView(L10n.string("No results"), systemImage: "chart.pie", description: Text(L10n.string("Run a scan to see storage analysis.")))
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
        .onChange(of: searchText) { _, text in
            // A search replaces the list's scope without changing the mode or the
            // folder, so clearing the field is all it takes to restore them.
            startSearch(text)
        }
        .onChange(of: searchRevision) { _, _ in
            // A new match set can retire rows a hover or a selection was about.
            hover.url = nil
            pruneSelection()
        }
        .onChange(of: explorerMode) { _, newMode in
            // The list's scope changed, so a selection, a hover, and a search
            // that were about the old list would otherwise point at rows that are
            // no longer on screen.
            hover.url = nil
            clearSelection()
            // A drill from a search result is the one mode change that brings its
            // own selection with it.
            if let url = drillSelection {
                selection.selectOnly(url)
            }
            drillSelection = nil
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
            pruneBreadcrumb()
            // A quiet refresh replaces the settled tree a search ran over. A live
            // scan's partials arrive far too often to restart a whole-tree walk
            // for each one, so the search re-runs when the walk is done.
            if isSearchActive && !isLiveScan {
                startSearch(searchText)
            }
        }
        .onChange(of: viewModel.isWatchingEnabled) { _, _ in
            viewModel.watchPreferenceChanged()
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
            // A whole-tree walk is worth stopping with the screen that asked for
            // it, even though it is off the main actor.
            searchRun?.cancel()
            searchRun = nil
        }
        .task(id: viewModel.scanRun) {
            // Re-run for every scan and on Rescan: grant Full Disk Access in
            // System Settings, hit Rescan, and the notice must disappear.
            fullDiskAccessGranted = await FullDiskAccessProbe.isGranted()
        }
        .task {
            // A screen opened with a query already in the field searches at once
            // rather than waiting out the debounce meant for typing.
            guard !searchText.isEmpty else { return }
            startSearch(searchText, debounce: false)
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
                    Label(L10n.string("Home"), systemImage: "house")
                }
                .help(L10n.string("Return to source selection"))
                .accessibilityLabel(L10n.string("Home"))
                .accessibilityHint(L10n.string("Shows source selection; a scan that is running keeps running"))
            }
            // A flexible spacer keeps Coverage, Rescan, and Export trailing while
            // Home stays at the leading edge.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            } else if #available(macOS 15.0, *) {
                ToolbarItem(placement: .principal) { Spacer() }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showHistory()
                } label: {
                    Label(L10n.string("History"), systemImage: "clock.arrow.circlepath")
                }
                .help(L10n.string("Compare this location's recorded scans"))
                .disabled(summary == nil || viewModel.history == nil)

                Button {
                    showCleanup()
                } label: {
                    Label(L10n.string("Cleanup"), systemImage: "sparkles")
                }
                .help(L10n.string("Large, old, and cache items worth reviewing"))
                .disabled(summary == nil || viewModel.isScanning)

                Button {
                    showCoverage()
                } label: {
                    Label(L10n.string("Coverage"), systemImage: "info.circle")
                }
                .help(L10n.string("What this scan counted, and what it did not"))
                .disabled(summary == nil)

                Button {
                    rescan()
                } label: {
                    Label(L10n.string("Rescan"), systemImage: "arrow.counterclockwise")
                }
                .help(L10n.string(viewModel.isScanning
                      ? "A scan is already running — cancel it first to start again"
                      : "Scan the current location again"))
                .disabled(viewModel.isScanning)

                Menu {
                    Button(L10n.string("Export as JSON…")) { exportJSON() }
                        .disabled(summary == nil)
                    Button(L10n.string("Export as CSV…")) { exportCSV() }
                        .disabled(summary == nil)
                    Divider()
                    Button(L10n.string("Export Diagnostics…")) { exportDiagnostics() }
                        .disabled(viewModel.currentRoot == nil)
                } label: {
                    Label(L10n.string("Export"), systemImage: "square.and.arrow.up")
                }
                .help(L10n.string("Export the analysis report or diagnostics"))
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
        breadcrumb.last?.name ?? scannedRootName ?? L10n.string("WillyDisk")
    }

    /// The size the header states: the focused folder's, not the whole scan's.
    ///
    /// The chart's centre disc sums the same children, so the header and the disc
    /// agree at every depth. While a scan is running this is the folder's size as
    /// known so far; the status strip carries the scan's own progress, which is
    /// the number that moves.
    private var focusedTotal: Int64 {
        if let node = resolvedFocus ?? breadcrumb.last { return node.logicalSize }
        if viewModel.isScanning {
            return currentChildren.reduce(Int64(0)) { $0 + max($1.logicalSize, 0) }
        }
        return viewModel.displayedTotal
    }

    /// The results layout: the explorer column leads and the chart takes what is
    /// left.
    ///
    /// The bands are told apart by their own spacing and fills, not by rules. The
    /// explorer keeps the width the seam gives it; the chart is the flexible
    /// remainder, so a wider window is chart, never a wider list.
    private var content: some View {
        HStack(spacing: 0) {
            explorerPane
                .dsGlassControl(cornerRadius: DS.Radius.panel)
                .padding(DS.Spacing.medium)
                .frame(width: explorerWidth)
            explorerResizeHandle
            chartPane
        }
    }

    /// The explorer column's width band: enough for a name and its size while
    /// leaving the chart the majority of the window.
    private static let explorerWidthRange: ClosedRange<CGFloat> = 300...560

    /// The seam between the explorer column and the chart.
    ///
    /// The pointer turns into the column-resize cursor and a drag widens or
    /// narrows the explorer.
    /// The drag is read in the layout direction, so dragging toward the window's
    /// edge grows the column in either reading direction.
    private var explorerResizeHandle: some View {
        Color.clear
            .frame(width: DS.Spacing.medium)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = explorerResizeStart ?? explorerWidth
                        if explorerResizeStart == nil { explorerResizeStart = start }
                        let delta = value.translation.width * (layoutDirection == .rightToLeft ? -1 : 1)
                        explorerWidth = min(
                            max(start + delta, Self.explorerWidthRange.lowerBound),
                            Self.explorerWidthRange.upperBound
                        )
                    }
                    .onEnded { _ in explorerResizeStart = nil }
            )
            .accessibilityHidden(true)
    }

    // MARK: - Access notice

    /// The single merged access notice, at the foot of the explorer column.
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
            chartHeader
            if isSearchActive {
                searchChart
            } else if explorerMode == .categories {
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
                        centerLabel: scannedRootName ?? L10n.string("This scan"),
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
                    centerLabel: breadcrumb.last?.name ?? scannedRootName ?? L10n.string("Root"),
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

    /// The chart's own path bar: the folder the chart is centred on, with every
    /// ancestor a step back up.
    ///
    /// It lives in the pane rather than in the window toolbar so it travels with
    /// the chart in both reading directions, instead of staying pinned to the
    /// window's leading edge where it no longer describes the chart beside it.
    ///
    /// The path appears only when it can take you somewhere: below the scanned
    /// root, where the ancestors are steps back up, and outside Categories, whose
    /// ring charts the whole scan rather than the open folder. The row keeps its
    /// height in every state, so the chart does not shift when the path comes or
    /// goes.
    private var chartHeader: some View {
        HStack(spacing: 0) {
            if showsChartPath {
                breadcrumbTrail
            }
            Spacer(minLength: 0)
        }
        .frame(height: DS.Size.iconButton)
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.xSmall)
    }

    private var showsChartPath: Bool {
        explorerMode != .categories && !breadcrumb.isEmpty
    }

    /// The chart pane while a search is active.
    ///
    /// A sunburst maps one folder's children, whose sizes partition their parent.
    /// A search's matches do not partition anything — a matched file can sit
    /// inside a matched folder — so drawing them would sum overlapping bytes into
    /// a whole the app cannot explain. The pane says what the search found and
    /// where the chart comes back from instead.
    private var searchChart: some View {
        VStack(spacing: DS.Spacing.small) {
            WillyDiskMark(size: 44)
            Text(searchChartTitle)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.primaryText)
                .multilineTextAlignment(.center)
            Text(L10n.format("The chart maps one folder at a time. Clear the search to return to “%@”.", folderTitle))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: DS.Size.scanStatusWidth)
        }
        .padding(DS.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var searchChartTitle: String {
        guard let results = searchResults else {
            return L10n.string("Searching every file and folder…")
        }
        if isSearching { return L10n.string("Searching…") }
        if results.matchCount == 0 {
            return isLiveScan
                ? L10n.string("No matches so far")
                : L10n.format("No matches for “%@”", searchQuery)
        }
        return results.isTruncated
            ? L10n.format("Showing the largest %lld of %@", results.matches.count, CountFormat.matches(results.matchCount))
            : L10n.format("%@ for “%@”", CountFormat.matches(results.matchCount), searchQuery)
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
            Text(L10n.format(
                isLiveScan ? "No %@ files yet" : "No %@ files to draw",
                category.displayName
            ))
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
            // The search field is on every list. Its query searches the scan, not
            // the list, so a match set takes over whichever mode was showing until
            // the field is cleared.
            explorerToolbar
            if isSearchActive {
                searchSummaryBar
                contentsList
                    .frame(maxHeight: .infinity)
            } else if explorerMode == .categories {
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
                contentsList
                    // The list is the flexible band: it gives up height to the
                    // detail pane and the access notice at the explorer's foot.
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
        // The explorer is a fixed-height column, not a stack that grows to its
        // content: its list is the part that scrolls. Without this frame an
        // expanded notice can make the pane report its ideal content height and
        // push the whole window's content out of view.
        .frame(maxHeight: .infinity, alignment: .top)
        // Match the notice's vertical inset so the pane does not read tight at
        // the top while the notice at its foot has breathing room.
        .padding(.top, DS.Spacing.small)
    }

    /// What the category list is, in one line. The sort control belongs to the
    /// node lists and is not shown here; the search field is, because it searches
    /// the scan rather than the nine categories.
    private var categoryModeCaption: some View {
        Text(L10n.string("Share of this scan's logical size. Choose a category to see its largest files."))
            .font(DS.Typography.caption)
            .foregroundStyle(DS.Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.bottom, DS.Spacing.small)
    }

    /// The way back out of a category, and what its list is showing.
    private func categoryDetailHeader(_ category: FileCategory) -> some View {
        HStack(spacing: DS.Spacing.xSmall) {
            InlineActionButton(L10n.string("All Categories"), systemImage: "chevron.left") {
                closeCategory()
            }
            .help(L10n.string("Show every category"))
            .accessibilityLabel(L10n.string("All Categories"))
            .accessibilityHint(L10n.string("Closes this category and shows the whole breakdown"))

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
                          ? L10n.format("Showing the largest %lld of %@", files.files.count, CountFormat.files(files.matchCount))
                          : CountFormat.files(files.matchCount))
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.small)
    }

    private func categorySummary(_ files: CategoryFiles) -> String {
        let size = ByteFormat.string(files.totalLogicalSize)
        if isLiveScan {
            return L10n.format("%@ · largest %lld so far", size, files.files.count)
        }
        if files.stoppedAtLimit {
            return L10n.format("%@ · sample of %@", size, CountFormat.files(files.matchCount))
        }
        if files.isTruncated {
            return L10n.format("%@ · largest %lld of %lld", size, files.files.count, files.matchCount)
        }
        return L10n.format("%@ · %@", size, CountFormat.files(files.matchCount))
    }

    private func categoryFilesLoading(_ category: FileCategory) -> some View {
        VStack(spacing: DS.Spacing.small) {
            ProgressView()
            Text(L10n.format("Reading the %@ files…", category.displayName))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// The switch between the folder in the chart and the two largest lists.
    private var explorerModeBar: some View {
        HStack(spacing: 0) {
            Picker(L10n.string("Explorer view"), selection: $explorerMode) {
                ForEach(ExplorerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .dsSegmentedSwitch()
            .accessibilityLabel(L10n.string("Explorer view"))
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
                scannedRootName ?? L10n.string("Scanned Folder"),
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Folder path"))
    }

    /// Both branches reserve the same box. The current folder is plain text, but
    /// it keeps the inset and the hit-target height an ancestor crumb wears, so
    /// the name does not shift when a drill turns it into a link and back.
    @ViewBuilder
    private func crumb(_ name: String, isCurrent: Bool = false, action: @escaping () -> Void) -> some View {
        if isCurrent {
            Text(name)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.primaryText)
                .lineLimit(1)
                .padding(.horizontal, DS.Spacing.xSmall)
                .frame(minHeight: DS.Size.iconButton)
                .accessibilityAddTraits(.isHeader)
        } else {
            BreadcrumbCrumb(name: name, action: action)
        }
    }

    /// One ancestor crumb. The trail stays quiet at rest; hovering raises the
    /// secondary name to the accent and fills the same chip an inline action
    /// wears, so a way back up is recognisable as a control.
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
                    .padding(.horizontal, DS.Spacing.xSmall)
                    .frame(minHeight: DS.Size.iconButton)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                            .fill(DS.Color.accent.opacity(isHovered ? DS.Opacity.rowHover : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(L10n.format("Show “%@”", name))
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
                if viewModel.isUpdating || (viewModel.isWatching && !viewModel.resultsAreStale) {
                    WatchStatusChip(isUpdating: viewModel.isUpdating)
                }
                Spacer(minLength: DS.Spacing.small)
                Text(ByteFormat.string(focusedTotal))
                    .font(DS.Typography.metric)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.primaryText)
                    // The total is the one figure on the row that must survive
                    // whole: it holds one line and gives way in points only at
                    // the narrowest column, where the folder name truncates.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }
            // The full timestamp would push the line past the column's
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
            if viewModel.resultsAreStale && !viewModel.isUpdating {
                StaleResultsBadge(message: staleMessage, onRescan: rescan)
            }
            if viewModel.stoppedEarly { stoppedEarlyNote }
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.vertical, DS.Spacing.xSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the stale marker names. The watcher's folders are the ones that
    /// actually changed; a move to the Trash has no folder list and keeps the
    /// general wording.
    private var staleMessage: String {
        guard let first = viewModel.changedFolders.first else {
            return L10n.string("Results changed since this scan. Rescan.")
        }
        if viewModel.changedFoldersWereTruncated {
            return L10n.format("Changed in Finder in %lld+ folders. Rescan.", viewModel.changedFolderCount)
        }
        if viewModel.changedFolderCount <= 1 {
            return L10n.format("Changed in Finder: “%@”. Rescan.", first.lastPathComponent)
        }
        return L10n.format("Changed in Finder in %lld folders. Rescan.", viewModel.changedFolderCount)
    }

    /// Counts for the list's scope: the folder's own entries while the chart and
    /// list agree on a folder, and the whole scan's counts while the list is one
    /// of the largest lists.
    private var countsText: String {
        if explorerMode == .folder {
            return L10n.format(
                "%@ across %@",
                CountFormat.files(summary?.fileCount ?? 0),
                CountFormat.items(presentableChildren.count)
            )
        }
        guard let s = summary else { return CountFormat.files(0) }
        // The scan root is a folder in the summary, but it is the scan itself and
        // never one of its own subfolders, so the largest-list counts leave it out.
        return L10n.format(
            "%@ in %@",
            CountFormat.files(s.fileCount),
            CountFormat.folders(max(0, s.directoryCount - 1))
        )
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
            // A translated date and duration can outgrow the explorer's
            // column; two lines keep the whole stamp readable rather than
            // ending it with an ellipsis.
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
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
            Text(L10n.string("Stopped early — these results are partial"))
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
            // The sort control is a folder list's, so it is absent from the
            // other modes. Reserving its height on the field keeps the toolbar —
            // and everything under it — in one place as the mode changes.
            .frame(minHeight: DS.Size.iconButton)

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
                .help(L10n.format("Sort by %@", sortOrder.label))
                .accessibilityLabel(L10n.string("Sort"))
                .accessibilityValue(sortOrder.label)
            }
        }
        .padding(DS.Spacing.small)
    }

    private var searchPrompt: String {
        L10n.string("Search this scan")
    }

    /// What the search found, in the explorer's own line.
    ///
    /// The list is bounded by design, so the line says how many matches there are
    /// and how much of them the list holds; a walk that stopped at the node cap
    /// says so rather than presenting a partial count as the whole answer.
    private var searchSummaryBar: some View {
        HStack(spacing: DS.Spacing.small) {
            if isSearching || searchResults == nil {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
            Text(searchSummaryText)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.medium)
        .padding(.bottom, DS.Spacing.small)
        .accessibilityElement(children: .combine)
    }

    private var searchSummaryText: String {
        guard let results = searchResults else {
            return L10n.string("Searching every file and folder…")
        }
        if isSearching { return L10n.string("Searching…") }
        if results.matchCount == 0 {
            return L10n.string(isLiveScan ? "No matches so far" : "No matches")
        }
        var text = results.isTruncated
            ? L10n.format("Showing the largest %lld of %@", results.matches.count, CountFormat.matches(results.matchCount))
            : CountFormat.matches(results.matchCount)
        if results.stoppedAtLimit {
            text = L10n.format(
                "%@ · searched the first %@",
                text,
                CountFormat.items(results.visitedCount)
            )
        }
        if isLiveScan {
            text = L10n.format("%@ so far", text)
        }
        return text
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
            onShowInFolder: isSearchActive ? { node in
                showInFolder(node)
            } : nil,
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

            detailRow(L10n.string("Path"), node.url.path)
            detailRow(L10n.string("Kind"), node.isDirectory ? L10n.string("Folder") : node.category.displayName)
            detailRow(L10n.string("Size"), ByteFormat.exact(node.logicalSize))
            detailRow(L10n.string("On disk"), ByteFormat.exact(node.allocatedSize))
            if node.name.hasPrefix(".") {
                detailRow(L10n.string("Visibility"), L10n.string("Hidden"))
            }
            if node.isDirectory {
                detailRow(L10n.string("Contents"), L10n.format("%@ in %@", CountFormat.files(node.fileCount), CountFormat.folders(node.directoryCount)))
            }
            if let modified = node.modifiedAt {
                detailRow(L10n.string("Modified"), DateFormat.short(modified))
            }
            if node.isSymlink {
                detailRow(L10n.string("Type"), L10n.string("Symbolic link"))
            }
            if !node.isAccessible {
                detailRow(L10n.string("Access"), node.errorMessage ?? L10n.string("Inaccessible"))
                    .foregroundStyle(DS.Color.warning)
            }

            if isSearchActive {
                Button {
                    showInFolder(node)
                } label: {
                    Label(L10n.string("Show in Folder"), systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.string("Leave the search and show the folder that holds this item"))
            }

            if node.isDirectory {
                Button {
                    activate(node)
                } label: {
                    Label(L10n.string("Browse This Folder"), systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                requestReclaim([node])
            } label: {
                Label(L10n.string("Move to Trash…"), systemImage: "trash")
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
            kind = L10n.string("Folders")
        } else if nodes.allSatisfy({ !$0.isDirectory }) {
            kind = L10n.string("Files")
        } else {
            kind = L10n.string("Files and folders")
        }
        let parents = Set(nodes.map { $0.url.deletingLastPathComponent() })
        let commonParent = parents.count == 1 ? parents.first : nil

        return VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: "square.stack.fill")
                    .foregroundStyle(DS.Color.accent)
                Text(L10n.format("%lld Items Selected", nodes.count))
                    .font(DS.Typography.headline)
                Spacer()
                detailHeaderActions(nodes)
            }

            detailRow(L10n.string("Kind"), kind)
            detailRow(L10n.string("Size"), ByteFormat.exact(logical))
            detailRow(L10n.string("On disk"), ByteFormat.exact(allocated))
            if let commonParent {
                detailRow(L10n.string("Location"), PathFormat.abbreviated(commonParent.path))
            }

            Text(L10n.string("Actions apply to the whole selection."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .padding(.top, DS.Spacing.xSmall)

            Button(role: .destructive) {
                requestReclaim(nodes)
            } label: {
                Label(L10n.format("Move %@ to Trash…", CountFormat.items(nodes.count)), systemImage: "trash")
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
            detailAction("eye", L10n.string("Quick Look")) {
                quickLook.toggle(nodes.map(\.url))
            }
            detailAction("arrow.up.forward.square", L10n.string("Reveal in Finder")) {
                revealInFinder(nodes)
            }
            detailAction("xmark", L10n.string("Close Details")) {
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
    /// entered, files open in their default application. A search's folder is not
    /// a child of the folder the explorer was showing, so it is opened the same
    /// way a search result drills to it.
    private func activate(_ node: ScanNode) {
        if node.isDirectory {
            if isSearchActive {
                openSearchResult(node)
            } else {
                enter(node)
            }
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

    /// Drills from a search result to the folder that holds it, selects it there,
    /// and clears the search so the explorer is back on a folder.
    private func showInFolder(_ node: ScanNode) {
        guard let chain = folderChain(holding: node.url.deletingLastPathComponent()) else {
            return
        }
        drill(to: chain, selecting: node.url)
    }

    /// Opens a folder result: the explorer lists that folder's own entries.
    private func openSearchResult(_ node: ScanNode) {
        guard node.isDirectory else {
            showInFolder(node)
            return
        }
        guard let chain = folderChain(holding: node.url) else {
            showInFolder(node)
            return
        }
        drill(to: chain, selecting: nil)
    }

    /// The folder chain from the scanned root down to `folder`, if the tree on
    /// screen holds it. A search result comes out of context, so the chain is what
    /// puts the explorer back at the folder that holds it; a result the current
    /// tree does not hold — one from a snapshot the screen has moved past —
    /// resolves to nothing rather than to a wrong folder.
    private func folderChain(holding folder: URL) -> [ScanNode]? {
        guard let summary, let root = rootNode(in: summary) else { return nil }
        return ExplorerPath.chain(to: folder, from: root)
    }

    /// Re-roots the explorer on a folder and clears the search. The list is
    /// paged, so a match below its first page is selected — and shown in the
    /// detail pane — without building every row above it.
    private func drill(to chain: [ScanNode], selecting url: URL?) {
        hover.url = nil
        // Clearing the field is what restores the folder scope the search
        // replaced; the mode and the breadcrumb only change for the drill itself.
        searchText = ""
        breadcrumb = chain
        if explorerMode == .folder {
            clearSelection()
            if let url { selection.selectOnly(url) }
        } else {
            // Switching to the folder list clears the selection on its way in, so
            // the drill's own selection waits for that to happen.
            drillSelection = url
            explorerMode = .folder
        }
        listFocused = true
        visibleItemLimit = DS.Size.explorerPageSize
    }

    /// Re-roots the chart at an ancestor. `depth` is how many crumbs are kept,
    /// so zero returns to the scanned location.
    private func goToBreadcrumb(depth: Int) {
        guard depth < breadcrumb.count else { return }
        hover.url = nil
        clearSelection()
        // Choosing a folder is a scope choice, so the search opens the way for it
        // rather than leaving the list on results that span every folder.
        searchText = ""
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
            canExportDiagnostics: viewModel.currentRoot != nil,
            exportDiagnostics: { exportDiagnostics() },
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

    private func exportDiagnostics() {
        DiagnosticsExport.export(from: viewModel)
    }

    /// Drops crumbs that no longer exist in the results on screen, and refreshes
    /// the ones that do so a folder's size comes from the current tree. A live
    /// scan's partial tree legitimately lacks folders that are still being
    /// walked, so this waits for a settled summary.
    private func pruneBreadcrumb() {
        guard !isLiveScan, !breadcrumb.isEmpty else { return }
        var level = rootNodes
        var kept: [ScanNode] = []
        for crumb in breadcrumb {
            guard let match = level.first(where: { $0.url == crumb.url }) else { break }
            kept.append(match)
            level = match.children
        }
        guard kept.map(\.id) != breadcrumb.map(\.id) else { return }
        breadcrumb = kept
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
            Text(L10n.format("%@, %@", CountFormat.files(viewModel.filesScanned), ByteFormat.string(viewModel.displayedTotal)))
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
            .accessibilityLabel(L10n.format("Scan %@ complete", percentText(fraction)))
        } else {
            HStack(spacing: DS.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Reading files…"))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.string("Scanning, progress not yet measurable"))
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
            Label(L10n.string("Cancel Scan"), systemImage: "stop.fill")
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
        .help(L10n.string("Stop the scan; the results gathered so far are kept"))
    }

    private func percentText(_ fraction: Double) -> String {
        L10n.format("%lld%%", Int((min(max(fraction, 0), 1) * 100).rounded()))
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
    /// Offered only while the list is a whole-scan search's results, where the
    /// row is out of the folder the explorer is showing.
    let onShowInFolder: ((ScanNode) -> Void)?
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
                                if let onShowInFolder, targets == 1 {
                                    Button(L10n.string("Show in Folder")) {
                                        onShowInFolder(row.node)
                                    }
                                    Divider()
                                }
                                Button(targets == 1
                                       ? L10n.string("Quick Look")
                                       : L10n.format("Quick Look %@", CountFormat.items(targets))) {
                                    onQuickLook(row.node)
                                }
                                Button(targets == 1
                                       ? L10n.string("Reveal in Finder")
                                       : L10n.format("Reveal %@ in Finder", CountFormat.items(targets))) {
                                    onReveal(row.node)
                                }
                                Divider()
                                Button(
                                    targets == 1
                                        ? L10n.string("Move to Trash…")
                                        : L10n.format("Move %@ to Trash…", CountFormat.items(targets)),
                                    role: .destructive
                                ) {
                                    onReclaim(row.node)
                                }
                            }
                        }

                        if hasMoreRows {
                            InlineActionButton(
                                L10n.string("Show More"),
                                systemImage: "chevron.down",
                                fillsWidth: true,
                                action: onShowMore
                            )
                            .padding(.vertical, DS.Spacing.xSmall)
                            .help(L10n.format("Show the next %lld items", min(DS.Size.explorerPageSize, remainingCount)))
                            .accessibilityLabel(L10n.string("Show more items"))
                            .accessibilityHint(L10n.format("Shows the next %lld items", min(DS.Size.explorerPageSize, remainingCount)))
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
            .accessibilityLabel(L10n.string("Files and folders"))
            .accessibilityHint(L10n.string("Use the arrow keys to move through the list, Space to preview, and Return to open."))
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
        case .folder: L10n.string("This Folder")
        case .topFiles: L10n.string("Top Files")
        case .topFolders: L10n.string("Top Folders")
        case .categories: L10n.string("Categories")
        }
    }
}

/// Which list the explorer draws.
///
/// A whole-scan search outranks the mode it was typed in: the query covers the
/// scan rather than the rows below the field, so Categories gives its category
/// list up for the matches like the other modes do.
enum ExplorerListSource: Equatable {
    case searchMatches
    case categoryFiles
    case nodeList

    static func resolve(isSearchActive: Bool, mode: ExplorerMode) -> Self {
        if isSearchActive { return .searchMatches }
        return mode == .categories ? .categoryFiles : .nodeList
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
    /// The whole-scan result set the rows were built from, or -1 when the list is
    /// a folder's entries or a ranked list.
    var searchResults: Int
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

/// What a row says under the name.
///
/// A folder's rows describe their contents, a ranked list says where each entry
/// is, and a search's rows name the folder that holds them, because a match can
/// be anywhere in the tree.
private enum ExplorerRowLocation {
    case none
    case itemPath
    case containingFolder
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

    init(node: ScanNode, location: ExplorerRowLocation = .none) {
        self.node = node
        url = node.url
        name = node.name
        isDirectory = node.isDirectory
        isSymlink = node.isSymlink
        isAccessible = node.isAccessible
        isHiddenName = node.name.hasPrefix(".")
        subtitleIsPath = location != .none
        switch location {
        case .none:
            subtitle = node.isDirectory
                ? L10n.format("%@ in %@", CountFormat.files(node.fileCount), CountFormat.folders(node.directoryCount))
                : node.category.displayName
        case .itemPath:
            subtitle = PathFormat.abbreviated(node.url.path)
        case .containingFolder:
            subtitle = PathFormat.abbreviated(node.url.deletingLastPathComponent().path)
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
        .accessibilityLabel(L10n.format(
            "%@%@, %@, %@",
            row.name,
            row.isHiddenName ? L10n.string(", hidden item") : "",
            row.subtitle,
            row.sizeText
        ))
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
