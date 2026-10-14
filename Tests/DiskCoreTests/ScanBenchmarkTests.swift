import XCTest
import Foundation
import Darwin
@testable import DiskCore

/// A reproducible, opt-in benchmark for the scanning engine.
///
/// It is skipped unless `WILLYDISK_BENCH_ROOT` is set, so it never slows the
/// normal `swift test` run. It drives the real `FileScanEngine` end to end —
/// detached task, `.partial` snapshots, `.progress`, issue surfacing and the
/// terminal event — and prints one machine-readable `BENCH` line with the
/// wall-clock time, the totals, the issue counts and peak resident memory.
///
/// ## Running it
///
/// ```
/// # whole data volume as seen through /  (Full Disk Access recommended)
/// WILLYDISK_BENCH_ROOT=/ WILLYDISK_BENCH_LABEL=disk \
///   swift test --filter ScanBenchmarkTests
///
/// # the home folder
/// WILLYDISK_BENCH_ROOT="$HOME" WILLYDISK_BENCH_LABEL=home \
///   swift test --filter ScanBenchmarkTests
/// ```
///
/// ## Conditions to record with a result
///
/// - the exact `WILLYDISK_BENCH_ROOT` and label,
/// - whether the process had Full Disk Access (`permissionDeniedCount` in the
///   `BENCH` line reveals an under-privileged run: a large non-zero value means
///   protected locations were skipped),
/// - cache state: this harness cannot drop the unified buffer cache, so runs are
///   warm unless the machine was rebooted or the cache purged. State it either
///   way, and compare like with like.
///
/// Optional knobs: `WILLYDISK_BENCH_REPEAT` (default 1) runs the scan that many
/// times and reports every run plus the minimum, which is the number to quote
/// for a warm cache. `WILLYDISK_BENCH_STAY_ON_VOLUME` (default 1) maps to
/// `ScanRequest.stayOnVolume`. `WILLYDISK_BENCH_CONCURRENCY` overrides the number
/// of traversal workers (default: the engine's own choice).
/// `WILLYDISK_BENCH_TOP` prints the N largest directories, which is how two runs
/// of the same root are compared entry by entry.
///
/// ## Comparing against another analyzer
///
/// A GUI analyzer has to be timed by hand: start its whole-disk scan, record the
/// duration it reports, and run this harness on the same root immediately before
/// or after so both see the same cache state. Record whether each process had
/// Full Disk Access — a scan without it silently skips protected locations, which
/// shows up here as a large `permission_denied` count.
///
/// `du`/`find` are a useful floor: they walk the same tree with minimal per-entry
/// overhead, so the gap between them and this harness is the engine's own cost.
/// ```
/// time du -sk "$HOME"      # allocated bytes, single-threaded
/// time find "$HOME" -xdev | wc -l
/// ```
final class ScanBenchmarkTests: XCTestCase {

    func testBenchmarkScan() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let rootPath = env["WILLYDISK_BENCH_ROOT"], !rootPath.isEmpty else {
            throw XCTSkip("set WILLYDISK_BENCH_ROOT to run the scan benchmark")
        }

        let label = env["WILLYDISK_BENCH_LABEL"] ?? rootPath
        let repeatCount = max(1, Int(env["WILLYDISK_BENCH_REPEAT"] ?? "1") ?? 1)
        let stayOnVolume = (env["WILLYDISK_BENCH_STAY_ON_VOLUME"] ?? "1") != "0"
        let concurrency = Int(env["WILLYDISK_BENCH_CONCURRENCY"] ?? "") ?? FileScanner.defaultConcurrency
        let topCount = Int(env["WILLYDISK_BENCH_TOP"] ?? "0") ?? 0
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)

        var best = TimeInterval.greatestFiniteMagnitude
        for run in 1...repeatCount {
            let sample = try await measureScan(
                ScanRequest(root: root, stayOnVolume: stayOnVolume),
                concurrency: concurrency,
                topCount: topCount
            )
            best = min(best, sample.wall)
            print(format(sample, label: label, run: run, repeatCount: repeatCount, concurrency: concurrency))
            for node in sample.topDirectories {
                print("BENCH-TOPDIR label=\(label) logical=\(node.logicalSize) allocated=\(node.allocatedSize) files=\(node.fileCount) dirs=\(node.directoryCount) path=\(node.url.path)")
            }
        }

        print("BENCH-BEST label=\(label) repeat=\(repeatCount) concurrency=\(concurrency) wall_s=\(format(best))")
    }

    // MARK: - Measurement

    private struct Sample {
        var wall: TimeInterval = 0
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var files = 0
        var directories = 0
        var errorCount = 0
        var inaccessibleCount = 0
        var permissionDeniedCount = 0
        var surfacedIssueCount = 0
        var partials = 0
        var progressEvents = 0
        var peakResidentBytes: UInt64 = 0
        var finished = false
        var topDirectories: [ScanNode] = []
    }

    private func measureScan(_ request: ScanRequest, concurrency: Int, topCount: Int) async throws -> Sample {
        let engine = FileScanEngine(concurrency: concurrency)
        var sample = Sample()
        var baselineResident = residentBytes()

        let clock = ContinuousClock()
        let start = clock.now
        for await event in engine.scan(request) {
            switch event {
            case .finished(let summary):
                sample.finished = true
                apply(summary, to: &sample)
                sample.topDirectories = Array(summary.largestDirectories.prefix(topCount))
            case .cancelled:
                sample.finished = false
            case .partial:
                sample.partials += 1
            case .progress:
                sample.progressEvents += 1
            case .started, .issue:
                break
            }
            baselineResident = max(baselineResident, residentBytes())
        }
        sample.wall = start.duration(to: clock.now).seconds
        sample.peakResidentBytes = baselineResident

        XCTAssertTrue(sample.finished, "the benchmark scan must run to completion")
        return sample
    }

    private func apply(_ summary: ScanSummary, to sample: inout Sample) {
        sample.logical = summary.totalLogicalSize
        sample.allocated = summary.totalAllocatedSize
        sample.files = summary.fileCount
        sample.directories = summary.directoryCount
        sample.errorCount = summary.errorCount
        sample.inaccessibleCount = summary.inaccessibleCount
        sample.permissionDeniedCount = summary.permissionDeniedCount
        sample.surfacedIssueCount = summary.surfacedIssueCount
    }

    private func format(_ sample: Sample, label: String, run: Int, repeatCount: Int, concurrency: Int) -> String {
        """
        BENCH label=\(label) run=\(run)/\(repeatCount) concurrency=\(concurrency) wall_s=\(format(sample.wall)) \
        files=\(sample.files) dirs=\(sample.directories) \
        logical_gib=\(format(Double(sample.logical) / 1_073_741_824)) \
        allocated_gib=\(format(Double(sample.allocated) / 1_073_741_824)) \
        errors=\(sample.errorCount) inaccessible=\(sample.inaccessibleCount) \
        permission_denied=\(sample.permissionDeniedCount) surfaced=\(sample.surfacedIssueCount) \
        partials=\(sample.partials) progress=\(sample.progressEvents) \
        peak_rss_mib=\(format(Double(sample.peakResidentBytes) / 1_048_576))
        """
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Process memory

    /// Peak resident memory observed so far, in bytes.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
