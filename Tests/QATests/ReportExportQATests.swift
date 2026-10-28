import XCTest
import Foundation
@testable import DiskCore
import DiskLocalization
@testable import DiskUI

/// The exported CSV is a report, not just a ranked table: the totals, access
/// counts, and accounting disclosures travel with the items they describe.
@MainActor
final class ReportExportQATests: XCTestCase {

    override func setUp() {
        super.setUp()
        L10n.overrideLanguage("en")
    }

    override func tearDown() {
        L10n.overrideLanguage(nil)
        super.tearDown()
    }

    private func summary() -> ScanSummary {
        let file = ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: "/scan/a,b.txt"),
            name: "a,b.txt",
            isDirectory: false,
            isSymlink: false,
            category: .documents,
            logicalSize: 10,
            allocatedSize: 20,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
        let folder = ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: "/scan/Folder", isDirectory: true),
            name: "Folder",
            isDirectory: true,
            isSymlink: false,
            category: .other,
            logicalSize: 10,
            allocatedSize: 20,
            fileCount: 1,
            directoryCount: 1,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
        return ScanSummary(
            root: URL(fileURLWithPath: "/scan", isDirectory: true),
            totalLogicalSize: 1_000,
            totalAllocatedSize: 2_000,
            fileCount: 3,
            directoryCount: 2,
            inaccessibleCount: 2,
            errorCount: 4,
            permissionDeniedCount: 1,
            surfacedIssueCount: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_042),
            categoryBreakdown: [.documents: 10],
            largestFiles: [file],
            largestDirectories: [folder],
            rootChildren: [],
            accounting: ScanAccounting(
                hardlinkFileCount: 2,
                hardlinkExtraLogicalSize: 30,
                hardlinkExtraAllocatedSize: 40,
                datalessFileCount: 3,
                datalessLogicalSize: 50,
                datalessAllocatedSize: 5,
                skippedSymlinkCount: 4,
                skippedVolumeCount: 1,
                specialFileCount: 2,
                excludedItemCount: 6
            )
        )
    }

    private func fields(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    func testCSVCarriesTotalsAccessAndAccounting() throws {
        let csv = ReportExport.makeCSV(summary())
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(fields(try XCTUnwrap(lines.first)).last, "Value")
        XCTAssertEqual(fields(try XCTUnwrap(lines.first)).count, 10)

        let total = try XCTUnwrap(lines.first { $0.hasPrefix("Total,") })
        let totalFields = fields(total)
        XCTAssertEqual(totalFields[1], "This scan")
        XCTAssertEqual(totalFields[2], "/scan")
        XCTAssertEqual(totalFields[4], "1000")
        XCTAssertEqual(totalFields[5], "2000")
        XCTAssertEqual(totalFields[6], "3")
        XCTAssertEqual(totalFields[7], "2")

        let notRead = try XCTUnwrap(lines.first { $0.hasPrefix("Access,Folders not read,") })
        XCTAssertEqual(fields(notRead)[9], "2")

        let restricted = try XCTUnwrap(lines.first { $0.hasPrefix("Access,Restricted locations,") })
        XCTAssertEqual(fields(restricted)[9], "1")

        let surfaced = try XCTUnwrap(lines.first { $0.hasPrefix("Access,Issues surfaced,") })
        XCTAssertEqual(fields(surfaced)[9], "2")

        let hardlinks = try XCTUnwrap(lines.first { $0.hasPrefix("Accounting,Hard-linked files,") })
        let hardlinkFields = fields(hardlinks)
        XCTAssertEqual(hardlinkFields[4], "30", "bytes counted again, logical")
        XCTAssertEqual(hardlinkFields[5], "40", "bytes counted again, on disk")
        XCTAssertEqual(hardlinkFields[9], "2", "hard-linked files")

        let exclusions = try XCTUnwrap(lines.first { $0.hasPrefix("Accounting,Skipped by your exclusions,") })
        XCTAssertEqual(fields(exclusions)[9], "6")

        XCTAssertTrue(csv.contains("File,\"a,b.txt\""), "a comma in a name is quoted once")
        XCTAssertFalse(csv.contains("\"\"a,b.txt\"\""), "and not escaped twice")
    }
}
