import XCTest
import Foundation
import DiskCore
@testable import DiskUI

/// The coverage sheet's words are the product's promise about what it knows.
/// These tests pin the promises that are easy to break: no invented
/// reconciliation, every skip named, and an unavailable answer said out loud.
final class CoverageQATests: XCTestCase {
    private func makeSummary(
        root: String = "/Users/me/Projects",
        accounting: ScanAccounting = .zero,
        inaccessibleCount: Int = 0,
        errorCount: Int = 0
    ) -> ScanSummary {
        ScanSummary(
            root: URL(fileURLWithPath: root),
            totalLogicalSize: 10_000_000,
            totalAllocatedSize: 12_000_000,
            fileCount: 120,
            directoryCount: 12,
            inaccessibleCount: inaccessibleCount,
            errorCount: errorCount,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_042),
            categoryBreakdown: [:],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: [],
            accounting: accounting
        )
    }

    private func facts(
        total: Int64 = 500_000_000_000,
        available: Int64 = 200_000_000_000,
        important: Int64? = nil
    ) -> VolumeFacts {
        VolumeFacts(
            mountURL: URL(fileURLWithPath: "/"),
            name: "Macintosh HD",
            totalCapacity: total,
            availableCapacity: available,
            availableForImportantUsage: important,
            isReadOnly: false
        )
    }

    func testReportNamesEveryOverlapAndSkip() {
        let report = CoverageReport(
            summary: makeSummary(
                accounting: ScanAccounting(
                    hardlinkFileCount: 2,
                    hardlinkExtraLogicalSize: 1_500_000,
                    hardlinkExtraAllocatedSize: 2_000_000,
                    datalessFileCount: 3,
                    datalessLogicalSize: 4_000_000,
                    datalessAllocatedSize: 1_000,
                    skippedSymlinkCount: 4,
                    skippedVolumeCount: 1,
                    specialFileCount: 2,
                    excludedItemCount: 3
                ),
                inaccessibleCount: 1,
                errorCount: 2
            ),
            volume: nil,
            snapshots: nil,
            isLive: false
        )

        let ids = report.limits.map(\.id)
        XCTAssertEqual(ids, ["inaccessible", "exclusions", "hardlinks", "dataless", "symlinks", "volumes", "special"])
        XCTAssertTrue(report.limits[2].detail?.contains("counted more than once") == true)
        XCTAssertTrue(report.limits[3].detail?.contains("not here") == true)
        XCTAssertEqual(report.volume.first?.value, "Unavailable")
        XCTAssertEqual(report.snapshots.value, "Checking…")
    }

    func testExclusionsAreDisclosedWithoutInventingASize() {
        let report = CoverageReport(
            summary: makeSummary(accounting: ScanAccounting(excludedItemCount: 2)),
            volume: facts(),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: false
        )

        let row = report.limits.first { $0.id == "exclusions" }
        XCTAssertEqual(row?.label, "Skipped by your exclusions")
        XCTAssertEqual(row?.value, "2 items")
        XCTAssertTrue(row?.detail?.contains("contents are not in the totals") == true)
        XCTAssertFalse(row?.detail?.contains("bytes") == true)
    }

    func testEmptyFindingsAreSaidPlainly() {
        let report = CoverageReport(
            summary: makeSummary(),
            volume: facts(),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: false
        )
        XCTAssertEqual(report.limits.map(\.id), ["none"])
        XCTAssertEqual(report.snapshots.value, "None listed")
        XCTAssertTrue(report.scopeNote.contains("does not subtract one from the other"))
    }

    func testUnavailableSnapshotsAreNotCalledEmpty() {
        let report = CoverageReport(
            summary: makeSummary(),
            volume: facts(),
            snapshots: LocalSnapshots(
                volumeName: "Macintosh HD",
                names: [],
                failureMessage: "`tmutil` could not list this volume's snapshots."
            ),
            isLive: false
        )
        XCTAssertEqual(report.snapshots.value, "Unavailable")
        XCTAssertTrue(report.snapshots.detail?.contains("may still hold space") == true)
    }

    func testStartupDiskIsCalledOut() {
        let rootReport = CoverageReport(
            summary: makeSummary(root: "/"),
            volume: facts(),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: false
        )
        XCTAssertNotNil(rootReport.startupDiskNote)

        let dataReport = CoverageReport(
            summary: makeSummary(root: "/System/Volumes/Data"),
            volume: facts(),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: false
        )
        XCTAssertNotNil(dataReport.startupDiskNote)

        let folderReport = CoverageReport(
            summary: makeSummary(),
            volume: facts(),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: false
        )
        XCTAssertNil(folderReport.startupDiskNote)
    }

    func testVolumePurgeableDifferenceIsExplainedNotAddedToTheScan() {
        let report = CoverageReport(
            summary: makeSummary(),
            volume: facts(available: 100_000_000_000, important: 150_000_000_000),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: false
        )
        let available = report.volume.first { $0.id == "volume-available" }
        XCTAssertNotNil(available)
        XCTAssertTrue(available?.detail?.contains("important use") == true)
        XCTAssertFalse(report.scanned.contains { $0.label.localizedCaseInsensitiveContains("reclaim") })
    }

    func testLiveReportSaysTotalsAreGrowing() {
        let report = CoverageReport(
            summary: makeSummary(),
            volume: facts(),
            snapshots: LocalSnapshots(volumeName: "Macintosh HD", names: []),
            isLive: true
        )
        XCTAssertTrue(report.isLive)
    }

    func testVolumeFactsComeFromTheSystem() async throws {
        let root = FileManager.default.temporaryDirectory
        let probed = await VolumeFactsProbe.facts(for: root)
        let facts = try XCTUnwrap(probed)
        XCTAssertGreaterThan(facts.totalCapacity, 0)
        XCTAssertGreaterThanOrEqual(facts.availableCapacity, 0)
        XCTAssertFalse(facts.name.isEmpty)
        XCTAssertFalse(facts.mountURL.path.isEmpty)
    }
}
