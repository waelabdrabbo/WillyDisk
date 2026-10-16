import XCTest
import SwiftUI
@testable import DiskCore
@testable import DiskUI

/// Independent QA verification of the access notice's single-source-of-truth
/// accounting and of the sunburst's hover identity rules.
///
/// The notice's headline, count and glyph are read by three surfaces — the
/// collapsed row, the expanded header, and the dismissed chip on the storage
/// strip. These tests pin the invariant that all three describe the same
/// findings, so no surface can call a fault a restricted location (or vice
/// versa), and that the number is never silent.
///
/// The cross-pane hover is a view-level behaviour and is verified live with a
/// real pointer; what is asserted here is the identity rule it depends on —
/// every drawn wedge has a unique id and at most one node URL, and an aggregate
/// wedge has no node at all, so it must never light a row.
final class AccessNoticeQATests: XCTestCase {

    private func summary(
        permissionDenied: Int,
        errorCount: Int,
        surfaced: Int,
        inaccessible: Int = 0
    ) -> ScanSummary {
        ScanSummary(
            root: URL(fileURLWithPath: "/qa"),
            totalLogicalSize: 1_000,
            totalAllocatedSize: 1_000,
            fileCount: 1,
            directoryCount: 1,
            inaccessibleCount: inaccessible,
            errorCount: errorCount,
            permissionDeniedCount: permissionDenied,
            surfacedIssueCount: surfaced,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: [.documents: 1_000],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )
    }

    private func denial(_ n: Int) -> [ScanIssue] {
        (0..<n).map { ScanIssue(path: "/qa/denied\($0)", message: "denied", kind: .permissionDenied) }
    }

    private func fault(_ n: Int) -> [ScanIssue] {
        (0..<n).map { ScanIssue(path: "/qa/fault\($0)", message: "I/O error", kind: .io) }
    }

    // MARK: - One number, one noun, one glyph

    func testRestrictedNoticeReportsRestrictedLocations() {
        let p = ScanIssuesPresentation(
            issues: denial(3),
            summary: summary(permissionDenied: 3, errorCount: 3, surfaced: 3, inaccessible: 3)
        )
        XCTAssertTrue(p.isAccessRestriction)
        XCTAssertEqual(p.noticeCount, 3, "the notice reports restricted locations")
        XCTAssertEqual(p.noticeCount, p.restrictedLocationCount)
        XCTAssertEqual(p.noticeHeadline, "3 locations restricted")
        XCTAssertEqual(p.noticeSymbolName, "lock.fill")
        // The headline's number is the same number every surface reports.
        XCTAssertTrue(p.noticeHeadline.hasPrefix("\(p.noticeCount) "))
    }

    func testFaultOnlyNoticeNeverClaimsRestrictedLocations() {
        let p = ScanIssuesPresentation(
            issues: fault(2),
            summary: summary(permissionDenied: 0, errorCount: 2, surfaced: 2)
        )
        XCTAssertFalse(p.isAccessRestriction, "an I/O fault is not an access restriction")
        XCTAssertEqual(p.restrictedLocationCount, 0)
        XCTAssertEqual(p.noticeCount, p.totalIssueCount, "a fault-only notice accounts for every unreadable item")
        XCTAssertEqual(p.noticeCount, 2)
        XCTAssertEqual(p.noticeHeadline, "2 issues", "it must not say 'locations restricted'")
        XCTAssertEqual(p.noticeSymbolName, "exclamationmark.triangle", "it must not claim a lock")
    }

    func testSingularNounForOneFinding() {
        let denied = ScanIssuesPresentation(
            issues: denial(1),
            summary: summary(permissionDenied: 1, errorCount: 1, surfaced: 1, inaccessible: 1)
        )
        XCTAssertEqual(denied.noticeHeadline, "1 location restricted")

        let faulty = ScanIssuesPresentation(
            issues: fault(1),
            summary: summary(permissionDenied: 0, errorCount: 1, surfaced: 1)
        )
        XCTAssertEqual(faulty.noticeHeadline, "1 issue")
    }

    func testMixedFindingsStillHeadlineTheRestrictedLocations() {
        // A denial majority: the actionable number leads, while the fault rows
        // keep their own styling row by row.
        let p = ScanIssuesPresentation(
            issues: denial(5) + fault(1),
            summary: summary(permissionDenied: 5, errorCount: 6, surfaced: 6)
        )
        XCTAssertTrue(p.isAccessRestriction)
        XCTAssertEqual(p.noticeCount, 5)
        XCTAssertEqual(p.noticeHeadline, "5 locations restricted")
        XCTAssertEqual(p.rows.filter { $0.kind == .permissionDenied }.count, 5)
        XCTAssertEqual(p.rows.filter { $0.kind != .permissionDenied }.count, 1)
    }

    func testLiveScanSaysSoFar() {
        // While scanning there is no final summary, so the totals come from the
        // rows surfaced so far and the copy must say so.
        let p = ScanIssuesPresentation(issues: denial(2), summary: nil)
        XCTAssertFalse(p.totalsAreFinal)
        XCTAssertEqual(p.noticeHeadline, "2 locations restricted so far")
        XCTAssertTrue(p.noticeHeadline.contains("so far"))
    }

    func testNoticeStaysPresentAndTruthfulWhenTheListIsCapped() {
        // 512 denials with only 50 rows surfaced: the count is the truthful 512,
        // the rows are bounded, and both surfaces read the same number.
        let p = ScanIssuesPresentation(
            issues: denial(50),
            summary: summary(permissionDenied: 512, errorCount: 512, surfaced: 50, inaccessible: 512)
        )
        XCTAssertEqual(p.rows.count, 50)
        XCTAssertEqual(p.noticeCount, 512)
        XCTAssertEqual(p.noticeHeadline, "512 locations restricted")
        XCTAssertEqual(p.listSummaryText, "Showing the first 50 of 512 — 462 more not listed")
    }

    func testNothingSilentWhenOnlyUnlistedIssuesExist() {
        // More issues exist than were surfaced, yet no row is rendered: the
        // notice must still account for them rather than showing nothing.
        let p = ScanIssuesPresentation(
            issues: [],
            summary: summary(permissionDenied: 7, errorCount: 7, surfaced: 0, inaccessible: 7)
        )
        XCTAssertFalse(p.hasRows)
        XCTAssertEqual(p.noticeCount, 7)
        XCTAssertEqual(p.noticeHeadline, "7 locations restricted")
        XCTAssertTrue(p.shouldShowBanner)
    }

    // MARK: - Hover identity rules

    private func node(
        _ name: String,
        size: Int64,
        path: String,
        isDirectory: Bool = true,
        category: FileCategory = .other,
        children: [ScanNode] = []
    ) -> ScanNode {
        ScanNode(
            id: UUID(), url: URL(fileURLWithPath: path), name: name,
            isDirectory: isDirectory, isSymlink: false, category: category,
            logicalSize: size, allocatedSize: size,
            fileCount: 0, directoryCount: 0, modifiedAt: nil,
            isAccessible: true, errorMessage: nil, children: children
        )
    }

    func testEveryDrawnWedgeHasAUniqueIDAndAtMostOneNodeURL() {
        let roots = [
            node("A", size: 60, path: "/qa/A", children: [
                node("a1", size: 40, path: "/qa/A/a1", isDirectory: false, category: .documents),
            ]),
            node("B", size: 40, path: "/qa/B"),
        ]
        let segments = SunburstLayout.segments(roots: roots, maxRings: 3, maxChildren: 12)
        XCTAssertFalse(segments.isEmpty)

        // A hovered URL must resolve to exactly one wedge, or the two panes
        // could disagree about which wedge is active.
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count, "wedge ids are unique")
        let urls = segments.compactMap { $0.node?.url }
        XCTAssertEqual(Set(urls).count, urls.count, "no URL is drawn on two wedges")
    }

    func testAggregateWedgeCarriesNoNodeSoItCannotLightARow() {
        // 20 children, 12 drawn: the remainder is one aggregate wedge with no
        // node, so a pointer over it has no counterpart row to light.
        let roots = (0..<20).map { node("child\($0)", size: Int64(1000 - $0), path: "/qa/child\($0)") }
        let segments = SunburstLayout.segments(roots: roots, maxRings: 1, maxChildren: 12)
        let aggregate = segments.filter { $0.node == nil }

        XCTAssertEqual(aggregate.count, 1)
        XCTAssertNil(aggregate.first?.node, "an aggregate wedge names no node")
        XCTAssertEqual(aggregate.first?.remainderCount, 8)
        XCTAssertGreaterThan(aggregate.first?.size ?? 0, 0, "it still carries the hidden bytes truthfully")
    }

    func testSizeZeroRowsHaveNoWedgeSoHoverCannotInventOne() {
        // The explorer and the chart share one presentability rule: a node with
        // no bytes is listed by neither, so neither can highlight the other.
        let zero = node("empty", size: 0, path: "/qa/empty")
        XCTAssertFalse(zero.isPresentable)
        let segments = SunburstLayout.segments(
            roots: [node("data", size: 10, path: "/qa/data"), zero],
            maxRings: 3, maxChildren: 12
        )
        XCTAssertTrue(segments.allSatisfy { $0.node?.url != zero.url }, "a zero-byte node is never drawn")
    }
}
