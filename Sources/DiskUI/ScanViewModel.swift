import Foundation
import Observation
import DiskCore

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

/// How a settled screen decides to re-measure itself after a Finder change.
public struct RefreshPolicy: Sendable, Equatable {
    /// How long the root must stay quiet before an automatic refresh starts.
    public var quietPeriod: Duration
    /// The shortest gap between the end of one automatic refresh and the start
    /// of the next.
    public var cooldown: Duration
    /// A scan that took longer than this is offered a Rescan instead of being
    /// repeated automatically; the screen keeps the last honest measurement.
    public var budget: TimeInterval

    public static let standard = RefreshPolicy(
        quietPeriod: .milliseconds(750),
        cooldown: .seconds(5),
        budget: 10
    )

    public init(
        quietPeriod: Duration = .milliseconds(750),
        cooldown: Duration = .seconds(5),
        budget: TimeInterval = 10
    ) {
        self.quietPeriod = quietPeriod
        self.cooldown = cooldown
        self.budget = budget
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
    /// Set when something outside the engine changed the tree the summary
    /// describes — moving an item to the Trash — so the screen can say the
    /// numbers are older than the disk instead of presenting them as current.
    /// Cleared when a scan starts over the same slot.
    public private(set) var resultsAreStale = false
    /// The folders the watcher reported changed since the results settled.
    /// Bounded to what a badge can name; `changedFolderCount` counts the rest.
    public private(set) var changedFolders: [URL] = []
    public private(set) var changedFolderCount = 0
    /// A batch named more folders than the badge keeps. The count is then a
    /// lower bound and the screen says so rather than inventing the rest.
    public private(set) var changedFoldersWereTruncated = false
    /// Whether a watcher is installed on the scan root.
    public private(set) var isWatching = false
    /// Whether the results on screen are being re-measured in place. The old
    /// summary stays visible until the new one lands.
    public private(set) var isRefreshing = false
    /// Whether a change is waiting out the quiet period before a refresh.
    public private(set) var isRefreshPending = false
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
                message: "There is no finished scan to check this item against. Run a scan, then try again.",
                showsShowTrash: false
            )
            reclaimNotice = notice
            return notice
        }

        var moved: [ReclaimCandidate] = []
        var failures: [String] = []

        isReclaiming = true
        changeDuringReclaim = false

        for candidate in candidates {
            var context = await ReclaimContextProbe.context(for: candidate.url, scanRoot: root)
            context.isScanning = isScanning
            if let refusal = ReclaimPolicy.refusal(for: candidate.url, in: context) {
                failures.append("\(candidate.name): \(refusal.title)")
                continue
            }
            switch await reclaimController.trash(candidate.url) {
            case .trashed:
                moved.append(candidate)
            case .failed(let reason):
                failures.append("\(candidate.name): \(reason)")
            }
        }

        if !moved.isEmpty {
            markResultsStale()
        }

        isReclaiming = false
        if changeDuringReclaim {
            changeDuringReclaim = false
            scheduleRefresh()
        }

        let notice = makeReclaimNotice(moved: moved, failures: failures)
        reclaimNotice = notice
        return notice
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
            let reason = failures.first ?? "The item is still in place."
            return ReclaimNotice(
                tone: .failure,
                message: "Couldn’t move to the Trash. \(reason)",
                showsShowTrash: false
            )
        }

        let movedSubject: String
        if moved.count == 1 {
            movedSubject = "“\(moved[0].name)” (\(size))"
        } else {
            movedSubject = "\(moved.count) items (\(size))"
        }

        if failures.isEmpty {
            return ReclaimNotice(
                tone: .success,
                message: "Moved \(movedSubject) to the Trash. Space is freed when you empty the Trash.",
                showsShowTrash: true
            )
        }
        return ReclaimNotice(
            tone: .failure,
            message: "Moved \(movedSubject) to the Trash; \(failures.count) could not be moved. \(failures[0])",
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
    private let refreshPolicy: RefreshPolicy
    /// Where a finished scan is remembered. `nil` means this process does not
    /// keep history: the app shell supplies one so scans are recorded, while a
    /// test or a preview that drives a scan is not made to write into the user's
    /// history.
    public let history: ScanHistory?
    private var scanTask: Task<Void, Never>?
    /// Bumped whenever a scan starts or is discarded, so work belonging to a
    /// superseded scan — a late event, or a cancel that was requested before the
    /// next scan began — can never touch the scan that is running now.
    private var scanGeneration = 0
    /// Bumped whenever the watch starts or stops, so a batch delivered for an
    /// older root cannot mark the results that replaced it.
    private var watchGeneration = 0
    /// A refresh waiting out its quiet period (and, if needed, the cooldown).
    private var pendingRefresh: Task<Void, Never>?
    /// When the last automatic refresh finished, for the cooldown.
    private var lastAutomaticRefreshAt: ContinuousClock.Instant?
    /// Whether a trash request is moving items right now, so a refresh never
    /// measures the tree halfway through the batch.
    private var isReclaiming = false
    private var changeDuringReclaim = false
    /// Every folder the current stale state is about, for counting without
    /// growing the badge's list without bound.
    private var changedFolderPaths: Set<String> = []

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
        refreshPolicy: RefreshPolicy = .standard
    ) {
        self.engine = engine
        self.reclaimController = ReclaimController()
        self.optionsStore = optionsStore
        self.watchPreferences = watchPreferences
        self.watcher = watcher
        self.refreshPolicy = refreshPolicy
        self.history = history
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
        refreshPolicy: RefreshPolicy = .standard
    ) {
        self.engine = engine
        self.reclaimController = reclaimController
        self.optionsStore = optionsStore
        self.watchPreferences = watchPreferences
        self.watcher = watcher
        self.refreshPolicy = refreshPolicy
        self.history = history
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

    /// Whether an automatic update is waiting out its quiet period or running.
    public var isUpdating: Bool { isRefreshing || isRefreshPending }

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

    public var filesScanned: Int { progress?.filesScanned ?? summary?.fileCount ?? 0 }
    public var directoriesScanned: Int { progress?.directoriesScanned ?? summary?.directoryCount ?? 0 }
    public var bytesScanned: Int64 { progress?.bytesScanned ?? summary?.totalLogicalSize ?? 0 }
    public var elapsed: TimeInterval { progress?.elapsed ?? 0 }

    /// Total size to display — the finished total when done, else bytes so far.
    public var displayedTotal: Int64 { summary?.totalLogicalSize ?? bytesScanned }

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
            return ScanSlotPresentation(
                root: root,
                state: .finished,
                filesScanned: summary.fileCount,
                bytesScanned: summary.totalLogicalSize,
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
        cancelPendingRefresh()
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
            blockedStartNotice = "A scan is already running. Stop it, or wait for it to finish, before starting another."
            return
        }

        route = .results
        blockedStartNotice = nil

        guard let engine else {
            phase = .failed("The scanning engine is not connected yet.")
            return
        }

        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        discardHeldPartial()
        lastPartialAppliedAt = nil
        summary = nil
        partialSummary = nil
        progress = nil
        issues = []
        currentRoot = root
        lastOptions = options
        scanStartedAt = .now
        resultsAreStale = false
        reclaimNotice = nil
        changedFolders = []
        changedFolderCount = 0
        changedFoldersWereTruncated = false
        changedFolderPaths = []
        isRefreshing = false
        isRefreshPending = false
        lastAutomaticRefreshAt = nil
        cancelPendingRefresh()
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
        let stream = engine.scan(request)
        scanTask = Task { [weak self] in
            await self?.consume(stream, generation: generation)
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
    /// Used after an item is moved to the Trash. The tree the summary describes is
    /// no longer what the engine measured, and rescanning a whole disk for one
    /// removal would be worse than saying so: the screen keeps the last honest
    /// totals, labels them stale, and offers Rescan.
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
        summary = nil
        partialSummary = nil
        progress = nil
        issues = []
        currentRoot = nil
        scanStartedAt = nil
        resultsAreStale = false
        reclaimNotice = nil
        blockedStartNotice = nil
        changedFolders = []
        changedFolderCount = 0
        changedFoldersWereTruncated = false
        changedFolderPaths = []
        isRefreshing = false
        isRefreshPending = false
        lastAutomaticRefreshAt = nil
        cancelPendingRefresh()
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
            cancelPendingRefresh()
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

    private func cancelPendingRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        isRefreshPending = false
    }

    /// One batch from the watcher, already filtered to the scan's own tree.
    private func receive(_ change: ScanTreeChange, watchGeneration generation: Int) {
        guard generation == watchGeneration, isWatching, phase == .finished else { return }

        if change.rootMissing {
            record(change)
            cancelPendingRefresh()
            stopWatching()
            markResultsStale()
            return
        }
        guard !change.isEmpty else { return }

        record(change)
        markResultsStale()

        // Moving items changes the tree too; measuring it halfway through the
        // batch would be a reading of neither state.
        if isReclaiming {
            changeDuringReclaim = true
            return
        }
        scheduleRefresh()
    }

    private func record(_ change: ScanTreeChange) {
        for folder in change.folders {
            guard changedFolderPaths.insert(folder.path).inserted else { continue }
            changedFolderCount += 1
            if changedFolders.count < ScanWatchScope.maxReportedFolders {
                changedFolders.append(folder)
            }
        }
        if change.folderCount > change.folders.count {
            changedFoldersWereTruncated = true
        }
    }

    /// Waits out the quiet period — and the cooldown, if one is still running —
    /// then re-measures the root.
    private func scheduleRefresh() {
        guard !isScanning, !isRefreshing, !isReclaiming else { return }
        guard canRefreshAutomatically else { return }

        pendingRefresh?.cancel()
        isRefreshPending = true

        let delay = max(refreshPolicy.quietPeriod, cooldownRemaining)
        let generation = scanGeneration
        pendingRefresh = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            self.beginRefresh()
        }
    }

    /// A run that took longer than the budget is not repeated behind the user's
    /// back; the screen says it is stale and offers Rescan instead.
    private var canRefreshAutomatically: Bool {
        guard let summary else { return false }
        return summary.finishedAt.timeIntervalSince(summary.startedAt) <= refreshPolicy.budget
    }

    private var cooldownRemaining: Duration {
        guard let lastAutomaticRefreshAt else { return .zero }
        let ready = lastAutomaticRefreshAt.advanced(by: refreshPolicy.cooldown)
        return max(.zero, ContinuousClock().now.duration(to: ready))
    }

    /// Re-measures the root without clearing what is on screen.
    ///
    /// This is the one place a scan begins without discarding the previous
    /// results: no snapshot, no progress, and no issue from the new walk reaches
    /// the screen, and the old summary is replaced only by the new terminal one.
    /// The request is the one the visible results came from, so a change cannot
    /// silently narrow or widen what the numbers mean.
    private func beginRefresh() {
        pendingRefresh = nil
        isRefreshPending = false

        guard !isScanning, !isRefreshing, !isReclaiming,
              watchPreferences.keepsResultsCurrent,
              phase == .finished, route == .results,
              let root = currentRoot, let engine,
              canRefreshAutomatically else {
            updateWatching()
            return
        }

        stopWatching()
        isRefreshing = true
        phase = .scanning
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        discardHeldPartial()
        lastPartialAppliedAt = nil

        let request = ScanRequest(
            root: root,
            followSymlinks: lastOptions.followSymlinks,
            stayOnVolume: lastOptions.stayOnVolume,
            includeHidden: lastOptions.includeHidden,
            excludedPaths: lastOptions.excludedPaths
        )
        let stream = engine.scan(request)
        scanTask = Task { [weak self] in
            await self?.consume(stream, generation: generation)
        }
    }

    // MARK: - Event consumption

    private func consume(_ stream: AsyncStream<ScanEvent>, generation: Int) async {
        for await event in stream {
            guard generation == scanGeneration else { return }
            switch event {
            case .started(let root):
                currentRoot = root
            case .progress(let p):
                // A refresh measures in place: its counters describe a walk the
                // screen is not showing, so they never reach it.
                guard !isRefreshing else { break }
                progress = p
            case .issue(let kind, let path, let message):
                guard !isRefreshing else { break }
                issues.append(ScanIssue(path: path, message: message, kind: kind))
            case .partial(let snapshot):
                guard !isRefreshing else { break }
                hold(snapshot, generation: generation)
            case .finished(let s):
                let wasRefresh = isRefreshing
                discardHeldPartial()
                summary = s
                partialSummary = nil
                progress = nil
                phase = .finished
                resultsAreStale = false
                changedFolders = []
                changedFolderCount = 0
                changedFoldersWereTruncated = false
                changedFolderPaths = []
                isRefreshing = false
                isRefreshPending = false
                pendingRefresh = nil
                resultsRevision &+= 1
                // A refresh keeps the screen current; it is not a run the user
                // asked to compare, so History stays the record of those.
                if wasRefresh {
                    // The cooldown runs from the end of the work so two long
                    // refreshes cannot follow one another back to back.
                    lastAutomaticRefreshAt = ContinuousClock().now
                } else {
                    recordHistory(s)
                }
                updateWatching()
            case .cancelled(let partial):
                let wasRefresh = isRefreshing
                discardHeldPartial()
                if wasRefresh {
                    // The complete older measurement is still the best answer on
                    // screen; only its age is new. A stopped update is a decision
                    // the watcher should not immediately undo.
                    phase = .finished
                    isRefreshing = false
                    isRefreshPending = false
                    pendingRefresh = nil
                    resultsAreStale = true
                    stopWatching()
                } else {
                    if let partial { summary = partial }
                    partialSummary = nil
                    progress = nil
                    phase = .cancelled
                    resultsRevision &+= 1
                    if summary == nil { route = .home }
                    updateWatching()
                }
            }
        }

        // The contract promises exactly one terminal event. If the stream ends
        // without one the scan is over either way, so the screen settles on what
        // it has instead of reporting a scan that is no longer running.
        guard generation == scanGeneration, phase == .scanning else { return }
        if isRefreshing {
            // The refresh never produced a terminal event, so what is on screen
            // is still the complete measurement it started from.
            phase = .finished
            isRefreshing = false
            isRefreshPending = false
            pendingRefresh = nil
            resultsAreStale = true
            stopWatching()
            return
        }
        // A snapshot the cadence was still holding is the newest the engine
        // produced, so it is what the screen settles on.
        if let held = heldPartial { partialSummary = held }
        discardHeldPartial()
        summary = partialSummary
        partialSummary = nil
        progress = nil
        phase = .cancelled
        resultsRevision &+= 1
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
        partialSummary = snapshot
        resultsRevision &+= 1
    }

    /// Drops a held snapshot: the state it describes is superseded, or belongs to
    /// a scan that is no longer the one on the engine's slot.
    private func discardHeldPartial() {
        heldPartialTask?.cancel()
        heldPartialTask = nil
        heldPartial = nil
    }
}
