import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies the category breakdown's arithmetic and its explorer filter.
final class CategoryBreakdownQATests: XCTestCase {

    func testSharesAreOfTheScanTotalAndSortedLargestFirst() throws {
        let breakdown = CategoryBreakdown(
            categoryBreakdown: [.images: 900, .video: 100],
            totalLogicalSize: 1_000
        )

        XCTAssertEqual(breakdown.shares.map(\.category), [.images, .video])
        XCTAssertEqual(breakdown.shares[0].share, 0.9, accuracy: 0.0001)
        XCTAssertEqual(breakdown.shares[1].share, 0.1, accuracy: 0.0001)
        XCTAssertEqual(breakdown.accountedSize, 1_000)
        XCTAssertEqual(breakdown.totalLogicalSize, 1_000)
    }

    func testZeroByteCategoriesAreOmitted() {
        let breakdown = CategoryBreakdown(
            categoryBreakdown: [.images: 500, .audio: 0, .other: 500],
            totalLogicalSize: 1_000
        )

        XCTAssertEqual(Set(breakdown.shares.map(\.category)), [.images, .other])
    }

    func testTiesOrderByCategoryNameSoRendersAreStable() {
        let breakdown = CategoryBreakdown(
            categoryBreakdown: [.video: 100, .images: 100],
            totalLogicalSize: 200
        )

        XCTAssertEqual(breakdown.shares.map(\.category), [.images, .video])
    }

    func testAScanWithNoBytesDividesByNothing() {
        let empty = CategoryBreakdown(categoryBreakdown: [:], totalLogicalSize: 0)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(empty.shares.isEmpty)
        XCTAssertEqual(empty.accountedSize, 0)

        let odd = CategoryBreakdown(categoryBreakdown: [.images: 10], totalLogicalSize: 0)
        XCTAssertEqual(odd.shares.first?.share, 0)
    }

    func testOneCategoryIsTheWholeScan() {
        let breakdown = CategoryBreakdown(
            categoryBreakdown: [.code: 4_096],
            totalLogicalSize: 4_096
        )
        XCTAssertEqual(breakdown.shares.first?.share, 1)
    }

    func testSummaryUsesTheScansOwnTotalAsTheDenominator() throws {
        let now = Date()
        let summary = ScanSummary(
            root: URL(fileURLWithPath: "/scan"),
            totalLogicalSize: 1_000,
            totalAllocatedSize: 1_000,
            fileCount: 1,
            directoryCount: 1,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: now,
            finishedAt: now,
            categoryBreakdown: [.images: 500],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )

        let breakdown = CategoryBreakdown(summary: summary)
        // Half the total, not all of it: the denominator is the scan total, not
        // the bytes the categorizer happened to account for.
        let share = try XCTUnwrap(breakdown.shares.first).share
        XCTAssertEqual(share, 0.5, accuracy: 0.0001)
    }

    func testWholePercentLabelsNeverRoundASliceAway() {
        XCTAssertEqual(PercentFormat.ofWhole(0), "0%")
        XCTAssertEqual(PercentFormat.ofWhole(0.004), "<1%")
        XCTAssertEqual(PercentFormat.ofWhole(0.38), "38%")
        XCTAssertEqual(PercentFormat.ofWhole(0.999), "99%")
        XCTAssertEqual(PercentFormat.ofWhole(1), "100%")
    }

    func testRankedListWithoutAFilterKeepsEverything() {
        let images = makeNode("/scan/big.jpg", size: 900, category: .images)
        let document = makeNode("/scan/report.pdf", size: 800, category: .documents)

        let all = ExplorerQuery.ranked([document, images])
        XCTAssertEqual(all.map(\.url), [images.url, document.url])
    }

    // MARK: - Category ring

    func testRingSegmentsAreProportionalAndContiguous() {
        let shares = [
            CategoryShare(category: .images, logicalSize: 50, share: 0.5),
            CategoryShare(category: .video, logicalSize: 30, share: 0.3),
            CategoryShare(category: .code, logicalSize: 20, share: 0.2),
        ]

        let segments = CategoryRingLayout.segments(from: shares)

        XCTAssertEqual(segments.map(\.category), [.images, .video, .code])
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.0001)
        XCTAssertEqual(segments[0].span, .pi, accuracy: 0.0001)
        XCTAssertEqual(segments[1].start, segments[0].end, accuracy: 0.0001)
        XCTAssertEqual(segments[2].end, 2 * .pi, accuracy: 0.0001)
    }

    func testRingDoesNotStretchAnIncompleteBreakdownToAFullCircle() throws {
        let shares = [
            CategoryShare(category: .images, logicalSize: 50, share: 0.5),
        ]

        let segments = CategoryRingLayout.segments(from: shares)
        let end = try XCTUnwrap(segments.first).end
        XCTAssertEqual(end, .pi, accuracy: 0.0001,
                       "half the bytes must draw half a ring, not a whole one")
    }

    func testRingSkipsAnEmptySlice() {
        let shares = [
            CategoryShare(category: .images, logicalSize: 50, share: 0.5),
            CategoryShare(category: .video, logicalSize: 0, share: 0),
            CategoryShare(category: .code, logicalSize: 50, share: 0.5),
        ]

        XCTAssertEqual(CategoryRingLayout.segments(from: shares).map(\.category), [.images, .code])
    }

    func testRingHoverNamesTheSliceUnderThePointer() {
        // Sized so the smallest slice is drawn last: a hover resolved by view
        // order would report `.audio` for every point on the chart.
        let shares = [
            CategoryShare(category: .images, logicalSize: 65, share: 0.65),
            CategoryShare(category: .video, logicalSize: 25, share: 0.25),
            CategoryShare(category: .audio, logicalSize: 10, share: 0.10),
        ]
        let segments = CategoryRingLayout.segments(from: shares)
        let geometry = SunburstGeometry(side: 400, ringCount: 1)
        let band = geometry.radii(ring: 1)
        let radius = (band.inner + band.outer) / 2

        func point(atAngle angle: Double) -> CGPoint {
            CGPoint(x: geometry.center.x + sin(angle) * radius,
                    y: geometry.center.y - cos(angle) * radius)
        }

        XCTAssertEqual(CategoryRingLayout.category(at: point(atAngle: 0.15 * 2 * .pi),
                                                   in: geometry, segments: segments), .images)
        XCTAssertEqual(CategoryRingLayout.category(at: point(atAngle: 0.775 * 2 * .pi),
                                                   in: geometry, segments: segments), .video)
        XCTAssertEqual(CategoryRingLayout.category(at: point(atAngle: 0.95 * 2 * .pi),
                                                   in: geometry, segments: segments), .audio)
    }

    func testRingHoverStopsAtTheSpindleAndTheRim() {
        let shares = [
            CategoryShare(category: .images, logicalSize: 1, share: 1),
        ]
        let segments = CategoryRingLayout.segments(from: shares)
        let geometry = SunburstGeometry(side: 400, ringCount: 1)

        XCTAssertNil(CategoryRingLayout.category(at: geometry.center, in: geometry, segments: segments))
        let beyondRim = CGPoint(x: geometry.center.x + geometry.outerRadius + 1,
                                y: geometry.center.y)
        XCTAssertNil(CategoryRingLayout.category(at: beyondRim, in: geometry, segments: segments))
    }

    private func makeNode(
        _ path: String,
        size: Int64,
        category: FileCategory
    ) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            isDirectory: false,
            isSymlink: false,
            category: category,
            logicalSize: size,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: Date(),
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }
}
