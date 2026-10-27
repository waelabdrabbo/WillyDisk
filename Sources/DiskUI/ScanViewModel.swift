import Foundation
import Observation
import DiskCore
import DiskLocalization

/// A non-fatal issue encountered during a scan. Scanning continues after these.
public struct ScanIssue: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let path: String
    public let message: String
    /// The shared classification carried off `ScanEvent.issue`, so the
    /// UI can separate expected permission denials from hard faults.
    public let kind: ScanIssueKind

    public init(path: String, message: String, kind: ScanIssueKind = .other) {
        self.id = UUID()
        self.path = path
        self.message = message
        self.kind = kind
    }
}

/// How settled results absorb filesystem changes.
///
/// A change is applied to the live tree where it happened, so nothing is
/// re-measured and no run is "too slow to keep current". The quiet period only
/// batches the burst one Finder action produces, and the bounds keep a single
/// batch from holding the updater in a long subtree walk.
public struct LiveUpdatePolicy: Sendable, Equatable {
    /// How long the root must stay quiet before a batch is applied.
    public var quietPeriod: Duration
    /// How many folders one batch reconciles.
    public var maxFoldersPerBatch: Int
    /// How many new folders one batch measures before the rest is deferred.
    public var maxSubtreeScansPerBatch: Int

    public static let standard = LiveUpdatePolicy(
        quietPeriod: .milliseconds(200),
        maxFoldersPerBatch: 512,
        maxSubtreeScansPerBatch: 16
    )

    public init(
        quietPeriod: Duration = .milliseconds(200),
        maxFoldersPerBatch: Int = 512,
        maxSubtreeScansPerBatch: Int = 16
    ) {
        self.quietPeriod = quietPeriod
        self.maxFoldersPerBatch = maxFoldersPerBatch
        self.maxSubtreeScansPerBatch = maxSubtreeScansPerBatch
    }
}

/// Drives the app's screens by consuming an `AsyncStream<ScanEvent>` produced by
/// a `ScanEngine`. Lives on the main actor; every screen reads it directly.
///
/// It tracks two independent things: `phase`, the lifecycle of the scan on the
/// engine's slot, and `route`, the screen the flow is showing. Keeping them
/// apart is what lets the source-selection screen stay up while a scan runs on
/// in the background.
///
/// It talks to `DiskCore` only (the frozen `ScanEngine` protocol + models) and
/// never re-implements scanning. The concrete engine is injected by the app
/// shell during integration; until then `engine` is `nil` and starting a scan
/// fails truthfully rather than fabricating progress.
@MainActor
@Observable
public final class ScanViewModel {

    /// The lifecycle phase of the scan on the engine's slot.
    public enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled
        case failed(String)
    }

    /// Which screen the flow is showing.
    ///
    /// Navigation is tracked separately from `phase` so the source-selection
    /// screen can stay up while a scan keeps running on the engine's slot: leaving
    /// a screen is not a statement about the scan.
    public enum Route: Equatable {
        case home
        case results
    }

    // MARK: State (private(set) — only this type mutates it)

    public private(set) var phase: Phase = .idle
    /// The screen the flow is showing. See `showHome()` / `showResults()`.
    public private(set) var route: Route = .home
    public private(set) var summary: ScanSummary?
    /// The newest non-terminal `.partial` snapshot. Drives progressive (in-flight)
    /// results while a scan runs; the terminal `summary` supersedes it when the scan
    /// finishes or is cancelled.
    public private(set) var partialSummary: ScanSummary?
    /// The root of the scan on the engine's slot — the scan running now, or the
    /// most recent scan whose results are still available. `nil` before the first
    /// scan and after `reset()`.
    public private(set) var currentRoot: URL?
    /// The last start request that was refused because a scan already filled the
    /// engine's single slot. Surfaced by the flow so a refusal is never silent.
    public private(set) var blockedStartNotice: String?
    public private(set) var progress: ScanProgress?
    public private(set) var issues: [ScanIssue] = []
    /// The options the scan on the slot was started with: the record of the
    /// choices that produced the current results. Rescan reads the store rather
    /// than this value, so a changed setting applies to the new run.
    public private(set) var lastOptions = ScanOptions.standard
    /// When the scan on the slot started, for the results line before a snapshot
    /// carries its own timestamps.
    public private(set) var scanStartedAt: Date?
    /// Set when the screen cannot follow a change and the numbers on it are
    /// therefore older than the disk — no live tree, or no watch to feed one.
    /// Cleared as soon as an applied batch brings the tree up to date.
    public private(set) var resultsAreStale = false
    /// Whether a watcher is installed on the scan root.
    public private(set) var isWatching = false
    /// The tree the results screen reads: the scan as a live arena that
    /// filesystem changes are applied to. It arrives while the walk fills it and
    /// is replaced by the handed-over tree when the scan settles; `nil` before a
    /// tree exists and when the engine has none.
    public private(set) var liveTree: LiveTree?
    /// Whether the finished scan is still being turned into a live tree.
    public private(set) var isBuildingLiveTree = false
    /// Whether a batch of filesystem changes is being applied right now.
    public private(set) var isApplyingChanges = false
    /// The outcome of the last trash request, kept until the screen dismisses it
    /// or a new scan starts.
    public private(set) var reclaimNotice: ReclaimNotice?

    /// Moves items to the Trash through the guard, one at a time, and reports
    /// what happened in the screen's words.
    ///
    /// Every request is checked again here even though the confirmation sheet
    /// already showed a decision: the tree can change while the sheet is open,
    /// and the engine's own rule is that no action is taken without a current
    /// answer.
    @discardableResult
    public func reclaim(_ candidates: [ReclaimCandidate]) async -> ReclaimNotice {
        guard let root = currentRoot else {
            let notice = ReclaimNotice(
                tone: .failure,
                message: L10n.string("There is no finished scan to check this item against. Run a scan, then try again."),
                showsShowTrash: false
            )
            reclaimNotice = notice
            return notice
        }

        var moved: [ReclaimCandidate] = []
        var trashedURLs: [URL: URL] = [:]
        var failures: [String] = []

        // A path inside another selected path is covered by that move.
        let byURL = Dictionary(candidates.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let selection = ReclaimSelection.outermost(candidates.map(\.url)).compactMap { byURL[$0] }

        for candidate in selection {
            var context = await ReclaimContextProbe.context(for: candidate.url, scanRoot: root)
            context.isScanning = isScanning
            if let refusal = ReclaimPolicy.refusal(for: candidate.url, in: context) {
                failures.append(L10n.format("%@: %@", candidate.name, refusal.title))
                continue
            }
            switch await reclaimController.trash(candidate.url) {
            case .trashed(let trashedURL):
                moved.append(candidate)
                if let trashedURL { trashedURLs[candidate.url] = trashedURL }
            case .failed(let reason):
                failures.append(L10n.format("%@: %@", candidate.name, reason))
            }
        }

        if !moved.isEmpty, let reclaimLog {
            let move = ReclaimMove(
                date: Date(),
                rootPath: root.standardizedFileURL.path,
                items: moved.map { candidate in
                    ReclaimMove.Item(
                        name: candidate.name,
                        originalPath: candidate.url.standardizedFileURL.path,
                        trashedPath: trashedURLs[candidate.url]?.standardizedFileURL.path,
                        isDirectory: candidate.isDirectory,
                        logicalSize: candidate.logicalSize,
                        allocatedSize: candidate.allocatedSize
                    )
                }
            )
            await reclaimLog.record(move)
        }

        if !moved.isEmpty, liveTree == nil || !isWatching {
            // A watched tree follows the move through the filesystem itself;
            // without one the numbers on screen are now older than the disk.
            markResultsStale()
        }

        let notice = makeReclaimNotice(moved: moved, failures: failures)
        reclaimNotice = notice
        return notice
    }

    /// Puts the items of one logged move back where they came from.
    ///
    /// Each item is checked at the moment of the move: the log says where the
    /// system put it, not where it still is. Items that cannot go back are
    /// reported by name and reason; the ones that can are recorded as restored.
    @discardableResult
    func restore(_ move: ReclaimMove) async -> ReclaimRestoreReport {
        var restored: Set<UUID> = []
        var failures: [String] = []

        for item in move.items where !item.isRestored {
            switch await restorer.restore(item) {
            case .restored:
                restored.insert(item.id)
            case .refused(let refusal):
                failures.append(L10n.format("%@: %@", item.name, refusal.title))
            case .failed(let reason):
                failures.append(L10n.format("%@: %@", item.name, reason))
            }
        }

        if !restored.isEmpty {
            await reclaimLog?.markRestored(moveID: move.id, itemIDs: restored)
        }
        if !restored.isEmpty, liveTree == nil || !isWatching {
            markResultsStale()
        }
        return ReclaimRestoreReport(restoredItemIDs: restored, failures: failures)
    }

    /// The guard's answer for one item, asked before the confirmation sheet
    /// opens so the sheet can explain a refusal instead of offering a dead button.
    public func reclaimRefusal(for url: URL) async -> ReclaimRefusal? {
        guard let root = currentRoot else { return .missing }
        var context = await ReclaimContextProbe.context(for: url, scanRoot: root)
        context.isScanning = isScanning
        return ReclaimPolicy.refusal(for: url, in: context)
    }

    public func dismissReclaimNotice() {
        reclaimNotice = nil
    }

    private func makeReclaimNotice(moved: [ReclaimCandidate], failures: [String]) -> ReclaimNotice {
        let size = ByteFormat.string(moved.reduce(0) { $0 + $1.allocatedSize })
        if moved.isEmpty {
            let reason = failures.first ?? L10n.string("The item is still in place.")
            return ReclaimNotice(
                tone: .failure,
                message: L10n.format("Couldn't move to the Trash. %@", reason),
                showsShowTrash: false
            )
        }

        let movedSubject: String
        if moved.count == 1 {
            movedSubject = L10n.format("“%@” (%@)", moved[0].name, size)
        } else {
            movedSubject = L10n.format("%@ (%@)", CountFormat.items(moved.count), size)
        }

        if failures.isEmpty {
            return ReclaimNotice(
                tone: .success,
                message: L10n.format("Moved %@ to the Trash. Space is freed when you empty the Trash.", movedSubject),
                showsShowTrash: true
            )
        }
        return ReclaimNotice(
            tone: .failure,
            message: L10n.format(
                "Moved %@ to the Trash; %@. %@",
                movedSubject,
                L10n.format("%lld could not be moved", failures.count),
                failures[0]
            ),
            showsShowTrash: true
        )
    }

    /// Bumped whenever the results a screen renders change: a progressive
    /// snapshot the screen takes (see `partialApplicationInterval`), the terminal
    /// summary, or a scan starting over. Screens key derived work — filtering and
    /// ordering a folder's entries — on it, so that work is redone when the data
    /// changes and not on every pass through a body. Progress and issue events
    /// carry no new tree data, so they do not bump it.
    public private(set) var resultsRevision = 0

    private var engine: (any ScanEngine)?
    private let reclaimController: ReclaimController
    /// The same store the source screen and Settings edit, so the sheet and a
    /// Rescan use the choices currently on screen rather than a private copy.
    public let optionsStore: ScanOptionsStore
    /// The shared choice to keep settled results current. Changing it never
    /// edits the results; it only decides whether a change is re-measured.
    public let watchPreferences: WatchPreferences
    private let watcher: (any TreeWatching)?
    private let updatePolicy: LiveUpdatePolicy
    /// Where a finished scan is remembered. `nil` means this process does not
    /// keep history: the app shell supplies one so scans are recorded, while a
    /// test or a preview that drives a scan is not made to write into the user's
    /// history.
    public let history: ScanHistory?
    /// Where this process remembers its own moves, so one can be undone while
    /// the Trash still holds it. `nil` means moves are not remembered: a test or
    /// a preview must not write into the user's log.
    public let reclaimLog: ReclaimLog?
    private let restorer: ReclaimRestorer
    private var scanTask: Task<Void, Never>?
    /// Bumped whenever a scan starts or is discarded, so work belonging to a
    /// superseded scan — a late event, or a cancel that was requested before the
    /// next scan began — can never touch the scan that is running now.
    private var scanGeneration = 0
    /// Bumped whenever the watch starts or stops, so a batch delivered for an
    /// older root cannot mark the results that replaced it.
    private var watchGeneration = 0
    /// The finished scan being turned into a live tree, so a scan that is
    /// replaced or reset never installs its tree over the next one.
    private var liveTreeTask: Task<Void, Never>?
    /// The one writer that applies filesystem changes to the tree.
    private var updater: LiveTreeUpdater?
    /// Folders the watcher reported that have not been reconciled yet.
    private var pendingFolders: Set<String> = []
    /// A batch waiting out the quiet period before it is applied.
    private var pendingUpdate: Task<Void, Never>?
    /// A hard bound on the folders a batch may hold while it waits.
    private static let maxPendingFolders = 4_096

    /// The newest progressive snapshot that has not reached the screen yet.
    private var heldPartial: ScanSummary?
    /// Applies `heldPartial` once the screen's cadence allows it.
    private var heldPartialTask: Task<Void, Never>?
    /// When the screen last took a progressive snapshot.
    private var lastPartialAppliedAt: ContinuousClock.Instant?
    /// Whether the results screen is being scrolled right now.
    ///
    /// Applying a snapshot rebuilds the chart and the list, which lands in the
    /// middle of a scroll. While the screen is moving the newest snapshot is
    /// therefore held, and the screen takes it as soon as the scroll ends.
    private var isResultsScrolling = false

    /// The cadence at which the screen takes progressive snapshots.
    ///
    /// Each `.partial` snapshot is superseded by the next, and a full-disk scan
    /// surfaces them far faster than any screen can usefully redraw — dozens a
    /// second. The newest snapshot is therefore held and applied on this cadence,
    /// so the screen's derived work — the chart's rings, the explorer's rows —
    /// runs at a rate a person can see, while what is on screen is never more
    /// than one step behind the engine.
    ///
    /// A second is deliberate rather than brisk: redrawing the live chart costs a
    /// good part of a frame budget per wedge it draws, so taking snapshots faster
    /// spends the main thread on redraws nobody can read. The first snapshot after
    /// a scan starts still lands at once, and the counters in the strip keep
    /// ticking with the engine's own progress events, so the screen stays alive
    /// between updates.
    private static let partialApplicationInterval: Duration = .seconds(1)

    /// A token that changes for every scan that starts. Views key per-scan work
    /// (the Full Disk Access probe) on it, so that work re-runs for each new
    /// scan and on Rescan rather than once per launch.
    public var scanRun: Int { scanGeneration }

    // MARK: Init

    public init(
        engine: (any ScanEngine)? = nil,
        optionsStore: ScanOptionsStore = .shared,
        history: ScanHistory? = nil,
        watchPreferences: WatchPreferences = .shared,
        watcher: (any TreeWatching)? = nil,
        updatePolicy: LiveUpdatePolicy = .standard,
        reclaimLog: ReclaimLog? = nil
    ) {
        self.engine = engine
        self.reclaimController = ReclaimController()
        self.restorer = ReclaimRestorer()
        self.optionsStore = optionsStore
        self.watchPreferences = watchPreferences
        self.watcher = watcher
        self.updatePolicy = updatePolicy
        self.history = history
        self.reclaimLog = reclaimLog
    }

    /// The trashing seam is injectable so the guard's decision and the system's
    /// Trash operation can be exercised separately, without touching a real Trash.
    init(
        engine: (any ScanEngine)? = nil,
        reclaimController: ReclaimController,
        optionsStore: ScanOptionsStore = .shared,
        history: ScanHistory? = nil,
        watchPreferences: WatchPreferences = .shared,
        watcher: (any TreeWatching)? = nil,
        updatePolicy: LiveUpdatePolicy = .standard,
        reclaimLog: ReclaimLog? = nil,
        restorer: ReclaimRestorer = ReclaimRestorer()
    ) {
        self.engine = engine
        self.reclaimController = reclaimController
        self.restorer = restorer
        self.optionsStore = optionsStore
        self.watchPreferences = watchPreferences
        self.watcher = watcher
        self.updatePolicy = updatePolicy
        self.history = history
        self.reclaimLog = reclaimLog
    }

    /// Connects (or replaces) the scanning engine. Called by the app shell once
    /// the scan engine is available.
    public func setEngine(_ engine: any ScanEngine) {
        self.engine = engine
    }

    // MARK: Derived accessors (observed through the stored properties)

    public var isScanning: Bool { phase == .scanning }
    public var hasResults: Bool { summary != nil }

    /// Whether the user has asked the screen to keep itself current.
    public var isWatchingEnabled: Bool { watchPreferences.keepsResultsCurrent }

    /// Whether a batch of filesystem changes is being applied to the tree.
    public var isUpdating: Bool { isApplyingChanges }

    /// Whether the visible results come from a scan that stopped before it had
    /// covered the whole root, so the totals on screen are only part of it.
    public var stoppedEarly: Bool {
        if case .cancelled = phase { return true }
        return false
    }

    /// The results to render right now.
    ///
    /// While a scan runs this is the newest non-terminal `.partial` snapshot, so
    /// the results screen fills in as work completes; once the scan settles
    /// (`.finished` or `.cancelled`) it is the terminal `summary`, which
    /// supersedes every snapshot. `nil` only before a running scan's first
    /// snapshot (and after a cancel that produced none).
    public var liveSummary: ScanSummary? { summary ?? partialSummary }

    public var filesScanned: Int { progress?.filesScanned ?? liveTree?.fileCount ?? summary?.fileCount ?? 0 }
    public var directoriesScanned: Int { progress?.directoriesScanned ?? liveTree?.directoryCount ?? summary?.directoryCount ?? 0 }
    public var bytesScanned: Int64 { progress?.bytesScanned ?? liveTree?.totalLogicalSize ?? summary?.totalLogicalSize ?? 0 }
    public var elapsed: TimeInterval { progress?.elapsed ?? 0 }

    /// Total size to display: the engine's counted bytes while a scan runs, then
    /// the live tree, and the finished summary before a tree exists.
    public var displayedTotal: Int64 {
        progress != nil ? bytesScanned : (liveTree?.totalLogicalSize ?? summary?.totalLogicalSize ?? bytesScanned)
    }

    /// The tree's entries for a folder, as the frozen nodes the screens draw.
    ///
    /// `nil` before the tree exists, so a screen can keep showing the summary
    /// while a full disk is being turned into one.
    public func liveChildren(atPath path: String) -> [ScanNode]? {
        guard let tree = liveTree, let id = tree.id(atPath: path) else { return nil }
        return tree.scanNodes(forChildrenOf: id)
    }

    /// The tree's node at a path, or `nil` before the tree exists.
    public func liveNode(atPath path: String) -> ScanNode? {
        liveTree?.scanNode(atPath: path)
    }

    /// The bounded, classified view of this scan's issues for the UI.
    ///
    /// Reads the truthful totals from `ScanSummary` (`errorCount`,
    /// `surfacedIssueCount`, `permissionDeniedCount`) rather than `issues.count`,
    /// so screens render one access notice with a capped list — the first 50,
    /// then "N more not listed".
    public var issuesPresentation: ScanIssuesPresentation {
        ScanIssuesPresentation(issues: issues, summary: summary)
    }

    /// The Home row's view of the location that occupies the engine's scan slot.
    ///
    /// `nil` when `url` is not that location, and when the scan on the slot has no
    /// results to open: a row never offers a View that leads nowhere.
    public func scanSlot(for url: URL) -> ScanSlotPresentation? {
        guard let root = currentRoot,
              root.standardizedFileURL == url.standardizedFileURL else { return nil }

        switch phase {
        case .scanning:
            return ScanSlotPresentation(
                root: root,
                state: .scanning,
                filesScanned: filesScanned,
                bytesScanned: bytesScanned,
                fraction: progress?.fractionCompleted
            )
        case .finished:
            guard let summary else { return nil }
            // The tree's numbers once it exists: the slot describes the results
            // on screen, which keep moving after the scan settles.
            return ScanSlotPresentation(
                root: root,
                state: .finished,
                filesScanned: liveTree?.fileCount ?? summary.fileCount,
                bytesScanned: liveTree?.totalLogicalSize ?? summary.totalLogicalSize,
                fraction: nil
            )
        case .cancelled:
            guard let summary else { return nil }
            return ScanSlotPresentation(
                root: root,
                state: .stopped,
                filesScanned: summary.fileCount,
                bytesScanned: summary.totalLogicalSize,
                fraction: nil
            )
        case .idle, .failed:
            return nil
        }
    }

    // MARK: Navigation

    /// Shows the results screen for the scan on the slot.
    public func showResults() {
        route = .results
        updateWatching()
    }

    /// Shows the source-selection screen without touching the scan: a scan already
    /// running keeps running in the background, and its results stay available.
    public func showHome() {
        route = .home
        cancelPendingUpdate()
        stopWatching()
    }

    /// Clears the refusal notice once the user has read it.
    public func dismissBlockedStartNotice() {
        blockedStartNotice = nil
    }

    // MARK: Scanning

    public func start(root: URL, options: ScanOptions = .standard) {
        // The engine has one scan slot. Refusing a second start keeps one scan
        // running at a time instead of racing or replacing it; the source
        // selection screen disables its own start actions for the same reason,
        // and this is the guard for the paths that go around them.
        guard !isScanning else {
            blockedStartNotice = L10n.string("A scan is already running. Stop it, or wait for it to finish, before starting another.")
            return
        }

        route = .results
        blockedStartNotice = nil

        guard let engine else {
            phase = .failed(L10n.string("The scanning engine is not connected yet."))
            return
        }

        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        discardHeldPartial()
        lastPartialAppliedAt = nil
        Self.retire(summary)
        summary = nil
        Self.retire(partialSummary)
        partialSummary = nil
        progress = nil
        issues = []
        currentRoot = root
        lastOptions = options
        scanStartedAt = .now
        resultsAreStale = false
        reclaimNotice = nil
        discardLiveTree()
        stopWatching()
        phase = .scanning
        resultsRevision &+= 1

        let request = ScanRequest(
            root: root,
            followSymlinks: options.followSymlinks,
            stayOnVolume: options.stayOnVolume,
            includeHidden: options.includeHidden,
            excludedPaths: options.excludedPaths
        )
        // An engine that fills a tree as it walks hands it over with the
        // terminal event; anything else leaves the tree to be built from the
        // summary afterwards.
        let liveEngine = engine as? any LiveTreeScanning
        let stream = liveEngine?.scan(request, buildingLiveTree: true) ?? engine.scan(request)
        scanTask = Task { [weak self] in
            await self?.consume(stream, generation: generation, liveEngine: liveEngine)
        }
    }

    /// Scans the location on the slot again, with the options currently stored
    /// for the next scan.
    ///
    /// Rescan is a new request, so it uses the same values the source screen and
    /// Settings show now. The results already on screen stay untouched until the
    /// new scan replaces them.
    public func rescan() {
        guard let root = currentRoot else { return }
        start(root: root, options: optionsStore.options)
    }

    /// Marks the results on the slot as older than the disk.
    ///
    /// Used when the screen has no way to follow a change — no live tree, or the
    /// watch switched off — so the numbers it shows are older than the disk and
    /// Rescan is the way to catch up.
    public func markResultsStale() {
        resultsAreStale = true
    }

    /// Asks the running scan to stop. Cancelling is a request, not an outcome:
    /// the engine reports the outcome with `.cancelled`, and until it does the
    /// results gathered so far stay on screen.
    public func cancel() {
        guard isScanning else { return }
        let engine = self.engine
        let generation = scanGeneration
        Task { [weak self] in
            // The engine keeps one scan slot, so a cancel that lands after a new
            // scan has started would stop the wrong scan; that cancel belonged to
            // a scan that has already been replaced.
            guard let self, self.scanGeneration == generation else { return }
            await engine?.cancel()
        }
    }

    public func reset() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        discardHeldPartial()
        lastPartialAppliedAt = nil
        Self.retire(summary)
        summary = nil
        Self.retire(partialSummary)
        partialSummary = nil
        progress = nil
        issues = []
        currentRoot = nil
        scanStartedAt = nil
        resultsAreStale = false
        reclaimNotice = nil
        blockedStartNotice = nil
        discardLiveTree()
        stopWatching()
        isResultsScrolling = false
        phase = .idle
        route = .home
        resultsRevision &+= 1
    }

    // MARK: - Watching the scanned tree

    /// The preference changed while results are on screen.
    public func watchPreferenceChanged() {
        updateWatching()
    }

    /// Matches the watch to what is on screen: settled results, on the results
    /// route, with the preference on. Anything else means no stream is open.
    ///
    /// A run's length does not decide whether it is watched: a change is applied
    /// to the live tree where it happened, so a whole-disk scan is kept current
    /// as cheaply as a home folder.
    private func updateWatching() {
        let shouldWatch = watcher != nil
            && watchPreferences.keepsResultsCurrent
            && route == .results
            && phase == .finished
            && summary != nil
        guard shouldWatch != isWatching else { return }
        if shouldWatch {
            startWatching()
        } else {
            cancelPendingUpdate()
            stopWatching()
        }
    }

    private func startWatching() {
        guard let watcher, let root = currentRoot else { return }
        watchGeneration &+= 1
        let generation = watchGeneration
        do {
            try watcher.start(
                root: root,
                // The options the scan on the slot ran with, not the store: the
                // tree the summary describes was measured with these.
                excludedPaths: lastOptions.excludedPaths,
                stayOnVolume: lastOptions.stayOnVolume
            ) { [weak self] change in
                Task { @MainActor in
                    self?.receive(change, watchGeneration: generation)
                }
            }
            isWatching = true
        } catch {
            isWatching = false
        }
    }

    private func stopWatching() {
        watchGeneration &+= 1
        isWatching = false
        watcher?.stop()
    }

    private func cancelPendingUpdate() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        pendingFolders.removeAll()
    }

    /// One batch from the watcher, already filtered to the scan's own tree.
    ///
    /// The folders are collected, not reconciled one by one: a Finder action
    /// arrives as a burst, and the tree is edited once for the whole of it.
    private func receive(_ change: ScanTreeChange, watchGeneration generation: Int) {
        guard generation == watchGeneration, isWatching, phase == .finished else { return }

        if change.rootMissing {
            cancelPendingUpdate()
            stopWatching()
            markResultsStale()
            return
        }
        guard !change.isEmpty else { return }

        for folder in change.folders where pendingFolders.count < Self.maxPendingFolders {
            pendingFolders.insert(folder.path)
        }

        guard liveTree != nil else {
            // The tree is still being built for this scan; the same folders are
            // applied the moment it exists. Without one the screen keeps the
            // scan's own measurement and says it is older than the disk.
            if !isBuildingLiveTree { markResultsStale() }
            return
        }
        scheduleUpdate()
    }

    /// Waits out the quiet period, then applies everything collected.
    ///
    /// One pass runs at a time: while a pass is in flight new folders collect, and
    /// the pass that is finishing drains them, so a long measurement never has a
    /// second pass scheduled behind it.
    private func scheduleUpdate() {
        guard updater != nil, liveTree != nil, phase == .finished, !isScanning,
              !isApplyingChanges else { return }

        pendingUpdate?.cancel()
        let delay = updatePolicy.quietPeriod
        let generation = scanGeneration
        pendingUpdate = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            await self.applyPendingChanges()
        }
    }

    private func applyPendingChanges() async {
        pendingUpdate = nil
        // The pass in flight drains whatever arrived during it, so a task that
        // wakes up mid-pass has nothing of its own to do.
        guard !isApplyingChanges,
              let updater, liveTree != nil, phase == .finished, !pendingFolders.isEmpty else { return }

        let folders = Array(pendingFolders.prefix(Self.maxPendingFolders))
        pendingFolders.subtract(folders)
        let generation = scanGeneration
        isApplyingChanges = true
        let batch = await updater.apply(changedFolders: folders)
        isApplyingChanges = false

        guard generation == scanGeneration, liveTree != nil else { return }
        if batch.changed {
            resultsAreStale = false
            resultsRevision &+= 1
        }
        for folder in batch.deferred where pendingFolders.count < Self.maxPendingFolders {
            pendingFolders.insert(folder)
        }
        // Folders that arrived during the pass, and the ones it deferred, are the
        // next pass's work.
        if !pendingFolders.isEmpty { scheduleUpdate() }
    }

    // MARK: - The live tree

    /// Turns a finished scan into the tree the screen edits.
    ///
    /// Building it walks the whole measured tree, which is seconds on a full disk,
    /// so it happens off the main actor: the screen keeps showing the summary in
    /// the meantime and switches to the tree when it lands. A tree that disagrees
    /// with the scan it came from is refused by `LiveTree(scanning:)`; the screen
    /// then stays on the summary and says when it is out of date.
    private func prepareLiveTree(for summary: ScanSummary) {
        liveTreeTask?.cancel()
        cancelPendingUpdate()
        Self.retire(liveTree)
        liveTree = nil
        updater = nil
        isBuildingLiveTree = true
        resultsRevision &+= 1

        let generation = scanGeneration
        let policy = liveTreePolicy(root: summary.root)
        liveTreeTask = Task { [weak self] in
            let tree = await Task.detached(priority: .userInitiated) {
                LiveTree(scanning: summary)
            }.value
            guard !Task.isCancelled, let self, self.scanGeneration == generation else {
                // The scan this tree describes was replaced while it was being
                // built; free it where freeing it cannot stall the window.
                Self.retire(tree)
                return
            }
            self.install(tree: tree, policy: policy)
        }
    }

    /// The rules of the scan on the slot, for the tree that keeps applying them.
    private func liveTreePolicy(root: URL) -> LiveTreePolicy {
        LiveTreePolicy(ScanRequest(
            root: root,
            followSymlinks: lastOptions.followSymlinks,
            stayOnVolume: lastOptions.stayOnVolume,
            includeHidden: lastOptions.includeHidden,
            excludedPaths: lastOptions.excludedPaths
        ))
    }

    private func install(tree: LiveTree?, policy: LiveTreePolicy) {
        isBuildingLiveTree = false
        liveTree = tree
        updater = tree.map {
            LiveTreeUpdater(
                tree: $0,
                policy: policy,
                maxFoldersPerBatch: updatePolicy.maxFoldersPerBatch,
                maxSubtreeScansPerBatch: updatePolicy.maxSubtreeScansPerBatch
            )
        }
        resultsRevision &+= 1
        // A scan that could not become a tree is not stale by itself; the next
        // change it cannot follow is what marks the screen.
        guard tree != nil else { return }
        // Folders reported while the tree was being built are reconciled now.
        if !pendingFolders.isEmpty { scheduleUpdate() }
    }

    /// Takes the tree the running walk has started filling, once it exists.
    ///
    /// The engine creates the tree before its first snapshot and keeps filling it
    /// as the scan runs, so the screen reads measured entries while they arrive.
    /// An engine that only reports summaries has none, and the tree is built from
    /// the finished summary instead.
    private func adoptInProgressTree(_ engine: (any LiveTreeScanning)?) async {
        guard let engine, liveTree == nil, phase == .scanning, let root = currentRoot else { return }
        guard let tree = await engine.liveTreeInProgress() else { return }
        install(tree: tree, policy: liveTreePolicy(root: root))
    }

    private func discardLiveTree() {
        liveTreeTask?.cancel()
        liveTreeTask = nil
        cancelPendingUpdate()
        // Drop the engine's reference too: the tree this screen is letting go of
        // should not stay alive in the engine until the next scan.
        (engine as? any LiveTreeScanning)?.clearLiveTree()
        Self.retire(liveTree)
        liveTree = nil
        updater = nil
        isBuildingLiveTree = false
        isApplyingChanges = false
    }

    // MARK: - Event consumption

    private func consume(
        _ stream: AsyncStream<ScanEvent>,
        generation: Int,
        liveEngine: (any LiveTreeScanning)? = nil
    ) async {
        for await event in stream {
            guard generation == scanGeneration else { return }
            switch event {
            case .started(let root):
                currentRoot = root
                await adoptInProgressTree(liveEngine)
            case .progress(let p):
                await adoptInProgressTree(liveEngine)
                progress = p
            case .issue(let kind, let path, let message):
                issues.append(ScanIssue(path: path, message: message, kind: kind))
            case .partial(let snapshot):
                await adoptInProgressTree(liveEngine)
                hold(snapshot, generation: generation)
            case .finished(let s):
                discardHeldPartial()
                summary = s
                Self.retire(partialSummary)
                partialSummary = nil
                progress = nil
                phase = .finished
                resultsAreStale = false
                resultsRevision &+= 1
                recordHistory(s)
                if let tree = await liveEngine?.takeLiveTree() {
                    // The walk built the tree; nothing here converts the summary.
                    install(tree: tree, policy: liveTreePolicy(root: s.root))
                } else if liveTree == nil {
                    // No tree was handed over; an engine that only reports
                    // summaries still gets one built from the finished summary.
                    prepareLiveTree(for: s)
                }
                updateWatching()
            case .cancelled(let partial):
                discardHeldPartial()
                if liveTree == nil { await adoptInProgressTree(liveEngine) }
                if let partial { summary = partial }
                Self.retire(partialSummary)
                partialSummary = nil
                progress = nil
                phase = .cancelled
                resultsRevision &+= 1
                if summary == nil { route = .home }
                // The tree the walk had filled stays as a partial, read-only
                // surface; it is not settled and is never watched. The engine no
                // longer needs its own reference.
                liveEngine?.clearLiveTree()
                updateWatching()
            }
        }

        // The contract promises exactly one terminal event. If the stream ends
        // without one the scan is over either way, so the screen settles on what
        // it has instead of reporting a scan that is no longer running.
        guard generation == scanGeneration, phase == .scanning else { return }
        if liveTree == nil { await adoptInProgressTree(liveEngine) }
        // A snapshot the cadence was still holding is the newest the engine
        // produced, so it is what the screen settles on.
        if let held = heldPartial {
            Self.retire(partialSummary)
            partialSummary = held
        }
        discardHeldPartial()
        summary = partialSummary
        partialSummary = nil
        progress = nil
        phase = .cancelled
        resultsRevision &+= 1
        liveEngine?.clearLiveTree()
        if summary == nil { route = .home }
    }

    // MARK: - History

    /// Remembers a finished scan without holding up the results.
    ///
    /// The record is built from the summary already in hand and written off the
    /// main actor, so the screen settles at once and the history list catches up
    /// when the write lands. `lastOptions` is read now, while it still describes
    /// the scan that just finished.
    private func recordHistory(_ summary: ScanSummary) {
        guard let history else { return }
        let options = lastOptions
        Task { await history.record(summary, options: options) }
    }

    // MARK: - Progressive rendering

    /// Holds a progressive snapshot until the screen's cadence allows it.
    ///
    /// The first snapshot after a scan starts, or after the cadence has passed,
    /// reaches the screen at once, so results fill in the moment there is
    /// something to show. A snapshot arriving inside the cadence waits out the
    /// remainder of it, and the newest snapshot is the one that counts: the ones
    /// it replaces were only ever an earlier reading of the same scan.
    private func hold(_ snapshot: ScanSummary, generation: Int) {
        Self.retire(heldPartial)
        heldPartial = snapshot
        // The screen is moving: the newest snapshot waits for it to stop rather
        // than landing in the middle of the scroll.
        guard !isResultsScrolling else { return }
        guard heldPartialTask == nil else { return }

        let clock = ContinuousClock()
        let wait: Duration
        if let last = lastPartialAppliedAt {
            wait = max(.zero, clock.now.duration(to: last.advanced(by: Self.partialApplicationInterval)))
        } else {
            wait = .zero
        }

        heldPartialTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            self.applyHeldPartial()
        }
    }

    /// Reports the results list's scroll activity.
    ///
    /// A snapshot is taken at most once a second, but each one redraws the chart
    /// and rebuilds the explorer's rows: work worth deferring while the user is
    /// moving the list, and taking the moment the movement stops.
    public func setResultsScrolling(_ scrolling: Bool) {
        guard scrolling != isResultsScrolling else { return }
        isResultsScrolling = scrolling
        guard scrolling else {
            applyHeldPartial()
            return
        }
        // A snapshot the cadence was about to take would stall the scroll; keep
        // the newest one waiting instead.
        heldPartialTask?.cancel()
        heldPartialTask = nil
    }

    /// Gives the newest held snapshot to the screens, and starts the next cadence.
    private func applyHeldPartial() {
        heldPartialTask = nil
        guard let snapshot = heldPartial else { return }
        heldPartial = nil
        lastPartialAppliedAt = ContinuousClock().now
        Self.retire(partialSummary)
        partialSummary = snapshot
        resultsRevision &+= 1
    }

    /// Drops a held snapshot: the state it describes is superseded, or belongs to
    /// a scan that is no longer the one on the engine's slot.
    private func discardHeldPartial() {
        heldPartialTask?.cancel()
        heldPartialTask = nil
        Self.retire(heldPartial)
        heldPartial = nil
    }

    // MARK: - Releasing a replaced measurement

    /// Frees a measurement the screen no longer shows away from the main actor.
    ///
    /// A summary from a producer that reports summaries only carries the scanned
    /// root's whole tree as nested `ScanNode` values, and a live tree's arena is
    /// large too; freeing either walks every entry the scan measured. On the main
    /// actor that walk is a visible pause wherever a scan is replaced — starting
    /// the next scan would land it on the click. The value is kept alive by a
    /// detached task and released when that task ends.
    private nonisolated static func retire<T: Sendable>(_ value: T?) {
        guard let value else { return }
        _ = Task.detached(priority: .utility) {
            withExtendedLifetime(value) {}
        }
    }
}
