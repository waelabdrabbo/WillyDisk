import XCTest
import Foundation
@testable import DiskCore

/// The scan-history store and the comparison over its records.
///
/// The store is the app's only long-lived file format, so these tests pin the
/// promises that keep it safe: a record written by this release reads back
/// unchanged, a file it cannot read is skipped rather than repaired or deleted,
/// the store stays bounded, and a comparison never invents an entry or a saving.
final class ScanHistoryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func store() -> ScanHistoryStore {
        ScanHistoryStore(directory: directory)
    }

    // MARK: - Fixtures

    private func entry(
        _ name: String,
        in folder: String = "/Users/me/Projects",
        size: Int64
    ) -> RecordedEntry {
        RecordedEntry(
            path: "\(folder)/\(name)",
            name: name,
            isDirectory: false,
            logicalSize: size,
            allocatedSize: size,
            modifiedAt: nil
        )
    }

    private func directoryEntry(
        _ name: String,
        in folder: String = "/Users/me/Projects",
        size: Int64
    ) -> RecordedEntry {
        RecordedEntry(
            path: "\(folder)/\(name)",
            name: name,
            isDirectory: true,
            logicalSize: size,
            allocatedSize: size,
            modifiedAt: nil
        )
    }

    private func record(
        root: String = "/Users/me/Projects",
        finishedDaysAgo: Double = 0,
        total: Int64 = 10_000_000,
        fileCount: Int = 10,
        categories: [String: Int64] = ["documents": 6_000_000, "images": 4_000_000],
        files: [RecordedEntry] = [],
        directories: [RecordedEntry] = [],
        options: RecordedOptions = RecordedOptions(
            followSymlinks: false,
            stayOnVolume: true,
            includeHidden: true,
            excludedPaths: []
        ),
        schemaVersion: Int = ScanRecord.currentSchemaVersion,
        entryCapacity: Int = ScanRecord.currentEntryCapacity,
        id: UUID = UUID()
    ) -> ScanRecord {
        let finished = Date(timeIntervalSince1970: 1_700_000_000 - finishedDaysAgo * 86_400)
        return ScanRecord(
            schemaVersion: schemaVersion,
            id: id,
            rootPath: root,
            startedAt: finished.addingTimeInterval(-12),
            finishedAt: finished,
            totalLogicalSize: total,
            totalAllocatedSize: total,
            fileCount: fileCount,
            directoryCount: 4,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            categorySizes: categories,
            largestFiles: files,
            largestDirectories: directories,
            entryCapacity: entryCapacity,
            accounting: RecordedAccounting(),
            options: options,
            volume: RecordedVolume(
                name: "Macintosh HD",
                mountPath: "/",
                totalCapacity: 500_000_000_000,
                availableCapacity: 200_000_000_000
            )
        )
    }

    // MARK: - Round trip

    func testRecordReadsBackUnchanged() throws {
        let original = record(
            finishedDaysAgo: 2,
            total: 12_345_678,
            categories: ["documents": 4_000_000, "other": 8_345_678],
            files: [entry("report.pdf", size: 2_400_000)],
            directories: [directoryEntry("Documents", size: 4_000_000)]
        )
        try store().save(original)

        let loaded = try XCTUnwrap(store().load().records.first)
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.categoryBreakdown[.documents], 4_000_000)
        XCTAssertEqual(loaded.root, URL(fileURLWithPath: "/Users/me/Projects"))
        XCTAssertEqual(loaded.volume?.name, "Macintosh HD")
    }

    func testLoadIsNewestFirst() throws {
        let history = store()
        try history.save(record(finishedDaysAgo: 8))
        try history.save(record(finishedDaysAgo: 1))
        try history.save(record(finishedDaysAgo: 4))

        let loaded = history.load().records
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.map(\.finishedAt), loaded.map(\.finishedAt).sorted(by: >))
    }

    func testMissingDirectoryIsAnEmptyHistory() {
        let missing = ScanHistoryStore(directory: directory.appendingPathComponent("never-written"))
        let snapshot = missing.load()
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertEqual(snapshot.skippedCount, 0)
    }

    // MARK: - Version and corruption

    func testUnknownSchemaVersionIsSkippedAndKept() throws {
        let history = store()
        try history.save(record())
        _ = try history.save(record(schemaVersion: ScanRecord.currentSchemaVersion + 1))

        let snapshot = history.load()
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.skippedCount, 1)

        // A record this release cannot read may belong to a newer one, so it is
        // left in place rather than cleaned up.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 2)
    }

    func testCorruptFileDegradesToTheRecordsThatStillRead() throws {
        try Data("not a scan record".utf8)
            .write(to: directory.appendingPathComponent("record-broken.json"))

        let history = store()
        try history.save(record(total: 7_000_000))

        let snapshot = history.load()
        XCTAssertEqual(snapshot.records.count, 1)
        XCTAssertEqual(snapshot.records.first?.totalLogicalSize, 7_000_000)
        XCTAssertEqual(snapshot.skippedCount, 1)
    }

    func testPruningKeepsTheNewestPerRoot() throws {
        let history = store()
        for index in 0..<(ScanHistoryStore.maxRecordsPerRoot + 4) {
            try history.save(record(finishedDaysAgo: Double(index)))
        }

        let snapshot = history.load()
        XCTAssertEqual(snapshot.records.count, ScanHistoryStore.maxRecordsPerRoot)
        // The four oldest runs fell off; the newest one is still there.
        let oldestKept = snapshot.records.last?.finishedAt
        let oldestWritten = Date(timeIntervalSince1970: 1_700_000_000 - Double(ScanHistoryStore.maxRecordsPerRoot + 3) * 86_400)
        XCTAssertNotNil(oldestKept)
        XCTAssertGreaterThan(oldestKept!, oldestWritten)
    }

    func testPruningKeepsTheNewestAcrossRoots() throws {
        let history = store()
        let perRoot = ScanHistoryStore.maxRecordsTotal / 5 + 2
        for rootIndex in 0..<5 {
            for index in 0..<perRoot {
                try history.save(record(
                    root: "/Users/me/Root\(rootIndex)",
                    finishedDaysAgo: Double(index) + Double(rootIndex) * 0.01
                ))
            }
        }

        let snapshot = history.load()
        XCTAssertEqual(snapshot.records.count, ScanHistoryStore.maxRecordsTotal)
    }

    func testPruningLeavesUnreadableFilesAlone() throws {
        let unreadable = directory.appendingPathComponent("record-unreadable.json")
        try Data("{".utf8).write(to: unreadable)

        let history = store()
        for index in 0..<(ScanHistoryStore.maxRecordsPerRoot + 3) {
            try history.save(record(finishedDaysAgo: Double(index)))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
        XCTAssertEqual(history.load().skippedCount, 1)
    }

    func testClearRemovesEverythingIncludingUnreadableRecords() throws {
        let history = store()
        try history.save(record())
        try Data("not a scan record".utf8)
            .write(to: directory.appendingPathComponent("record-broken.json"))

        try history.clear()

        XCTAssertTrue(history.load().records.isEmpty)
        XCTAssertEqual(history.load().skippedCount, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    // MARK: - Comparison

    func testTotalsAndCategoriesCompareExactly() {
        let earlier = record(
            finishedDaysAgo: 5,
            total: 10_000_000,
            fileCount: 10,
            categories: ["documents": 6_000_000, "images": 4_000_000]
        )
        let later = record(
            total: 13_000_000,
            fileCount: 12,
            categories: ["documents": 7_000_000, "images": 4_000_000, "video": 2_000_000]
        )

        let comparison = ScanComparison.between(earlier, later)
        XCTAssertEqual(comparison.totalLogicalDelta, 3_000_000)
        XCTAssertEqual(comparison.fileCountDelta, 2)
        XCTAssertEqual(comparison.directoryCountDelta, 0)

        let documents = comparison.categories.first { $0.category == .documents }
        XCTAssertEqual(documents?.change, .grown)
        XCTAssertEqual(documents?.delta, 1_000_000)

        let images = comparison.categories.first { $0.category == .images }
        XCTAssertEqual(images?.change, .unchanged)
        XCTAssertEqual(images?.delta, 0)

        let video = comparison.categories.first { $0.category == .video }
        XCTAssertEqual(video?.change, .new, "a category absent before and present now appeared")
        XCTAssertEqual(video?.earlier, 0)
    }

    func testEntriesAreMatchedByPathAndLabelled() {
        let earlier = record(
            finishedDaysAgo: 3,
            files: [
                entry("report.pdf", size: 2_000_000),
                entry("photo.jpg", size: 1_500_000),
                entry("same.txt", size: 500_000),
                entry("gone.zip", size: 900_000)
            ]
        )
        let later = record(
            files: [
                entry("report.pdf", size: 3_500_000),
                entry("photo.jpg", size: 1_000_000),
                entry("new.mov", size: 4_000_000),
                entry("same.txt", size: 500_000)
            ]
        )

        let comparison = ScanComparison.between(earlier, later)

        // Largest change first: new.mov is new at 4 MB, report.pdf grew 1.5 MB.
        XCTAssertEqual(comparison.files.map(\.name).prefix(4), ["new.mov", "report.pdf", "photo.jpg", "same.txt"])
        XCTAssertEqual(comparison.files[0].change, .new)
        XCTAssertNil(comparison.files[0].earlierSize)
        XCTAssertEqual(comparison.files[0].delta, 4_000_000)

        XCTAssertEqual(comparison.files[1].change, .grown)
        XCTAssertEqual(comparison.files[1].earlierSize, 2_000_000)
        XCTAssertEqual(comparison.files[1].delta, 1_500_000)

        XCTAssertEqual(comparison.files[2].change, .shrunk)
        XCTAssertEqual(comparison.files[2].delta, -500_000)

        XCTAssertEqual(comparison.files[3].change, .unchanged)
        XCTAssertEqual(comparison.files[3].delta, 0)

        XCTAssertEqual(comparison.droppedFileCount, 1, "gone.zip left the later list")
        XCTAssertEqual(comparison.changedFiles.count, 3)
    }

    func testComparisonOrdersRunsChronologicallyWhicheverWayItIsCalled() {
        let older = record(finishedDaysAgo: 10, total: 5_000_000)
        let newer = record(finishedDaysAgo: 1, total: 9_000_000)

        let forward = ScanComparison.between(older, newer)
        let reversed = ScanComparison.between(newer, older)

        XCTAssertEqual(forward.earlier.id, older.id)
        XCTAssertEqual(forward.later.id, newer.id)
        XCTAssertEqual(reversed.earlier.id, older.id)
        XCTAssertEqual(reversed.later.id, newer.id)
        XCTAssertEqual(forward.totalLogicalDelta, 4_000_000)
        XCTAssertEqual(reversed.totalLogicalDelta, 4_000_000)
    }

    func testDifferentOptionsAreDisclosed() {
        let sameOptions = ScanComparison.between(
            record(finishedDaysAgo: 2),
            record()
        )
        XCTAssertFalse(sameOptions.optionsDiffer)

        let changed = ScanComparison.between(
            record(finishedDaysAgo: 2),
            record(options: RecordedOptions(
                followSymlinks: false,
                stayOnVolume: true,
                includeHidden: false,
                excludedPaths: ["/Users/me/Projects/Archives"]
            ))
        )
        XCTAssertTrue(changed.optionsDiffer)
    }

    func testFullEarlierListReportsItsCutOff() {
        let fullList = (0..<ScanRecord.currentEntryCapacity).map {
            entry("file-\($0).bin", size: Int64(1_000_000 - $0 * 1_000))
        }
        XCTAssertEqual(ScanRecord.currentEntryCapacity, 100)

        let comparison = ScanComparison.between(
            record(
                finishedDaysAgo: 2,
                fileCount: ScanRecord.currentEntryCapacity + 1,
                files: fullList
            ),
            record(files: [entry("file-0.bin", size: 1_000_000)])
        )

        XCTAssertEqual(comparison.earlierFileCutOff, 901_000)
        XCTAssertEqual(comparison.droppedFileCount, ScanRecord.currentEntryCapacity - 1)
    }

    func testCutOffUsesTheCapacityTheRecordWasWrittenWith() {
        // A run recorded when the engine kept ten entries was full at ten, so its
        // smallest size is the cut-off, even though this release keeps more.
        let tenEntries = (0..<10).map { entry("file-\($0).bin", size: Int64(10_000 - $0 * 100)) }
        let smallCapacity = record(finishedDaysAgo: 2, fileCount: 11, files: tenEntries, entryCapacity: 10)
        let comparison = ScanComparison.between(
            smallCapacity,
            record(files: [entry("file-0.bin", size: 20_000)])
        )
        XCTAssertEqual(comparison.earlierFileCutOff, 9_100)

        // The same ten entries are a partial list for a capacity this release
        // never used, so they are not a cut-off.
        let largeCapacity = record(finishedDaysAgo: 2, fileCount: 11, files: tenEntries, entryCapacity: 500)
        XCTAssertNil(ScanComparison.between(largeCapacity, record(files: tenEntries)).earlierFileCutOff)
    }

    func testShortEarlierListHasNoCutOff() {
        let comparison = ScanComparison.between(
            record(finishedDaysAgo: 2, files: [entry("a.bin", size: 10)]),
            record(files: [entry("a.bin", size: 20), entry("b.bin", size: 5)])
        )
        XCTAssertNil(comparison.earlierFileCutOff, "the list held every entry it found")
        XCTAssertEqual(comparison.files.first { $0.name == "b.bin" }?.change, .new)
    }

    func testLaterEntryAtOrBelowAFullEarlierCutOffIsNotNew() {
        // The earlier run kept its ten largest files, down to 9,100 bytes. The
        // file below is absent from that list, but at its cut-off size it could
        // have been there without being recorded; losing the recorded entry lets
        // it into the later list. That is not evidence it is new.
        let earlierFiles = (0..<10).map { entry("file-\($0).bin", size: Int64(10_000 - $0 * 100)) }
        let laterFiles = Array(earlierFiles.dropLast()) + [entry("below-cutoff.bin", size: 9_100)]

        let comparison = ScanComparison.between(
            record(finishedDaysAgo: 2, fileCount: 11, files: earlierFiles, entryCapacity: 10),
            record(files: laterFiles, entryCapacity: 10)
        )

        XCTAssertEqual(comparison.earlierFileCutOff, 9_100)
        XCTAssertNil(comparison.files.first { $0.name == "below-cutoff.bin" })
        XCTAssertEqual(comparison.uncomparedFileCount, 1)
        XCTAssertTrue(comparison.changedFiles.isEmpty, "an unrecorded earlier entry is not a change")
        XCTAssertEqual(comparison.droppedFileCount, 1)
    }

    func testLaterEntryAboveAFullEarlierCutOffIsNew() {
        let earlierFiles = (0..<10).map { entry("file-\($0).bin", size: Int64(10_000 - $0 * 100)) }
        let laterFiles = Array(earlierFiles.dropLast()) + [entry("above-cutoff.bin", size: 9_101)]

        let comparison = ScanComparison.between(
            record(finishedDaysAgo: 2, fileCount: 11, files: earlierFiles, entryCapacity: 10),
            record(files: laterFiles, entryCapacity: 10)
        )

        let appeared = comparison.files.first { $0.name == "above-cutoff.bin" }
        XCTAssertEqual(appeared?.change, .new, "it outranks the earlier cut-off, so the earlier run would have listed it")
        XCTAssertEqual(appeared?.delta, 9_101)
        XCTAssertEqual(comparison.uncomparedFileCount, 0)
        XCTAssertEqual(comparison.changedFiles.count, 1)
    }

    func testExactlyFullEarlierListStillHeldEveryEntry() {
        // The run found exactly as many files as the list could hold, so a later
        // entry absent from it is new even though it is smaller than every entry
        // the earlier list recorded.
        let earlierFiles = (0..<10).map { entry("file-\($0).bin", size: Int64(10_000 - $0 * 100)) }
        let laterFiles = Array(earlierFiles.dropLast()) + [entry("appeared.bin", size: 5_000)]

        let comparison = ScanComparison.between(
            record(finishedDaysAgo: 2, fileCount: 10, files: earlierFiles, entryCapacity: 10),
            record(files: laterFiles, entryCapacity: 10)
        )

        XCTAssertNil(comparison.earlierFileCutOff, "the earlier list held every file the run found")
        XCTAssertEqual(comparison.files.first { $0.name == "appeared.bin" }?.change, .new)
        XCTAssertEqual(comparison.uncomparedFileCount, 0)
    }

    func testUnchangedRunsHaveNoChanges() {
        let directories = [directoryEntry("Documents", size: 4_000_000)]
        let files = [entry("report.pdf", size: 2_000_000)]
        let comparison = ScanComparison.between(
            record(finishedDaysAgo: 2, files: files, directories: directories),
            record(files: files, directories: directories)
        )

        XCTAssertFalse(comparison.hasChanges)
        XCTAssertTrue(comparison.changedFiles.isEmpty)
        XCTAssertEqual(comparison.files.first?.change, .unchanged)
    }
}
