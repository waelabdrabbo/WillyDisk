import XCTest
import Foundation
import DiskCore
import DiskLocalization
@testable import DiskUI

/// The recent list replaced a path line with a last-run line. These pin the two
/// rules that make that safe: a measured summary is preferred only when it can
/// identify the row, and a repeated name keeps the path that tells it apart.
final class RecentLocationSummaryQATests: XCTestCase {

    override func setUp() {
        super.setUp()
        L10n.overrideLanguage("en")
    }

    override func tearDown() {
        L10n.overrideLanguage(nil)
        super.tearDown()
    }

    private func record(
        root: String = "/Users/me/Documents",
        finished: Date,
        size: Int64 = 1_500_000_000
    ) -> ScanRecord {
        ScanRecord(
            rootPath: root,
            startedAt: finished.addingTimeInterval(-60),
            finishedAt: finished,
            totalLogicalSize: size,
            totalAllocatedSize: size,
            fileCount: 10,
            directoryCount: 2,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            categorySizes: [:],
            largestFiles: [],
            largestDirectories: [],
            entryCapacity: ScanRecord.currentEntryCapacity,
            accounting: RecordedAccounting(),
            options: RecordedOptions(
                followSymlinks: false,
                stayOnVolume: true,
                includeHidden: false,
                excludedPaths: []
            ),
            volume: nil
        )
    }

    func testFinishedRunShowsSizeAndAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(fileURLWithPath: "/Users/me/Documents")
        let detail = RecentLocationDetail.of(
            url: url,
            record: record(finished: now.addingTimeInterval(-2 * 86_400)),
            nameIsRepeated: false,
            now: now
        )

        XCTAssertFalse(detail.isPath)
        XCTAssertTrue(detail.text.hasPrefix("Last scan "))
        XCTAssertTrue(detail.text.contains("GB"))
        XCTAssertTrue(detail.text.contains("2 days ago"))
    }

    func testNoFinishedRunFallsBackToThePath() {
        let url = URL(fileURLWithPath: "/Users/me/Documents")
        let detail = RecentLocationDetail.of(url: url, record: nil, nameIsRepeated: false)

        XCTAssertTrue(detail.isPath)
        XCTAssertEqual(detail.text, PathFormat.abbreviated(url.path))
    }

    func testRepeatedNameKeepsThePathThatDistinguishesIt() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let url = URL(fileURLWithPath: "/Users/me/Archive/Documents")
        let detail = RecentLocationDetail.of(
            url: url,
            record: record(root: url.path, finished: now.addingTimeInterval(-2 * 86_400)),
            nameIsRepeated: true,
            now: now
        )

        XCTAssertTrue(detail.isPath)
        XCTAssertFalse(detail.text.contains("Last scan"))
        XCTAssertEqual(detail.text, PathFormat.abbreviated(url.path))
    }

    func testOnlyCollidingNamesAreRepeated() {
        let urls = [
            URL(fileURLWithPath: "/Users/me/Documents"),
            URL(fileURLWithPath: "/Users/me/Archive/Documents"),
            URL(fileURLWithPath: "/Users/me/Downloads"),
        ]

        XCTAssertEqual(RecentLocations.repeatedNames(in: urls), ["Documents"])
        XCTAssertTrue(RecentLocations.repeatedNames(in: [urls[0], urls[2]]).isEmpty)
    }
}
