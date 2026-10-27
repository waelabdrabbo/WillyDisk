import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// An opt-in measurement of what a whole-tree search costs on a real folder.
///
/// A search walks every entry of the tree, and a home folder is millions of
/// them, so this cost is what decides whether the field answers or spins. It is
/// also the check behind the walk's shape: the comparison against a name runs
/// once per entry, a path query carries each entry's path from the walk instead
/// of asking the tree for it, and both are measured here rather than assumed.
/// Skipped unless `WILLYDISK_BENCH_ROOT` is set, like the engine's benchmarks.
///
/// ```
/// WILLYDISK_BENCH_ROOT=~ swift test -c release --filter SearchBenchmarkTests
/// WILLYDISK_BENCH_ROOT=/Applications swift test -c release --filter SearchBenchmarkTests
/// ```
///
/// `WILLYDISK_BENCH_MAX_SEARCH_S` is optional: when set, the benchmark fails if a
/// query takes longer than that many seconds, which holds a real folder to the
/// search's own 4 s re-walk interval.
///
/// Measure in release: the comparison and the path walk are this target's own
/// code, and a debug build times the unoptimized loop instead of the search.
final class SearchBenchmarkTests: XCTestCase {

    func testWholeTreeSearchCost() async throws {
        guard let root = ProcessInfo.processInfo.environment["WILLYDISK_BENCH_ROOT"], !root.isEmpty else {
            throw XCTSkip("set WILLYDISK_BENCH_ROOT to a folder to measure a whole-tree search")
        }

        let engine = FileScanEngine()
        let request = ScanRequest(root: URL(fileURLWithPath: root, isDirectory: true))
        for await event in engine.scan(request, buildingLiveTree: true) {
            if case .cancelled = event { XCTFail("the scan of \(root) was cancelled") }
        }
        let handed = await engine.takeLiveTree()
        let tree = try XCTUnwrap(handed, "the walk should hand its tree over")

        let name = try measure("library", in: tree, root: root)
        let path = try measure("Library/", in: tree, root: root)

        // A path query answers over the same entries a name query does; only the
        // text it matches differs. Both are capped at the same point, so a tree
        // under the cap visits all of it either way.
        XCTAssertEqual(name.visitedCount, path.visitedCount)
    }

    private func measure(
        _ query: String,
        in tree: LiveTree,
        root: String
    ) throws -> ScanSearchResults {
        let started = ContinuousClock().now
        let results = try XCTUnwrap(ScanSearch.results(for: query, in: tree))
        let elapsed = Self.seconds(ContinuousClock().now - started)
        XCTAssertEqual(results.query, query)

        print(
            "SEARCH root=\(root) nodes=\(tree.nodeCount) query=\(query) "
                + "seconds=\(String(format: "%.2f", elapsed)) "
                + "visited=\(results.visitedCount) matches=\(results.matchCount) "
                + "stopped=\(results.stoppedAtLimit)"
        )

        // The search re-walks an open query every 4 s, so a walk that takes longer
        // than that cannot finish one: it is replaced before it lands. This is the
        // check that a search of a real folder stays inside that budget, which is
        // what `WILLYDISK_BENCH_MAX_SEARCH_S` is for; it never runs in CI.
        if let limitText = ProcessInfo.processInfo.environment["WILLYDISK_BENCH_MAX_SEARCH_S"],
           let limit = Double(limitText) {
            XCTAssertLessThanOrEqual(
                elapsed,
                limit,
                "the search of \(root) for “\(query)” took longer than \(limit)s"
            )
        }
        return results
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
