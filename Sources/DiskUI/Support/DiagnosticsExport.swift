import Foundation
import UniformTypeIdentifiers
import DiskCore
import DiskLocalization

/// A support document about the scan on the engine's slot.
///
/// The report explains a scan — the choices it ran with, how long it took, how
/// much it measured, what it could not read, and the build that produced it.
/// It deliberately says nothing about the user's files: it carries no path, no
/// file name, no excluded location, and no file content. Counts stand in for
/// what was read, and the choices are booleans plus the number of exclusions.
/// Report export is the document that names paths, and it is a separate export
/// the user chooses.
@MainActor
public enum DiagnosticsExport {

    /// The layout this release writes. A later release that adds a section
    /// raises it, so a reader can tell the two apart.
    static let schemaVersion = 1

    // MARK: - Entry point

    /// Asks for a destination and writes the diagnostics JSON there.
    public static func export(from viewModel: ScanViewModel) {
        guard let data = try? jsonData(for: makeReport(for: viewModel)),
              let json = String(data: data, encoding: .utf8) else { return }
        ExportPanel.present(
            content: json,
            defaultName: L10n.string("WillyDisk Diagnostics.json"),
            contentType: .json,
            title: L10n.string("Export Diagnostics"),
            message: L10n.string("Includes scan settings, timing, issue counts, and version. No file names, paths, or contents are included."),
            failureDescription: { url, error in
                L10n.format("Could not write the diagnostics to %@: %@", url.lastPathComponent, error.localizedDescription)
            }
        )
    }

    // MARK: - Building

    /// The report the app writes, with the run on the slot as its subject.
    /// `now` and the build facts are injectable so a test can pin a report
    /// without depending on the host's build or clock.
    static func makeReport(
        for viewModel: ScanViewModel,
        now: Date = .now,
        app: AppFacts = .current()
    ) -> Report {
        Report(
            schemaVersion: schemaVersion,
            generatedAt: now,
            app: app,
            scan: makeScan(for: viewModel)
        )
    }

    static func jsonData(for report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private static func makeScan(for viewModel: ScanViewModel) -> ScanFacts {
        let measured = measuredSummary(of: viewModel)
        return ScanFacts(
            state: state(of: viewModel),
            failureReason: failureReason(of: viewModel.phase),
            options: Choices(viewModel.lastOptions),
            timing: timing(for: viewModel, measured: measured),
            totals: measured.map(Totals.init),
            issueCounts: measured.map(IssueCounts.init),
            accounting: measured.map { Accounting($0.accounting) }
        )
    }

    /// The measurement the report may describe, if there is one: the finished
    /// run, or the newest snapshot a running one has produced — counted work,
    /// never a projection.
    private static func measuredSummary(of viewModel: ScanViewModel) -> ScanSummary? {
        switch viewModel.phase {
        case .finished, .cancelled:
            return viewModel.summary
        case .scanning:
            return viewModel.partialSummary
        case .idle, .failed:
            return nil
        }
    }

    private static func state(of viewModel: ScanViewModel) -> String {
        switch viewModel.phase {
        case .idle: return "idle"
        case .scanning: return "running"
        // A finished run whose tree is installed is being kept current, which is
        // what the report's numbers describe.
        case .finished: return viewModel.liveTree == nil ? "finished" : "live"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }

    private static func failureReason(of phase: ScanViewModel.Phase) -> String? {
        guard case .failed(let reason) = phase else { return nil }
        return reason
    }

    /// What the report can honestly say about time, and which measurement it
    /// came from: a finished run's own endpoints, the last snapshot a stopped
    /// run produced, the engine's live clock, or only the moment the scan began.
    private static func timing(for viewModel: ScanViewModel, measured: ScanSummary?) -> Timing {
        switch viewModel.phase {
        case .finished:
            guard let measured else { return startTiming(for: viewModel) }
            return summaryTiming(measured, source: "finishedSummary")
        case .cancelled:
            guard let measured else { return startTiming(for: viewModel) }
            return summaryTiming(measured, source: "cancelledSnapshot")
        case .scanning:
            guard let startedAt = viewModel.scanStartedAt else {
                return Timing(source: "none", startedAt: nil, finishedAt: nil, elapsedSeconds: nil)
            }
            guard let elapsed = viewModel.progress?.elapsed else {
                return Timing(source: "scanStart", startedAt: startedAt, finishedAt: nil, elapsedSeconds: nil)
            }
            return Timing(
                source: "liveProgress",
                startedAt: startedAt,
                finishedAt: nil,
                elapsedSeconds: seconds(elapsed)
            )
        case .idle, .failed:
            return Timing(source: "none", startedAt: nil, finishedAt: nil, elapsedSeconds: nil)
        }
    }

    private static func summaryTiming(_ summary: ScanSummary, source: String) -> Timing {
        Timing(
            source: source,
            startedAt: summary.startedAt,
            finishedAt: summary.finishedAt,
            elapsedSeconds: seconds(summary.finishedAt.timeIntervalSince(summary.startedAt))
        )
    }

    private static func startTiming(for viewModel: ScanViewModel) -> Timing {
        guard let startedAt = viewModel.scanStartedAt else {
            return Timing(source: "none", startedAt: nil, finishedAt: nil, elapsedSeconds: nil)
        }
        return Timing(source: "scanStart", startedAt: startedAt, finishedAt: nil, elapsedSeconds: nil)
    }

    /// Whole milliseconds: enough to read a scan's duration, without presenting
    /// sub-millisecond noise as precision the measurement has.
    private static func seconds(_ interval: TimeInterval) -> Double {
        max(0, (interval * 1000).rounded() / 1000)
    }

    // MARK: - Report shape

    struct Report: Encodable {
        let schemaVersion: Int
        let generatedAt: Date
        let app: AppFacts
        let scan: ScanFacts
    }

    /// The build and environment that produced the report. The app's name and
    /// version come from its bundle, so the report never disagrees with About.
    struct AppFacts: Encodable {
        let name: String
        let version: String?
        let build: String?
        let bundleIdentifier: String?
        let operatingSystemVersion: String
        let operatingSystemBuild: String?
        let architecture: String
        let interfaceLanguage: String

        static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> AppFacts {
            let system = processInfo.operatingSystemVersion
            return AppFacts(
                name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "WillyDisk",
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                bundleIdentifier: bundle.bundleIdentifier,
                operatingSystemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                operatingSystemBuild: kernelBuild(),
                architecture: architecture,
                interfaceLanguage: L10n.language
            )
        }

        private static func kernelBuild() -> String? {
            var size = 0
            guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var value = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.osversion", &value, &size, nil, 0) == 0 else { return nil }
            let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let build = String(decoding: bytes, as: UTF8.self)
            return build.isEmpty ? nil : build
        }

        #if arch(arm64)
        private static let architecture = "arm64"
        #elseif arch(x86_64)
        private static let architecture = "x86_64"
        #else
        private static let architecture = "unknown"
        #endif
    }

    struct ScanFacts: Encodable {
        /// One of `idle`, `running`, `refreshing`, `finished`, `cancelled`, or
        /// `failed` — the slot's state, so a report says whether its totals are a
        /// final measurement, a snapshot, or an older run still on screen.
        let state: String
        let failureReason: String?
        let options: Choices
        let timing: Timing
        let totals: Totals?
        let issueCounts: IssueCounts?
        let accounting: Accounting?
    }

    /// The choices the run was started with. Exclusions are a count, never the
    /// paths themselves.
    struct Choices: Encodable {
        let followSymlinks: Bool
        let stayOnVolume: Bool
        let includeHidden: Bool
        let excludedPathCount: Int

        init(_ options: ScanOptions) {
            followSymlinks = options.followSymlinks
            stayOnVolume = options.stayOnVolume
            includeHidden = options.includeHidden
            excludedPathCount = options.excludedPaths.count
        }
    }

    struct Timing: Encodable {
        /// Which measurement the endpoints and elapsed time describe:
        /// `finishedSummary`, `cancelledSnapshot`, `liveProgress`, `scanStart`
        /// (the moment a scan began, with no elapsed time yet), or `none`.
        let source: String
        let startedAt: Date?
        let finishedAt: Date?
        let elapsedSeconds: Double?
    }

    struct Totals: Encodable {
        let fileCount: Int
        let directoryCount: Int
        let logicalSize: Int64
        let allocatedSize: Int64

        init(_ summary: ScanSummary) {
            fileCount = summary.fileCount
            directoryCount = summary.directoryCount
            logicalSize = summary.totalLogicalSize
            allocatedSize = summary.totalAllocatedSize
        }
    }

    struct IssueCounts: Encodable {
        let errorCount: Int
        let inaccessibleCount: Int
        let permissionDeniedCount: Int
        let surfacedIssueCount: Int

        init(_ summary: ScanSummary) {
            errorCount = summary.errorCount
            inaccessibleCount = summary.inaccessibleCount
            permissionDeniedCount = summary.permissionDeniedCount
            surfacedIssueCount = summary.surfacedIssueCount
        }
    }

    struct Accounting: Encodable {
        let hardlinkFileCount: Int
        let hardlinkExtraLogicalSize: Int64
        let hardlinkExtraAllocatedSize: Int64
        let datalessFileCount: Int
        let datalessLogicalSize: Int64
        let datalessAllocatedSize: Int64
        let skippedSymlinkCount: Int
        let skippedVolumeCount: Int
        let specialFileCount: Int
        let excludedItemCount: Int

        init(_ accounting: ScanAccounting) {
            hardlinkFileCount = accounting.hardlinkFileCount
            hardlinkExtraLogicalSize = accounting.hardlinkExtraLogicalSize
            hardlinkExtraAllocatedSize = accounting.hardlinkExtraAllocatedSize
            datalessFileCount = accounting.datalessFileCount
            datalessLogicalSize = accounting.datalessLogicalSize
            datalessAllocatedSize = accounting.datalessAllocatedSize
            skippedSymlinkCount = accounting.skippedSymlinkCount
            skippedVolumeCount = accounting.skippedVolumeCount
            specialFileCount = accounting.specialFileCount
            excludedItemCount = accounting.excludedItemCount
        }
    }
}
