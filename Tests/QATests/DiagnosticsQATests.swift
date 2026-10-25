import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The diagnostics report as the app builds it: what a finished, stopped, or
/// running scan contributes, and what the report must never carry.
@MainActor
final class DiagnosticsQATests: XCTestCase {

    /// An engine whose stream the test settles by hand, so a report is built at
    /// the moment the test means to describe.
    private final class ControlledEngine: ScanEngine, @unchecked Sendable {
        private var continuations: [AsyncStream<ScanEvent>.Continuation] = []

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> {
            AsyncStream { continuation in
                continuations.append(continuation)
            }
        }

        func cancel() async {}

        func yield(_ event: ScanEvent) {
            continuations.last?.yield(event)
        }

        func finish(_ summary: ScanSummary) {
            yield(.finished(summary))
            continuations.last?.finish()
        }

        func stop(_ partial: ScanSummary?) {
            yield(.cancelled(partial: partial))
            continuations.last?.finish()
        }
    }

    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private var directory: URL!
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskDiagnosticsQATests-\(UUID().uuidString)")
        root = directory.appendingPathComponent("SentinelFolderName")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "DiagnosticsQATests-\(UUID().uuidString)"
        self.suite = suite
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        if let defaults, let suite {
            defaults.removePersistentDomain(forName: suite)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeSummary(
        finishedAt: Date? = nil,
        fileCount: Int = 42,
        errorCount: Int = 0,
        files: [ScanNode] = [],
        accounting: ScanAccounting = .zero
    ) -> ScanSummary {
        let finished = finishedAt ?? startedAt.addingTimeInterval(2.5)
        return ScanSummary(
            root: root,
            totalLogicalSize: 9_000_000,
            totalAllocatedSize: 9_500_000,
            fileCount: fileCount,
            directoryCount: 7,
            inaccessibleCount: 4,
            errorCount: errorCount,
            permissionDeniedCount: 3,
            surfacedIssueCount: 2,
            startedAt: startedAt,
            finishedAt: finished,
            categoryBreakdown: [.documents: 9_000_000],
            largestFiles: files,
            largestDirectories: [],
            rootChildren: [],
            accounting: accounting
        )
    }

    private func makeNode(name: String) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: root.appendingPathComponent(name),
            name: name,
            isDirectory: false,
            isSymlink: false,
            category: .documents,
            logicalSize: 1_000,
            allocatedSize: 1_000,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }

    private func makeViewModel(engine: ControlledEngine) -> ScanViewModel {
        ScanViewModel(engine: engine, optionsStore: ScanOptionsStore(defaults: defaults))
    }

    private func fixedFacts() -> DiagnosticsExport.AppFacts {
        DiagnosticsExport.AppFacts(
            name: "WillyDisk",
            version: "9.9.9",
            build: "4242",
            bundleIdentifier: "test.willydisk.fixture",
            operatingSystemVersion: "15.1.2",
            operatingSystemBuild: "24B83",
            architecture: "arm64",
            interfaceLanguage: "en"
        )
    }

    private func json(_ report: DiagnosticsExport.Report) throws -> [String: Any] {
        let data = try DiagnosticsExport.jsonData(for: report)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func scanSection(_ report: DiagnosticsExport.Report) throws -> [String: Any] {
        try XCTUnwrap(try json(report)["scan"] as? [String: Any])
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    // MARK: - A finished run

    func testFinishedReportCarriesSettingsTimingCountsAndVersion() async throws {
        let engine = ControlledEngine()
        let viewModel = makeViewModel(engine: engine)
        let options = ScanOptions(
            followSymlinks: true,
            stayOnVolume: false,
            includeHidden: false,
            excludedPaths: [
                directory.appendingPathComponent("First Exclusion"),
                directory.appendingPathComponent("Second Exclusion"),
            ]
        )
        viewModel.start(root: root, options: options)
        engine.finish(makeSummary(
            errorCount: 11,
            accounting: ScanAccounting(
                hardlinkFileCount: 2,
                hardlinkExtraLogicalSize: 4_096,
                datalessFileCount: 1,
                excludedItemCount: 9
            )
        ))
        let settled = await waitUntil { viewModel.phase == .finished }
        XCTAssertTrue(settled, "the finished summary should settle the screen")

        let report = DiagnosticsExport.makeReport(for: viewModel, now: startedAt, app: fixedFacts())
        let document = try json(report)
        XCTAssertEqual(document["schemaVersion"] as? Int, DiagnosticsExport.schemaVersion)

        let app = try XCTUnwrap(document["app"] as? [String: Any])
        XCTAssertEqual(app["name"] as? String, "WillyDisk")
        XCTAssertEqual(app["version"] as? String, "9.9.9")
        XCTAssertEqual(app["build"] as? String, "4242")
        XCTAssertEqual(app["bundleIdentifier"] as? String, "test.willydisk.fixture")
        XCTAssertEqual(app["operatingSystemVersion"] as? String, "15.1.2")
        XCTAssertEqual(app["operatingSystemBuild"] as? String, "24B83")
        XCTAssertEqual(app["architecture"] as? String, "arm64")
        XCTAssertEqual(app["interfaceLanguage"] as? String, "en")

        let scan = try scanSection(report)
        XCTAssertEqual(scan["state"] as? String, "finished")
        XCTAssertNil(scan["failureReason"])

        let choices = try XCTUnwrap(scan["options"] as? [String: Any])
        XCTAssertEqual(choices["followSymlinks"] as? Bool, true)
        XCTAssertEqual(choices["stayOnVolume"] as? Bool, false)
        XCTAssertEqual(choices["includeHidden"] as? Bool, false)
        XCTAssertEqual(choices["excludedPathCount"] as? Int, 2, "the count, not the paths")

        let timing = try XCTUnwrap(scan["timing"] as? [String: Any])
        XCTAssertEqual(timing["source"] as? String, "finishedSummary")
        XCTAssertEqual(timing["startedAt"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(timing["finishedAt"] as? String, "2023-11-14T22:13:22Z")
        XCTAssertEqual(timing["elapsedSeconds"] as? Double, 2.5)

        let totals = try XCTUnwrap(scan["totals"] as? [String: Any])
        XCTAssertEqual(totals["fileCount"] as? Int, 42)
        XCTAssertEqual(totals["directoryCount"] as? Int, 7)
        XCTAssertEqual(totals["logicalSize"] as? Int64, 9_000_000)
        XCTAssertEqual(totals["allocatedSize"] as? Int64, 9_500_000)

        let issues = try XCTUnwrap(scan["issueCounts"] as? [String: Any])
        XCTAssertEqual(issues["errorCount"] as? Int, 11)
        XCTAssertEqual(issues["inaccessibleCount"] as? Int, 4)
        XCTAssertEqual(issues["permissionDeniedCount"] as? Int, 3)
        XCTAssertEqual(issues["surfacedIssueCount"] as? Int, 2)

        let accounting = try XCTUnwrap(scan["accounting"] as? [String: Any])
        XCTAssertEqual(accounting["hardlinkFileCount"] as? Int, 2)
        XCTAssertEqual(accounting["hardlinkExtraLogicalSize"] as? Int64, 4_096)
        XCTAssertEqual(accounting["datalessFileCount"] as? Int, 1)
        XCTAssertEqual(accounting["excludedItemCount"] as? Int, 9)
    }

    // MARK: - Privacy

    func testReportCarriesNoFileNamePathOrExcludedLocation() async throws {
        let engine = ControlledEngine()
        let viewModel = makeViewModel(engine: engine)
        let excluded = directory.appendingPathComponent("SentinelExcludedVault")
        let fileName = "SentinelFileNameQWERTY"
        let issuePath = "/SentinelIssuePath/Secret"
        let issueMessage = "SentinelIssueMessage"

        viewModel.start(root: root, options: ScanOptions(excludedPaths: [excluded]))
        engine.yield(.issue(kind: .permissionDenied, path: issuePath, message: issueMessage))
        engine.finish(makeSummary(files: [makeNode(name: fileName)]))
        let settled = await waitUntil { viewModel.phase == .finished }
        XCTAssertTrue(settled)

        let text = try XCTUnwrap(
            String(
                data: DiagnosticsExport.jsonData(for: DiagnosticsExport.makeReport(for: viewModel)),
                encoding: .utf8
            )
        )
        for secret in [
            root.lastPathComponent,
            fileName,
            excluded.lastPathComponent,
            "SentinelIssuePath",
            "Secret",
            issueMessage,
        ] {
            XCTAssertFalse(text.contains(secret), "the diagnostics report leaked \(secret)")
        }
        XCTAssertFalse(text.contains("\"path\""), "the report has no path field")
        XCTAssertFalse(text.contains("\"largestFiles\""), "the report does not carry the ranked tree")
    }

    // MARK: - A stopped or running run

    func testCancelledReportNamesItsSnapshotAndKeepsTheMeasuredTotals() async throws {
        let engine = ControlledEngine()
        let viewModel = makeViewModel(engine: engine)
        viewModel.start(root: root)
        engine.stop(makeSummary(finishedAt: startedAt.addingTimeInterval(1.25), fileCount: 12))
        let settled = await waitUntil { viewModel.phase == .cancelled }
        XCTAssertTrue(settled)

        let report = DiagnosticsExport.makeReport(for: viewModel, app: fixedFacts())
        let scan = try scanSection(report)
        XCTAssertEqual(scan["state"] as? String, "cancelled")
        let timing = try XCTUnwrap(scan["timing"] as? [String: Any])
        XCTAssertEqual(timing["source"] as? String, "cancelledSnapshot")
        XCTAssertEqual(timing["elapsedSeconds"] as? Double, 1.25)
        let totals = try XCTUnwrap(scan["totals"] as? [String: Any])
        XCTAssertEqual(totals["fileCount"] as? Int, 12, "the last snapshot is a measurement, not a projection")
    }

    func testRunningReportUsesTheLiveClockAndClaimsNoTotalsBeforeASnapshot() async throws {
        let engine = ControlledEngine()
        let viewModel = makeViewModel(engine: engine)
        viewModel.start(root: root)
        engine.yield(.progress(ScanProgress(
            currentPath: root.path,
            filesScanned: 30,
            directoriesScanned: 4,
            bytesScanned: 1_500_000,
            fractionCompleted: nil,
            elapsed: 4.5
        )))
        let progressed = await waitUntil { viewModel.progress != nil }
        XCTAssertTrue(progressed)

        let before = try scanSection(DiagnosticsExport.makeReport(for: viewModel, app: fixedFacts()))
        XCTAssertEqual(before["state"] as? String, "running")
        let timing = try XCTUnwrap(before["timing"] as? [String: Any])
        XCTAssertEqual(timing["source"] as? String, "liveProgress")
        XCTAssertEqual(timing["elapsedSeconds"] as? Double, 4.5)
        XCTAssertNotNil(timing["startedAt"])
        XCTAssertNil(before["totals"], "nothing has been snapshotted yet, so there is no total to report")
        XCTAssertNil(before["issueCounts"])

        engine.yield(.partial(makeSummary(finishedAt: startedAt.addingTimeInterval(5), fileCount: 30)))
        let snapshotted = await waitUntil { viewModel.partialSummary != nil }
        XCTAssertTrue(snapshotted)

        let after = try scanSection(DiagnosticsExport.makeReport(for: viewModel, app: fixedFacts()))
        XCTAssertEqual(after["state"] as? String, "running")
        let totals = try XCTUnwrap(after["totals"] as? [String: Any])
        XCTAssertEqual(totals["fileCount"] as? Int, 30)
        XCTAssertEqual((after["timing"] as? [String: Any])?["source"] as? String, "liveProgress")
    }

    // MARK: - Build facts

    func testBuildFactsComeFromTheBundle() throws {
        let bundleURL = directory.appendingPathComponent("Fixture.app")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleName": "WillyDisk",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "777",
            "CFBundleIdentifier": "test.willydisk.bundle",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let facts = DiagnosticsExport.AppFacts.current(bundle: bundle)
        XCTAssertEqual(facts.name, "WillyDisk")
        XCTAssertEqual(facts.version, "1.2.3")
        XCTAssertEqual(facts.build, "777")
        XCTAssertEqual(facts.bundleIdentifier, "test.willydisk.bundle")
        XCTAssertNotNil(facts.operatingSystemBuild, "the kernel build is readable on macOS")
        XCTAssertFalse(facts.operatingSystemVersion.isEmpty)
        XCTAssertTrue(["arm64", "x86_64", "unknown"].contains(facts.architecture))
    }
}
