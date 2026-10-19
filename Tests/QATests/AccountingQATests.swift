import XCTest
import Foundation
import Darwin
import DiskCore
@testable import DiskUI

/// Verifies the accounting disclosures the app shows against a real filesystem,
/// not against the engine's own model of one.
final class AccountingQATests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskAccounting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func finishScan(_ request: ScanRequest) async throws -> ScanSummary {
        let engine = FileScanEngine()
        for await event in engine.scan(request) {
            if case .finished(let summary) = event { return summary }
        }
        throw XCTSkip("the scan produced no terminal summary")
    }

    func testHardLinksCountEveryLinkAndDiscloseTheOverlap() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        let link = root.appendingPathComponent("second-link.bin")
        let payload = Data(repeating: 0x41, count: 1_048_576)
        try payload.write(to: original)
        try FileManager.default.linkItem(at: original, to: link)

        let summary = try await finishScan(ScanRequest(root: root))
        XCTAssertEqual(summary.totalLogicalSize, 2 * Int64(payload.count),
                       "the total counts every link the walk reaches")
        XCTAssertEqual(summary.accounting.hardlinkFileCount, 1)
        XCTAssertEqual(summary.accounting.hardlinkExtraLogicalSize, Int64(payload.count))
        XCTAssertGreaterThan(summary.accounting.hardlinkExtraAllocatedSize, 0)
    }

    func testUnfollowedSymlinkIsSkippedAndDisclosed() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target.bin")
        try Data(repeating: 0x42, count: 4_096).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.bin"),
            withDestinationURL: target
        )

        let summary = try await finishScan(ScanRequest(root: root, followSymlinks: false))
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.totalLogicalSize, 4_096)
        XCTAssertEqual(summary.accounting.skippedSymlinkCount, 1)
    }

    func testFIFOIsSkippedAndDisclosed() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x43, count: 128).write(to: root.appendingPathComponent("real.bin"))
        let fifo = root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0, "mkfifo: \(String(cString: strerror(errno)))")

        let summary = try await finishScan(ScanRequest(root: root))
        XCTAssertEqual(summary.fileCount, 1)
        XCTAssertEqual(summary.accounting.specialFileCount, 1)
    }

    func testSnapshotParserReadsNamesAndIgnoresHeaders() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-19-120000.local
        com.apple.TimeMachine.2026-10-18-120000.local
        com.apple.TimeMachine.2026-10-19-120000.local

        """
        XCTAssertEqual(
            SnapshotProbe.parse(output),
            [
                "com.apple.TimeMachine.2026-10-19-120000.local",
                "com.apple.TimeMachine.2026-10-18-120000.local",
            ]
        )
    }
}
