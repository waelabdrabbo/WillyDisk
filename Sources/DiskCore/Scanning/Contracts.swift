import Foundation

/// Frozen scanning contract.
///
/// The engine implements this contract in `Sources/DiskCore/Scanning/`; see
/// `docs/ARCHITECTURE.md`.
public struct ScanRequest: Sendable {
    public var root: URL
    public var followSymlinks: Bool = false   // default safe: do not follow
    public var stayOnVolume: Bool = true      // do not cross mount boundaries
    public var includeHidden: Bool = true

    public init(root: URL, followSymlinks: Bool = false, stayOnVolume: Bool = true, includeHidden: Bool = true) {
        self.root = root
        self.followSymlinks = followSymlinks
        self.stayOnVolume = stayOnVolume
        self.includeHidden = includeHidden
    }
}

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let bytesScanned: Int64
    /// nil when progress cannot be computed reliably (e.g. no known total). Never fabricate.
    public let fractionCompleted: Double?
    public let elapsed: TimeInterval
}

public enum ScanEvent: Sendable {
    case started(root: URL)
    case progress(ScanProgress)
    /// A non-fatal problem; the scan continues. Carries the `ScanIssueKind` so a
    /// consumer can tell an *expected* permission denial (whole-volume scan
    /// without Full Disk Access) apart from a hard I/O fault. The per-path detail
    /// stream is bounded by the engine; `ScanSummary.errorCount` is the truthful,
    /// uncapped total.
    case issue(kind: ScanIssueKind, path: String, message: String)
    /// A progressive, **non-terminal** snapshot of the results accumulated so far.
    ///
    /// The engine may emit zero or more of these between `.started` and the single
    /// terminal event. The payload is the same `ScanSummary` shape as the final
    /// result, populated only with work actually completed at the moment of the
    /// snapshot — never projected or fabricated. For a `.partial` event `finishedAt`
    /// is the snapshot timestamp (the instant this summary was produced) while
    /// `startedAt` stays the scan start; the case itself is what distinguishes an
    /// in-flight snapshot from the terminal result. Consumers may render the tree,
    /// largest items and category breakdown while the scan runs, then replace the
    /// snapshot with the terminal `.finished` summary.
    case partial(ScanSummary)
    case finished(ScanSummary)
    case cancelled(partial: ScanSummary?)        // cancellation is a first-class outcome
}

public protocol ScanEngine: Sendable {
    /// Streams events. May emit zero or more non-terminal `.partial` snapshots,
    /// then emits `.finished` or `.cancelled` exactly once, then ends. `.partial`
    /// never terminates the stream.
    func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent>
    func cancel() async
}
