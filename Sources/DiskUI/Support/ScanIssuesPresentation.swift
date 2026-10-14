import Foundation
import DiskCore

/// The bounded, classified view of a scan's issues that DiskUI renders.
///
/// Built from the surfaced `ScanIssue`s **and** the truthful totals on
/// `ScanSummary`, so a whole-volume scan shows one calm access notice with a
/// capped detail list. Totals are read from the summary — never from
/// `issues.count` — because the engine surfaces at most
/// `FileScanner.maxSurfacedIssues` per-path details while `errorCount` stays
/// uncapped.
///
/// Pure and `Equatable`, so the presentation rules can be verified without a
/// running view.
public struct ScanIssuesPresentation: Equatable, Sendable {

    /// Most issue rows any screen renders. Mirrors the engine's own surfacing
    /// bound so the UI stays bounded even if a future engine stops capping.
    public static let rowLimit = 50

    /// Rows to render, in the order the engine surfaced them, capped at
    /// `rowLimit`.
    public let rows: [ScanIssue]
    /// Distinct restricted locations — the actionable number the access notice
    /// reports. `ScanSummary.permissionDeniedCount` once the scan is final;
    /// while scanning, the denials surfaced so far.
    public let restrictedLocationCount: Int
    /// Issues that are *not* access restrictions — `errorCount −
    /// permissionDeniedCount` once the scan is final, else the non-permission
    /// rows surfaced so far. Never negative.
    public let otherIssueCount: Int
    /// Issues that exist but are not rendered: the engine's unsurfaced
    /// remainder (`errorCount − surfacedIssueCount`) plus any rows past
    /// `rowLimit`. Never negative.
    public let unlistedCount: Int
    /// The truthful total once the scan has finished (`errorCount`); while
    /// scanning, the number surfaced so far (`rows.count + unlistedCount`).
    public let totalIssueCount: Int
    /// `true` when the totals come from a finished/cancelled `ScanSummary`,
    /// `false` while the scan is still running (so copy can say "so far").
    public let totalsAreFinal: Bool

    /// Whether the scan reported permission-denied locations — the case the
    /// access notice explains and offers the Full Disk Access action for.
    public var shouldShowBanner: Bool { restrictedLocationCount > 0 }

    public var hasRows: Bool { !rows.isEmpty }

    /// Whether the findings are access restrictions (the actionable case)
    /// rather than only other unreadable items.
    public var isAccessRestriction: Bool { restrictedLocationCount > 0 }

    /// Whether access restrictions dominate the findings.
    ///
    /// Access restrictions are the overwhelming majority of findings when a
    /// whole volume is scanned without Full Disk Access, so a majority of them
    /// makes the headline report the actionable number — restricted locations —
    /// while every genuine fault keeps its warning styling row by row.
    public var isDenialDominated: Bool { restrictedLocationCount > otherIssueCount }

    /// Whether any issue exists but is not among the rendered rows.
    public var hasUnlisted: Bool { unlistedCount > 0 }

    /// The count the access notice reports: restricted locations when the
    /// findings are access restrictions, otherwise every unreadable item.
    public var noticeCount: Int {
        isAccessRestriction ? restrictedLocationCount : totalIssueCount
    }

    /// The glyph the access notice leads with, matching what it accounts for so
    /// a pure-fault scan never claims a lock.
    public var noticeSymbolName: String {
        isAccessRestriction ? "lock.fill" : "exclamationmark.triangle"
    }

    /// One-line headline for the access notice, e.g. `"512 locations
    /// restricted"` or `"3 issues so far"` while the scan is still running.
    public var noticeHeadline: String {
        let soFar = totalsAreFinal ? "" : " so far"
        if isAccessRestriction {
            let noun = restrictedLocationCount == 1 ? "location" : "locations"
            return "\(restrictedLocationCount) \(noun) restricted\(soFar)"
        }
        let noun = totalIssueCount == 1 ? "issue" : "issues"
        return "\(totalIssueCount) \(noun)\(soFar)"
    }

    /// Title of the detail list: expected access restrictions are not failures,
    /// so a denial-dominated list names them as locations.
    public var listTitle: String {
        isDenialDominated ? "Unreadable locations" : "Issues"
    }

    /// One-line accounting for the bounded list, e.g.
    /// `"Showing the first 50 of 512 — 462 more not listed"`.
    public var listSummaryText: String {
        if hasUnlisted {
            return "Showing the first \(rows.count) of \(totalIssueCount) — \(unlistedCount) more not listed"
        }
        if !totalsAreFinal {
            return rows.count >= Self.rowLimit
                ? "Showing the first \(rows.count) — more may follow"
                : "\(rows.count) so far"
        }
        return "\(rows.count) total"
    }

    public init(issues: [ScanIssue], summary: ScanSummary?) {
        let surfacedCount = issues.count
        let rows = Array(issues.prefix(Self.rowLimit))

        // The engine's uncapped remainder, plus anything this list itself drops.
        let engineUnlisted = summary.map { max(0, $0.errorCount - $0.surfacedIssueCount) } ?? 0
        let listUnlisted = max(0, surfacedCount - Self.rowLimit)
        let unlisted = engineUnlisted + listUnlisted

        self.rows = rows
        self.unlistedCount = unlisted
        self.totalIssueCount = rows.count + unlisted
        self.totalsAreFinal = summary != nil
        self.restrictedLocationCount = summary?.permissionDeniedCount
            ?? rows.filter { $0.kind == .permissionDenied }.count
        self.otherIssueCount = summary.map { max(0, $0.errorCount - $0.permissionDeniedCount) }
            ?? rows.filter { $0.kind != .permissionDenied }.count
    }
}
