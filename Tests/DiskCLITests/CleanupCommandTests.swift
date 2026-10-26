import XCTest
import Foundation
import Darwin
@testable import DiskCLI
import DiskCore
import DiskLocalization

/// `WillyDisk cleanup`: what it parses, what it lists, and the record it writes.
final class CleanupCommandTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        L10n.overrideLanguage("en")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskCleanupCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        L10n.overrideLanguage(nil)
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Parsing

    func testParsesTheFolderAndFlags() throws {
        guard case .cleanup(let command) = try ScanCommandLine.parse([
            "WillyDisk", "cleanup", root.path, "--json", "--check-contents",
        ]) else {
            return XCTFail("expected a cleanup invocation")
        }
        XCTAssertEqual(command.root.path, root.standardizedFileURL.path)
        XCTAssertTrue(command.json)
        XCTAssertTrue(command.checksContents)
    }

    func testHelpExitsZeroAndListsTheFlags() {
        let recorder = OutputRecorder()
        let code = ScanCLI.run(
            arguments: ["WillyDisk", "cleanup", "--help"],
            output: recorder.output,
            installsSignalHandling: false
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(recorder.err, "")
        for flag in ["WillyDisk cleanup", "USAGE", "--json", "--check-contents", "EXIT STATUS"] {
            XCTAssertTrue(recorder.out.contains(flag), "help should list \(flag)")
        }
    }

    func testMissingFolderExitsOne() {
        let recorder = OutputRecorder()
        let code = ScanCLI.run(
            arguments: ["WillyDisk", "cleanup", root.appendingPathComponent("not-there").path],
            output: recorder.output,
            installsSignalHandling: false
        )
        XCTAssertEqual(code, 1)
        XCTAssertTrue(recorder.err.contains("no such folder"))
        XCTAssertEqual(recorder.out, "")
    }

    func testUsageErrorNamesTheCleanupHelp() {
        let recorder = OutputRecorder()
        let code = ScanCLI.run(
            arguments: ["WillyDisk", "cleanup", "--bogus"],
            output: recorder.output,
            installsSignalHandling: false
        )
        XCTAssertEqual(code, 2)
        XCTAssertTrue(recorder.err.contains("unknown option '--bogus'"))
        XCTAssertTrue(recorder.err.contains("cleanup --help"))
    }

    // MARK: - Text report

    func testTextListsTheRulesAndDuplicateSizes() async throws {
        try makeFixture()

        let run = try await cleanupText()
        XCTAssertEqual(run.code, 0, run.stderr)
        XCTAssertEqual(run.stderr, "")
        XCTAssertTrue(run.text.contains("WillyDisk cleanup"))
        XCTAssertTrue(run.text.contains("bytes on disk"))
        XCTAssertTrue(run.text.contains("Rebuildable"))
        XCTAssertTrue(run.text.contains("Caches"))
        XCTAssertTrue(run.text.contains("Logs"))
        XCTAssertTrue(run.text.contains("Your files"))
        XCTAssertTrue(run.text.contains("Old downloads"))
        XCTAssertTrue(run.text.contains("Duplicates"))
        XCTAssertTrue(run.text.contains("1 size group"))
        XCTAssertTrue(run.text.contains("copy-a.bin"))
        XCTAssertTrue(run.text.contains("copy-b.bin"))
        XCTAssertFalse(run.text.contains("Identical contents"), "contents are not read without --check-contents")
    }

    func testTextChecksContentsOnlyWhenAsked() async throws {
        try makeFixture()

        let run = try await cleanupText(checksContents: true)
        XCTAssertEqual(run.code, 0, run.stderr)
        XCTAssertTrue(run.text.contains("Identical contents"))
        XCTAssertTrue(run.text.contains("Compared"))
    }

    func testLargeAndOldUsesThePolicyItIsGiven() async throws {
        try makeFixture()
        let policy = CleanupPolicy(
            largeFileMinimum: 5_000,
            largeFileAge: 30 * 24 * 3600,
            downloadAge: 30 * 24 * 3600
        )

        let recorder = OutputRecorder()
        let code = await ScanCLI.executeCleanup(
            CleanupCommand(root: root, policy: policy),
            engine: FileScanEngine(),
            output: recorder.output
        )
        XCTAssertEqual(code, 0, recorder.err)
        XCTAssertTrue(recorder.out.contains("Large and old"))
        XCTAssertTrue(recorder.out.contains("old-large.bin"))
    }

    func testContentsAreNotSummarizedWhenNothingWasCompared() async throws {
        let original = root.appendingPathComponent("Documents/original.bin")
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 1_200_000).write(to: original)
        let clone = root.appendingPathComponent("Documents/clone.bin")
        guard clonefile(original.path, clone.path, 0) == 0 else {
            throw XCTSkip("this volume does not support clones")
        }

        let run = try await cleanupText(checksContents: true)

        XCTAssertEqual(run.code, 0, run.stderr)
        XCTAssertTrue(run.text.contains("No identical contents found"))
        XCTAssertFalse(run.text.contains("Compared 0"), run.text)
        XCTAssertTrue(run.text.contains("share storage"), run.text)
    }

    // MARK: - Record

    func testJSONIsTheVersionedRecordAndIsStableAcrossRuns() async throws {
        try makeFixture()

        let first = try await cleanupJSON()
        XCTAssertEqual(first.code, 0, first.stderr)
        XCTAssertEqual(first.stderr, "")
        let second = try await cleanupJSON()

        XCTAssertEqual(
            normalizedScannedAt(first.text),
            normalizedScannedAt(second.text),
            "two runs of the same folder differ only in the scan's time"
        )

        let record = try decode(first.text)
        XCTAssertEqual(record.schemaVersion, CleanupOutput.currentSchemaVersion)
        XCTAssertEqual(record.rootPath, root.standardizedFileURL.path)
        XCTAssertEqual(record.stoppedAtLimit, false)
        XCTAssertNil(record.contents, "contents are only read when asked for")
        XCTAssertEqual(record.duplicates.fileCount, 2)
        XCTAssertEqual(record.duplicates.groupCount, 1)
        XCTAssertEqual(
            record.duplicates.groups.first?.paths.map { ($0 as NSString).lastPathComponent },
            ["copy-a.bin", "copy-b.bin"]
        )

        let caches = try XCTUnwrap(record.groups.first { $0.rule == "caches" })
        XCTAssertEqual(caches.tier, "rebuildable")
        XCTAssertEqual(caches.shownCount, 1)
        XCTAssertEqual(caches.candidates.first?.isDirectory, true)
        XCTAssertEqual(
            caches.candidates.first.map { ($0.path as NSString).lastPathComponent },
            "Caches"
        )

        let downloads = try XCTUnwrap(record.groups.first { $0.rule == "downloads" })
        XCTAssertEqual(downloads.tier, "personal")
    }

    func testJSONCarriesContentsWhenChecked() async throws {
        try makeFixture()
        let run = try await cleanupJSON(checksContents: true)
        let record = try decode(run.text)
        let contents = try XCTUnwrap(record.contents)
        XCTAssertEqual(contents.candidateFileCount, 2)
        XCTAssertEqual(contents.comparedFileCount, 2)
        XCTAssertEqual(contents.groups.count, 1)
        XCTAssertEqual(
            contents.groups.first?.paths.map { ($0 as NSString).lastPathComponent },
            ["copy-a.bin", "copy-b.bin"]
        )
    }

    func testContentsAreNotCheckedWhenThereIsNothingToCompare() async throws {
        try write("Documents/only.bin", bytes: 2_000)

        let text = try await cleanupText(checksContents: true)
        XCTAssertEqual(text.code, 0, text.stderr)
        XCTAssertFalse(text.text.contains("Identical contents"))

        let json = try await cleanupJSON(checksContents: true)
        XCTAssertNil(try decode(json.text).contents)
    }

    // MARK: - Cancellation and failure

    func testACancelledScanWritesNoReport() async {
        let recorder = OutputRecorder()
        let code = await ScanCLI.executeCleanup(
            CleanupCommand(root: root),
            engine: ScriptedEngine(events: [
                .started(root: root),
                .cancelled(partial: summary()),
            ]),
            output: recorder.output
        )
        XCTAssertEqual(code, 130)
        XCTAssertEqual(recorder.out, "")
        XCTAssertEqual(recorder.err, "Scan cancelled.\n")
    }

    func testASummaryThatCannotBecomeATreeFails() async {
        let recorder = OutputRecorder()
        let code = await ScanCLI.executeCleanup(
            CleanupCommand(root: root),
            engine: ScriptedEngine(events: [.finished(summary())]),
            output: recorder.output
        )
        XCTAssertEqual(code, 1)
        XCTAssertEqual(recorder.out, "")
        XCTAssertTrue(recorder.err.contains("tree to review"))
    }

    // MARK: - Fixture

    /// Caches and logs (rebuildable), an old download, and two identical
    /// same-size files, plus one file the large-and-old test can find.
    private func makeFixture() throws {
        try write("Library/Caches/com.example/blob.bin", bytes: 3_000)
        try write("Library/Logs/app.log", bytes: 1_000)
        try write("Downloads/old.zip", bytes: 2_000)
        try write("Documents/copy-a.bin", bytes: 1_200_000)
        try write("Documents/copy-b.bin", bytes: 1_200_000)
        try write("Documents/old-large.bin", bytes: 6_000)

        let old = Date().addingTimeInterval(-400 * 86_400)
        for path in ["Downloads/old.zip", "Documents/old-large.bin"] {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: root.appendingPathComponent(path).path
            )
        }
    }

    private func write(_ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func cleanupText(
        checksContents: Bool = false
    ) async throws -> (code: Int32, text: String, stderr: String) {
        let recorder = OutputRecorder()
        let code = await ScanCLI.executeCleanup(
            CleanupCommand(root: root, checksContents: checksContents),
            engine: FileScanEngine(),
            output: recorder.output
        )
        return (code, recorder.out, recorder.err)
    }

    private func cleanupJSON(
        checksContents: Bool = false
    ) async throws -> (code: Int32, text: String, stderr: String) {
        let recorder = OutputRecorder()
        let code = await ScanCLI.executeCleanup(
            CleanupCommand(root: root, json: true, checksContents: checksContents),
            engine: FileScanEngine(),
            output: recorder.output
        )
        return (code, recorder.out, recorder.err)
    }

    private func decode(_ json: String) throws -> CleanupRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CleanupRecord.self, from: Data(json.utf8))
    }

    private func normalizedScannedAt(_ json: String) -> String {
        json.replacingOccurrences(
            of: #""scannedAt" : "[^"]+""#,
            with: #""scannedAt" : "run""#,
            options: .regularExpression
        )
    }

    private func summary() -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: 1,
            totalAllocatedSize: 1,
            fileCount: 1,
            directoryCount: 1,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_001),
            categoryBreakdown: [:],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )
    }
}
