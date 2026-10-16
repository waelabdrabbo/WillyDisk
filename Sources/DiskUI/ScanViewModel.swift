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

    /// Bumped whenever the results a screen renders change: a progressive
    /// snapshot the screen takes (see `partialApplicationInterval`), the terminal
    /// summary, or a scan starting over. Screens key derived work — filtering and
    /// ordering a folder's entries — on it, so that work is redone when the data
    /// changes and not on every pass through a body. Progress and issue events
    /// carry no new tree data, so they do not bump it.
    public private(set) var resultsRevision = 0

    private var engine: (any ScanEngine)?
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

    public init(engine: (any ScanEngine)? = nil) {
        self.engine = engine
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

    public func start(
        root: URL,
        followSymlinks: Bool = false,
        stayOnVolume: Bool = true,
        includeHidden: Bool = true
    ) {
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
        phase = .scanning
        resultsRevision &+= 1

        let request = ScanRequest(
            root: root,
            followSymlinks: followSymlinks,
            stayOnVolume: stayOnVolume,
            includeHidden: includeHidden
        )
        let stream = engine.scan(request)
        scanTask = Task { [weak self] in
            await self?.consume(stream, generation: generation)
        }
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
        blockedStartNotice = nil
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
