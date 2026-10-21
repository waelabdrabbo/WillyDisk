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

    func testRankedListAppliesTheCategoryFilter() {
        let images = makeNode("/scan/big.jpg", size: 900, category: .images)
        let document = makeNode("/scan/report.pdf", size: 800, category: .documents)
        let smallImage = makeNode("/scan/small.png", size: 100, category: .images)

        let filtered = ExplorerQuery.ranked(
            [document, smallImage, images],
            search: "",
            category: .images
        )

        XCTAssertEqual(filtered.map(\.url), [images.url, smallImage.url],
                       "only images, still largest first")
    }

    func testRankedListWithoutAFilterKeepsEverything() {
        let images = makeNode("/scan/big.jpg", size: 900, category: .images)
        let document = makeNode("/scan/report.pdf", size: 800, category: .documents)

        let all = ExplorerQuery.ranked([document, images], search: "", category: nil)
        XCTAssertEqual(all.map(\.url), [images.url, document.url])
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
