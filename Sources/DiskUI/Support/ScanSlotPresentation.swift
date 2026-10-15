import Foundation

/// The Home screen's view of the location that occupies the engine's scan slot.
///
/// The engine keeps a single scan slot, so at most one location is on it at a
/// time: the scan running now, or the most recent scan whose results are still
/// available. Home shows that location's row as this status — with a View action
/// in place of a start-scan action — and keeps it truthful as the scan settles.
///
/// Pure and `Equatable`, so the row's wording can be verified without a running
/// view.
public struct ScanSlotPresentation: Equatable, Sendable {

    /// The scan's state as the Home row reads it.
    public enum State: Equatable, Sendable {
        /// The scan is running right now.
        case scanning
        /// The scan covered the whole root.
        case finished
        /// The scan was stopped before it had covered the whole root, so its
        /// totals are only part of the location.
        case stopped
    }

    /// The location on the slot — the same location as the row showing this.
    public let root: URL
    public let state: State
    /// The engine's real completion fraction, present only when the engine
    /// reports one. A row must never infer or invent a fraction.
    public let fraction: Double?
    /// Files the engine has actually counted.
    public let filesScanned: Int
    /// Logical bytes the engine has actually counted.
    public let bytesScanned: Int64

    /// Whether the scan is still running, so the row shows a live indicator.
    public var isLive: Bool { state == .scanning }

    /// Short status, e.g. `"Scanning…"`.
    public var label: String {
        switch state {
        case .scanning: return "Scanning…"
        case .finished: return "Scan complete"
        case .stopped: return "Scan stopped"
        }
    }

    /// The honest supporting numbers: the live counters while the scan runs,
    /// its totals once it has settled. `nil` when there is nothing to report
    /// yet, so the row never shows a fabricated zero.
    public var detail: String? {
        var parts: [String] = []
        if filesScanned > 0 { parts.append("\(filesScanned.formatted(.number)) files") }
        if bytesScanned > 0 { parts.append(ByteFormat.string(bytesScanned)) }
        guard !parts.isEmpty else { return nil }
        let counts = parts.joined(separator: " · ")
        switch state {
        case .scanning: return "\(counts) so far"
        case .finished: return counts
        case .stopped: return "\(counts) gathered"
        }
    }

    /// One spoken phrase for the status, saying plainly whether the numbers are
    /// still arriving or are final.
    public var accessibilityLabel: String {
        let counts = detail?.replacingOccurrences(of: " · ", with: ", ")
        switch state {
        case .scanning:
            return counts.map { "Scanning, \($0)" } ?? "Scanning"
        case .finished:
            return counts.map { "Scan finished, \($0)" } ?? "Scan finished"
        case .stopped:
            return counts.map { "Scan stopped, \($0), results are partial" }
                ?? "Scan stopped, results are partial"
        }
    }

    public init(
        root: URL,
        state: State,
        filesScanned: Int,
        bytesScanned: Int64,
        fraction: Double?
    ) {
        self.root = root
        self.state = state
        self.filesScanned = max(0, filesScanned)
        self.bytesScanned = max(0, bytesScanned)
        self.fraction = fraction
    }
}
