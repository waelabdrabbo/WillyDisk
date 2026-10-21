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
    private var scanTask: Task<Void, Never>?
    /// Bumped whenever a scan starts or is discarded, so work belonging to a
    /// superseded scan — a late event, or a cancel that was requested before the
    /// next scan began — can never touch the scan that is running now.
    private var scanGeneration = 0

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
        optionsStore: ScanOptionsStore = .shared
    ) {
        self.engine = engine
        self.reclaimController = ReclaimController()
        self.optionsStore = optionsStore
    }

    /// The trashing seam is injectable so the guard's decision and the system's
    /// Trash operation can be exercised separately, without touching a real Trash.
    init(
        engine: (any ScanEngine)? = nil,
        reclaimController: ReclaimController,
        optionsStore: ScanOptionsStore = .shared
    ) {
        self.engine = engine
        self.reclaimController = reclaimController
        self.optionsStore = optionsStore
    }

    /// Connects (or replaces) the scanning engine. Called by the app shell once
    /// the scan engine is available.
    public func setEngine(_ engine: any ScanEngine) {
        self.engine = engine
    }

    // MARK: Derived accessors (observed through the stored properties)

    public var isScanning: Bool { phase == .scanning }
    public var hasResults: Bool { summary != nil }

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
    }

    /// Shows the source-selection screen without touching the scan: a scan already
    /// running keeps running in the background, and its results stay available.
    public func showHome() {
        route = .home
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
        isResultsScrolling = false
        phase = .idle
        route = .home
        resultsRevision &+= 1
    }

    // MARK: - Event consumption

    private func consume(_ stream: AsyncStream<ScanEvent>, generation: Int) async {
        for await event in stream {
            guard generation == scanGeneration else { return }
            switch event {
            case .started(let root):
                currentRoot = root
            case .progress(let p):
                progress = p
            case .issue(let kind, let path, let message):
                issues.append(ScanIssue(path: path, message: message, kind: kind))
            case .partial(let snapshot):
                hold(snapshot, generation: generation)
            case .finished(let s):
                discardHeldPartial()
                summary = s
                partialSummary = nil
                progress = nil
                phase = .finished
                resultsRevision &+= 1
            case .cancelled(let partial):
                discardHeldPartial()
                if let partial { summary = partial }
                partialSummary = nil
                progress = nil
                phase = .cancelled
                resultsRevision &+= 1
                // A scan stopped before it produced any results has nothing to
                // open, so the flow returns to source selection rather than
                // showing an empty results screen.
                if summary == nil { route = .home }
            }
        }

        // The contract promises exactly one terminal event. If the stream ends
        // without one the scan is over either way, so the screen settles on what
        // it has instead of reporting a scan that is no longer running.
        guard generation == scanGeneration, phase == .scanning else { return }
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
