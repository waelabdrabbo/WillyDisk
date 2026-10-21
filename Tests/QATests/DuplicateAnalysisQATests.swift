import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies that a size match is only a candidate, and that contents decide
/// what is called a duplicate.
final class DuplicateAnalysisQATests: XCTestCase {

    private let megabyte: Int64 = 1_000_000
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateAnalysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSameSizeDifferentContentsAreNeverCalledDuplicates() throws {
        let first = try write("first.bin", byte: 0xAA, size: Int(megabyte) + 100_000)
        let second = try write("second.bin", byte: 0xBB, size: Int(megabyte) + 100_000)
        let copy = try write("copy.bin", byte: 0xAA, size: Int(megabyte) + 100_000)
        let group = sizeGroup([first, second, copy])

        let report = try XCTUnwrap(DuplicateHasher.check(groups: [group]))

        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.candidates.map(\.name), ["copy.bin", "first.bin"])
        XCTAssertEqual(report.comparedFileCount, 3)
        XCTAssertEqual(report.candidateFileCount, 3)
        XCTAssertEqual(report.unreadableFileCount, 0)
        XCTAssertFalse(report.groups.first?.candidates.contains { $0.name == "second.bin" } ?? true)
    }

    func testThreeIdenticalFilesBecomeOneGroup() throws {
        let first = try write("a.bin", byte: 0x11, size: Int(megabyte) + 12)
        let second = try write("b.bin", byte: 0x11, size: Int(megabyte) + 12)
        let third = try write("c.bin", byte: 0x11, size: Int(megabyte) + 12)
        let group = sizeGroup([first, second, third])

        let report = try XCTUnwrap(DuplicateHasher.check(groups: [group]))

        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.candidates.count, 3)
        XCTAssertEqual(report.groups.first?.totalLogicalSize,
                       3 * (megabyte + 12))
        XCTAssertEqual(report.groups.first?.candidates.map(\.name), ["a.bin", "b.bin", "c.bin"])
    }

    func testCancellingConfirmsNothing() throws {
        let first = try write("first.bin", byte: 0x01, size: Int(megabyte) + 1)
        let second = try write("second.bin", byte: 0x01, size: Int(megabyte) + 1)
        let group = sizeGroup([first, second])

        XCTAssertNil(DuplicateHasher.check(groups: [group], isCancelled: { true }))
    }

    func testAnUnreadableFileIsNotCalledADuplicate() throws {
        let first = try write("first.bin", byte: 0x22, size: Int(megabyte) + 1)
        let second = try write("second.bin", byte: 0x22, size: Int(megabyte) + 1)
        try FileManager.default.removeItem(at: second)
        let group = sizeGroup([first, second])

        let report = try XCTUnwrap(DuplicateHasher.check(groups: [group]))

        XCTAssertTrue(report.groups.isEmpty)
        XCTAssertEqual(report.comparedFileCount, 1)
        XCTAssertEqual(report.unreadableFileCount, 1)
        XCTAssertEqual(report.candidateFileCount, 2)
    }

    func testProgressCoversEveryCandidateAndFinishes() throws {
        let first = try write("first.bin", byte: 0x33, size: Int(megabyte) + 1)
        let second = try write("second.bin", byte: 0x33, size: Int(megabyte) + 1)
        let group = sizeGroup([first, second])
        let sink = ProgressSink()

        let report = try XCTUnwrap(DuplicateHasher.check(groups: [group], progress: sink.record))

        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(sink.last?.totalFiles, 2)
        XCTAssertEqual(sink.last?.completedFiles, 2)
        XCTAssertEqual(sink.last?.fraction, 1)
        XCTAssertEqual(sink.last?.totalBytes, 2 * (megabyte + 1))
    }

    @MainActor
    func testDuplicateCheckPublishesConfirmedGroups() async throws {
        let first = try write("first.bin", byte: 0x44, size: Int(megabyte) + 1)
        let second = try write("second.bin", byte: 0x44, size: Int(megabyte) + 1)
        let check = DuplicateCheck()

        check.start([sizeGroup([first, second])])

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .checked = check.state { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        guard case .checked(let report) = check.state else {
            return XCTFail("the check did not finish: \(check.state)")
        }
        XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(report.groups.first?.candidates.count, 2)
    }

    @MainActor
    func testCancellingDuplicateCheckLeavesItIdle() async throws {
        let first = try write("first.bin", byte: 0x55, size: Int(megabyte) + 1)
        let second = try write("second.bin", byte: 0x55, size: Int(megabyte) + 1)
        let check = DuplicateCheck()

        check.start([sizeGroup([first, second])])
        check.cancel()

        XCTAssertEqual(check.state, .idle)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(check.state, .idle, "a cancelled check must not publish a report later")
    }

    // MARK: - Fixtures

    private func write(_ name: String, byte: UInt8, size: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: byte, count: size).write(to: url)
        return url
    }

    private func sizeGroup(_ urls: [URL]) -> DuplicateSizeGroup {
        let nodes = urls.map(node)
        let size = nodes.first?.logicalSize ?? 0
        return DuplicateSizeGroup(
            logicalSize: size,
            candidates: nodes.map(CleanupCandidate.init),
            matchCount: nodes.count
        )
    }

    private func node(_ url: URL) -> ScanNode {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ScanNode(
            id: UUID(),
            url: url,
            name: url.lastPathComponent,
            isDirectory: false,
            isSymlink: false,
            category: .other,
            logicalSize: size,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }
}

/// Collects progress updates from the hashing thread without sharing mutable
/// state across actors.
private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [DuplicateHashProgress] = []

    func record(_ progress: DuplicateHashProgress) {
        lock.lock()
        updates.append(progress)
        lock.unlock()
    }

    var last: DuplicateHashProgress? {
        lock.lock()
        defer { lock.unlock() }
        return updates.last
    }
}
