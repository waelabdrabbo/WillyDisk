import XCTest
import Foundation
@testable import DiskCLI
import DiskCore
import DiskLocalization

/// The command line as a script meets it: the arguments it accepts, the exit
/// statuses it reports, the report it prints, and the record it writes.
final class ScanCommandTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        L10n.overrideLanguage("en")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskCLITests-\(UUID().uuidString)", isDirectory: true)
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

    func testParsesDefaults() throws {
        guard case .scan(let command) = try ScanCommandLine.parse(["WillyDisk", "scan", root.path]) else {
            return XCTFail("expected a scan invocation")
        }
        XCTAssertEqual(command.root.path, root.standardizedFileURL.path)
        XCTAssertEqual(command.depth, ScanCommand.defaultDepth)
        XCTAssertEqual(command.top, ScanCommand.defaultTop)
        XCTAssertFalse(command.json)
    }

    func testParsesOptionsInAnyOrder() throws {
        let arguments = ["WillyDisk", "scan", root.path, "--json", "--top", "3", "--depth=1"]
        guard case .scan(let command) = try ScanCommandLine.parse(arguments) else {
            return XCTFail("expected a scan invocation")
        }
        XCTAssertEqual(command.root.path, root.standardizedFileURL.path)
        XCTAssertEqual(command.depth, 1)
        XCTAssertEqual(command.top, 3)
        XCTAssertTrue(command.json)
    }

    func testOptionBeforeTheFolder() throws {
        let arguments = ["WillyDisk", "scan", "--depth", "0", root.path]
        guard case .scan(let command) = try ScanCommandLine.parse(arguments) else {
            return XCTFail("expected a scan invocation")
        }
        XCTAssertEqual(command.depth, 0)
        XCTAssertEqual(command.root.path, root.standardizedFileURL.path)
    }

    func testHelpDoesNotNeedAFolder() throws {
        for arguments in [["WillyDisk", "--help"], ["WillyDisk", "-h"], ["WillyDisk", "scan", "--help"]] {
            XCTAssertEqual(try ScanCommandLine.parse(arguments), .help, "\(arguments)")
        }
        for arguments in [["WillyDisk", "cleanup", "--help"], ["WillyDisk", "cleanup", "-h"]] {
            XCTAssertEqual(try ScanCommandLine.parse(arguments), .cleanupHelp, "\(arguments)")
        }
    }

    func testUsageErrors() {
        let cases: [(arguments: [String], message: String)] = [
            (["WillyDisk"], "no command"),
            (["WillyDisk", "list"], "expected 'scan' or 'cleanup'"),
            (["WillyDisk", "scan"], "missing the folder"),
            (["WillyDisk", "scan", root.path, root.path + "2"], "only one folder"),
            (["WillyDisk", "scan", root.path, "--bogus"], "unknown option '--bogus'"),
            (["WillyDisk", "scan", root.path, "--depth"], "needs a number"),
            (["WillyDisk", "scan", root.path, "--depth", "many"], "at least 0"),
            (["WillyDisk", "scan", root.path, "--depth", "-1"], "at least 0"),
            (["WillyDisk", "scan", root.path, "--top", "0"], "at least 1"),
            (["WillyDisk", "scan", root.path, "--top=5.5"], "at least 1"),
            (["WillyDisk", "cleanup"], "missing the folder"),
            (["WillyDisk", "cleanup", root.path, "--bogus"], "unknown option '--bogus'"),
            (["WillyDisk", "cleanup", root.path, root.path + "2"], "only one folder"),
        ]
        for item in cases {
            let error = usageError(item.arguments)
            XCTAssertNotNil(error, "\(item.arguments)")
            XCTAssertTrue(
                error?.message.contains(item.message) ?? false,
                "\(item.arguments): '\(error?.message ?? "")' should mention '\(item.message)'"
            )
        }
    }

    func testProcessDispatch() {
        XCTAssertFalse(ScanCLI.handles(["WillyDisk"]))
        XCTAssertFalse(ScanCLI.handles(["WillyDisk", "somewhere"]))
        XCTAssertTrue(ScanCLI.handles(["WillyDisk", "scan", "/tmp"]))
        XCTAssertTrue(ScanCLI.handles(["WillyDisk", "cleanup", "/tmp"]))
        XCTAssertTrue(ScanCLI.handles(["WillyDisk", "--help"]))
        XCTAssertTrue(ScanCLI.handles(["WillyDisk", "-h"]))
    }

    // MARK: - Exit statuses

    func testUsageErrorExitsTwo() {
        let recorder = OutputRecorder()
        let code = ScanCLI.run(
            arguments: ["WillyDisk", "scan", "--bogus"],
            output: recorder.output,
            installsSignalHandling: false
        )
        XCTAssertEqual(code, 2)
        XCTAssertEqual(recorder.out, "")
        XCTAssertTrue(recorder.err.contains("unknown option '--bogus'"))
        XCTAssertTrue(recorder.err.contains("--help"))
    }

    func testHelpExitsZeroAndListsTheFlags() {
        let recorder = OutputRecorder()
        let code = ScanCLI.run(
            arguments: ["WillyDisk", "--help"],
            output: recorder.output,
            installsSignalHandling: false
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(recorder.err, "")
        for flag in ["--depth", "--top", "--json", "--help", "USAGE", "EXIT STATUS"] {
            XCTAssertTrue(recorder.out.contains(flag), "help should list \(flag)")
        }
    }

    func testMissingFolderExitsOne() {
        let recorder = OutputRecorder()
        let missing = root.appendingPathComponent("not-there").path
        let code = ScanCLI.run(
            arguments: ["WillyDisk", "scan", missing],
            output: recorder.output,
            installsSignalHandling: false
        )
        XCTAssertEqual(code, 1)
        XCTAssertTrue(recorder.err.contains("no such folder"))
        XCTAssertEqual(recorder.out, "")
    }

    // MARK: - Text report

    func testTextReportIsStableAndHonoursDepthAndTop() async throws {
        try makeFixture()

        let full = try await scanText(depth: 2, top: 10)
        XCTAssertEqual(full.code, 0, full.stderr)
        XCTAssertEqual(full.stderr, "")
        XCTAssertTrue(full.text.contains("WillyDisk scan"))
        XCTAssertTrue(full.text.contains("Location   \(root.standardizedFileURL.path)"))
        XCTAssertTrue(full.text.contains("Files      8"))
        XCTAssertTrue(full.text.contains("Folders    5"))
        XCTAssertTrue(full.text.contains("Options    hidden items included"))
        XCTAssertTrue(full.text.contains("Largest files (8)"))
        XCTAssertTrue(full.text.contains("By category"))
        XCTAssertTrue(full.text.contains("nested"))

        let again = try await scanText(depth: 2, top: 10)
        XCTAssertEqual(full.text, again.text, "the same folder must print the same bytes")

        let shallow = try await scanText(depth: 1, top: 2)
        XCTAssertEqual(shallow.code, 0)
        XCTAssertFalse(folderSection(of: shallow.text).contains("nested"))
        XCTAssertTrue(folderSection(of: shallow.text).contains("alpha"))
        XCTAssertTrue(folderSection(of: shallow.text).contains("gamma"))
        XCTAssertTrue(
            folderSection(of: shallow.text).contains("+ 1 more folder"),
            "top 2 must disclose the hidden folder:\n\(shallow.text)"
        )
        XCTAssertFalse(folderSection(of: shallow.text).contains("beta"))
    }

    func testArabicReportUsesLocalizedLabelsAndKeepsItsColumns() async throws {
        try makeFixture()
        L10n.overrideLanguage("ar")
        defer { L10n.overrideLanguage("en") }

        let report = try await scanText(depth: 1, top: 2)
        XCTAssertEqual(report.code, 0, report.stderr)
        XCTAssertTrue(report.text.contains("أكبر الملفات"), report.text)
        XCTAssertTrue(report.text.contains("المجلدات ("), report.text)
        XCTAssertTrue(report.text.contains("على القرص"), report.text)

        // The value column follows the widest label, so a translated label never
        // runs into its value.
        let volumeLine = report.text.components(separatedBy: "\n").first { $0.contains("على القرص") }
        XCTAssertNotNil(volumeLine)
        XCTAssertTrue(volumeLine?.contains("  ") == true)
    }

    func testTextReportNamesTheRootOnceInTheFolderTree() async throws {
        try makeFixture()
        let report = try await scanText(depth: 1, top: 10).text
        let tree = folderSection(of: report).components(separatedBy: "Folders (").last ?? ""
        let appearances = tree.components(separatedBy: root.standardizedFileURL.path).count - 1
        XCTAssertEqual(appearances, 1)
    }

    // MARK: - JSON record

    func testJSONIsTheVersionedRecordAndIsStableAcrossRuns() async throws {
        try makeFixture()

        let first = try await scanJSON()
        XCTAssertEqual(first.code, 0, first.stderr)
        XCTAssertEqual(first.stderr, "")
        let second = try await scanJSON()

        XCTAssertEqual(
            normalizedRunIdentity(first.text),
            normalizedRunIdentity(second.text),
            "two runs of the same folder differ only in the run's identity"
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ScanRecord.self, from: Data(first.text.utf8))
        XCTAssertEqual(record.schemaVersion, ScanRecord.currentSchemaVersion)
        XCTAssertEqual(record.rootPath, root.standardizedFileURL.path)
        XCTAssertEqual(record.totalLogicalSize, 16_100)
        XCTAssertEqual(record.fileCount, 8)
        XCTAssertEqual(record.directoryCount, 5)
        XCTAssertEqual(record.entryCapacity, ScanRecord.currentEntryCapacity)
        XCTAssertEqual(record.categorySizes.values.reduce(0, +), 16_100)
        XCTAssertEqual(record.options.followSymlinks, false)
        XCTAssertEqual(record.options.stayOnVolume, true)
        XCTAssertEqual(record.options.includeHidden, true)
        XCTAssertEqual(record.options.excludedPaths, [])
        XCTAssertEqual(record.largestFiles.count, 8)
        XCTAssertEqual(record.largestDirectories.count, 5)

        // Equal-size entries are ordered by path, so a concurrent walk cannot
        // change the bytes of the record.
        let rootFiles = record.largestFiles.filter { $0.logicalSize == 500 }.map(\.path)
        XCTAssertEqual(rootFiles, rootFiles.sorted())
    }

    func testJSONKeepsTheEngineCapacityDespiteTop() async throws {
        try makeFixture()
        let json = try await scanJSON(top: 1)
        XCTAssertEqual(json.code, 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ScanRecord.self, from: Data(json.text.utf8))
        XCTAssertEqual(record.entryCapacity, ScanRecord.currentEntryCapacity)
        XCTAssertEqual(record.largestFiles.count, 8)
        XCTAssertEqual(record.largestDirectories.count, 5)
    }

    // MARK: - Cancellation

    func testCancelledRunSaysSoAndWritesNoReport() async {
        let engine = ScriptedEngine(events: [
            .started(root: root),
            .partial(summary(total: 1, files: 1)),
            .cancelled(partial: summary(total: 1, files: 1)),
        ])
        let recorder = OutputRecorder()
        let code = await ScanCLI.execute(
            ScanCommand(root: root),
            engine: engine,
            output: recorder.output
        )
        XCTAssertEqual(code, 130)
        XCTAssertEqual(recorder.out, "")
        XCTAssertEqual(recorder.err, "Scan cancelled.\n")
    }

    func testPartialSnapshotIsNotTheReport() async {
        let engine = ScriptedEngine(events: [
            .started(root: root),
            .partial(summary(total: 1, files: 1)),
            .finished(summary(total: 4096, files: 4)),
        ])
        let recorder = OutputRecorder()
        let code = await ScanCLI.execute(
            ScanCommand(root: root, depth: 0),
            engine: engine,
            output: recorder.output
        )
        XCTAssertEqual(code, 0)
        XCTAssertTrue(recorder.out.contains("Files      4"))
        XCTAssertFalse(recorder.out.contains("Files      1"))
    }

    func testStreamWithoutTerminalEventFails() async {
        let engine = ScriptedEngine(events: [.started(root: root)])
        let recorder = OutputRecorder()
        let code = await ScanCLI.execute(
            ScanCommand(root: root),
            engine: engine,
            output: recorder.output
        )
        XCTAssertEqual(code, 1)
        XCTAssertEqual(recorder.out, "")
        XCTAssertTrue(recorder.err.contains("without a result"))
    }

    // MARK: - Fixture

    /// Root: 5000-byte file, two equal 500-byte files.
    /// alpha (3100) holds big (2000), small (1000), and nested (100).
    /// beta (3000) and gamma (4000) are one file each.
    private func makeFixture() throws {
        try write("root.txt", bytes: 5000)
        try write("one.dat", bytes: 500)
        try write("two.dat", bytes: 500)
        try write("alpha/big.bin", bytes: 2000)
        try write("alpha/small.bin", bytes: 1000)
        try write("alpha/nested/nested.bin", bytes: 100)
        try write("beta/beta.bin", bytes: 3000)
        try write("gamma/gamma.bin", bytes: 4000)
    }

    private func write(_ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private func folderSection(of report: String) -> String {
        report.components(separatedBy: "Largest files").first ?? report
    }

    private func scanText(depth: Int, top: Int) async throws -> (code: Int32, text: String, stderr: String) {
        let recorder = OutputRecorder()
        let code = await ScanCLI.execute(
            ScanCommand(root: root, depth: depth, top: top),
            engine: FileScanEngine(),
            output: recorder.output
        )
        return (code, recorder.out, recorder.err)
    }

    private func scanJSON(top: Int = 10) async throws -> (code: Int32, text: String, stderr: String) {
        let recorder = OutputRecorder()
        let code = await ScanCLI.execute(
            ScanCommand(root: root, top: top, json: true),
            engine: FileScanEngine(),
            output: recorder.output
        )
        return (code, recorder.out, recorder.err)
    }

    private func normalizedRunIdentity(_ json: String) -> String {
        var text = json
        let patterns = [
            (#""id" : "[^"]+""#, #""id" : "run""#),
            (#""startedAt" : "[^"]+""#, #""startedAt" : "run""#),
            (#""finishedAt" : "[^"]+""#, #""finishedAt" : "run""#),
        ]
        for (pattern, replacement) in patterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return text
    }

    private func summary(total: Int64, files: Int) -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: total,
            totalAllocatedSize: total,
            fileCount: files,
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

    private func usageError(_ arguments: [String]) -> ScanUsageError? {
        do {
            _ = try ScanCommandLine.parse(arguments)
            XCTFail("\(arguments) should not parse")
            return nil
        } catch let error as ScanUsageError {
            return error
        } catch {
            XCTFail("\(arguments) threw \(error)")
            return nil
        }
    }
}

// MARK: - Test doubles

/// Collects what the command writes, from whichever thread the scan reports on.
final class OutputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOut = ""
    private var storedError = ""

    var out: String {
        lock.lock()
        defer { lock.unlock() }
        return storedOut
    }

    var err: String {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var output: ScanOutput {
        ScanOutput(
            standardOutput: { [self] text in
                lock.lock()
                storedOut += text
                lock.unlock()
            },
            standardError: { [self] text in
                lock.lock()
                storedError += text
                lock.unlock()
            }
        )
    }
}

/// An engine whose stream the test settles by hand.
final class ScriptedEngine: ScanEngine, @unchecked Sendable {
    private let events: [ScanEvent]

    init(events: [ScanEvent]) {
        self.events = events
    }

    func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
        let events = events
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    func cancel() async {}
}
