import XCTest
import Foundation
import Darwin
@testable import DiskCore

/// A reproducible, opt-in check that the live arena built from a real scan
/// carries exactly what the scan measured, plus the cost of building it.
///
/// Skipped unless `WILLYDISK_BENCH_ROOT` is set, like `ScanBenchmarkTests`, so the
/// normal suite stays fast. It scans the root with the real engine, builds
/// `LiveTree` from the terminal summary, and prints one `LIVETREE` line with the
/// node count, the build time, and peak resident memory. The top directories the
/// scan ranked are then read back out of the arena and compared entry by entry,
/// which is the check that the arena and the measurement agree.
///
/// ```
/// WILLYDISK_BENCH_ROOT=/Applications swift test --filter LiveTreeBenchmarkTests
/// WILLYDISK_BENCH_ROOT=/ swift test --filter LiveTreeBenchmarkTests
/// ```
final class LiveTreeBenchmarkTests: XCTestCase {

    func testBuildsTheTreeFromARealScan() async throws {
        guard let root = ProcessInfo.processInfo.environment["WILLYDISK_BENCH_ROOT"], !root.isEmpty else {
            throw XCTSkip("set WILLYDISK_BENCH_ROOT to a folder to check a live tree against a real scan")
        }

        let engine = FileScanEngine()
        let request = ScanRequest(root: URL(fileURLWithPath: root, isDirectory: true))
        var summary: ScanSummary?
        for await event in engine.scan(request) {
            switch event {
            case .finished(let finished):
                summary = finished
            case .cancelled:
                XCTFail("the scan of \(root) was cancelled")
            case .started, .progress, .issue, .partial:
                break
            }
        }
        let measured = try XCTUnwrap(summary, "the scan produced no terminal summary")

        let started = ContinuousClock().now
        let tree = try XCTUnwrap(
            LiveTree(scanning: measured),
            "the arena disagreed with the scan it was built from"
        )
        let build = ContinuousClock().now - started

        XCTAssertEqual(tree.fileCount, measured.fileCount)
        XCTAssertEqual(tree.directoryCount, measured.directoryCount)
        XCTAssertEqual(tree.totalLogicalSize, measured.totalLogicalSize)
        XCTAssertEqual(tree.totalAllocatedSize, measured.totalAllocatedSize)
        XCTAssertEqual(tree.categorySizes(), measured.categoryBreakdown)

        // The scan's own ranking read back out of the arena: same paths, same
        // numbers, same order.
        for node in measured.largestDirectories.prefix(100) {
            guard let entry = tree.id(atPath: node.url.path).flatMap({ tree.entry(for: $0) }) else {
                let children = tree.children(of: LiveTree.rootID).map(\.name).sorted().prefix(25)
                print("LIVETREE MISSING path=\(node.url.path) rootChildren=\(children)")
                XCTFail("the tree does not hold \(node.url.path)")
                continue
            }
            XCTAssertEqual(entry.logicalSize, node.logicalSize, "bytes under \(node.url.path)")
            XCTAssertEqual(entry.allocatedSize, node.allocatedSize, "allocated bytes under \(node.url.path)")
            XCTAssertEqual(entry.fileCount, node.fileCount, "files under \(node.url.path)")
            XCTAssertEqual(entry.directoryCount, node.directoryCount, "folders under \(node.url.path)")
        }

        // The bounded cost of one change: re-listing the folder the scan found
        // busiest, and one edit applied to the tree.
        var relist = "n/a"
        if let busiest = measured.largestDirectories.first {
            let reader = DirectoryReader()
            var seconds: [Double] = []
            for _ in 0..<10 {
                let start = ContinuousClock().now
                _ = try? reader.read(path: busiest.url.path)
                seconds.append(Self.seconds(ContinuousClock().now - start))
            }
            relist = String(format: "%.2fms", seconds.min().map { $0 * 1_000 } ?? 0)
        }

        var edit = "n/a"
        let rootChildren = tree.children(of: LiveTree.rootID)
        if let file = rootChildren.first(where: { !$0.isDirectory }) {
            let start = ContinuousClock().now
            for step in 0..<10_000 {
                tree.apply([
                    .updateFile(
                        id: file.id,
                        logicalSize: Int64(step),
                        allocatedSize: Int64(step),
                        modifiedAt: nil,
                        category: file.category
                    ),
                ])
            }
            edit = String(format: "%.2fµs", Self.seconds(ContinuousClock().now - start) / 10_000 * 1_000_000)
        }

        // What a walk over every entry costs when a screen asks for a live
        // ranking or a whole-tree search.
        let walkStart = ContinuousClock().now
        var walked = 0
        var walkedBytes: Int64 = 0
        tree.walk { entry in
            walked += 1
            if entry.kind == .file { walkedBytes += entry.logicalSize }
            return .descend
        }
        let walk = ContinuousClock().now - walkStart
        XCTAssertEqual(walked, tree.nodeCount - 1, "a walk visits every entry below the root")
        XCTAssertEqual(walkedBytes, tree.totalLogicalSize, "and sums to the measured total")

        let nodesStart = ContinuousClock().now
        let walkedNodes = tree.walkNodes { _ in .descend }
        let nodesWalk = ContinuousClock().now - nodesStart
        XCTAssertEqual(walkedNodes, tree.nodeCount - 1)

        print(
            "LIVETREE root=\(root) nodes=\(tree.nodeCount) files=\(tree.fileCount) "
                + "dirs=\(tree.directoryCount) build=\(Self.format(build)) "
                + "resident=\(Self.residentMegabytes())MB relist=\(relist) edit=\(edit) "
                + "walk=\(Self.format(walk)) walkNodes=\(Self.format(nodesWalk))"
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// The same scan, with the walk filling the tree as it goes: the time a
    /// screen waits after the terminal event is the take, not a conversion.
    func testTheEngineBuildsTheTreeDuringTheScan() async throws {
        guard let root = ProcessInfo.processInfo.environment["WILLYDISK_BENCH_ROOT"], !root.isEmpty else {
            throw XCTSkip("set WILLYDISK_BENCH_ROOT to a folder to measure the walk-built tree")
        }

        let engine = FileScanEngine()
        let request = ScanRequest(root: URL(fileURLWithPath: root, isDirectory: true))
        let started = ContinuousClock().now
        var summary: ScanSummary?
        for await event in engine.scan(request, buildingLiveTree: true) {
            if case .finished(let finished) = event { summary = finished }
            if case .cancelled = event { XCTFail("the scan was cancelled") }
        }
        let scan = ContinuousClock().now - started

        let takeStarted = ContinuousClock().now
        let handed = await engine.takeLiveTree()
        let take = ContinuousClock().now - takeStarted

        let measured = try XCTUnwrap(summary)
        let tree = try XCTUnwrap(handed, "the walk should hand its tree over")
        XCTAssertTrue(tree.matches(measured))

        print(
            "LIVETREE engine root=\(root) scan=\(Self.format(scan)) "
                + "take=\(Self.format(take)) nodes=\(tree.nodeCount) "
                + "resident=\(Self.residentMegabytes())MB"
        )
    }

    private static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }

    private static func residentMegabytes() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) / 1_048_576
    }
}
