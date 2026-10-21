import Foundation
import DiskCore

/// Turns a finished scan into the two things the command line can print: a
/// short human report and the versioned record the app's history stores.
///
/// Both are derived from the same `ScanSummary` the engine reports. Nothing is
/// recomputed or estimated here; the only choice the report makes is order.
/// The engine ranks by size, and equal sizes can arrive in any order from a
/// concurrent walk, so every list is re-sorted by size and then by path. That
/// makes two runs of an unchanged folder print the same bytes.
public enum ScanReport {

    // MARK: - Text report

    public static func text(for summary: ScanSummary, command: ScanCommand) -> String {
        var lines: [String] = []

        lines.append("WillyDisk scan")
        lines.append("  Location   \(summary.root.standardizedFileURL.path)")
        lines.append("  Logical    \(size(summary.totalLogicalSize)) (\(summary.totalLogicalSize.formatted()) bytes)")
        lines.append("  On disk    \(size(summary.totalAllocatedSize)) (\(summary.totalAllocatedSize.formatted()) bytes)")
        lines.append("  Files      \(summary.fileCount.formatted())")
        lines.append("  Folders    \(summary.directoryCount.formatted())")
        lines.append("  Issues     \(issues(summary))")
        lines.append("  Options    hidden items included, stays on this volume, symbolic links not followed")

        if let root = rootNode(in: summary) {
            lines.append("")
            lines.append(folderHeading(command))
            append(folder: root, named: root.url.standardizedFileURL.path, level: 0, command, into: &lines)
        }

        let files = ordered(summary.largestFiles).prefix(command.top)
        lines.append("")
        lines.append("Largest files (\(files.count.formatted()))")
        if files.isEmpty {
            lines.append("  (none)")
        }
        for file in files {
            lines.append("  \(size(file.logicalSize))  \(file.url.standardizedFileURL.path)")
        }

        let categories = summary.categoryBreakdown
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value
                    ? lhs.key.rawValue < rhs.key.rawValue
                    : lhs.value > rhs.value
            }
            .prefix(command.top)
        lines.append("")
        lines.append("By category (\(categories.count.formatted()))")
        if categories.isEmpty {
            lines.append("  (nothing measured)")
        }
        for (category, bytes) in categories {
            lines.append("  \(size(bytes))  \(category.rawValue.capitalized)")
        }

        appendAccounting(summary.accounting, into: &lines)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func issues(_ summary: ScanSummary) -> String {
        guard summary.permissionDeniedCount > 0 else {
            return summary.errorCount.formatted()
        }
        return "\(summary.errorCount.formatted()) (\(summary.permissionDeniedCount.formatted()) permission denied)"
    }

    private static func folderHeading(_ command: ScanCommand) -> String {
        guard command.depth > 0 else { return "Folders (root only)" }
        let levels = command.depth == 1 ? "1 level" : "\(command.depth.formatted()) levels"
        return "Folders (\(levels), \(command.top.formatted()) per level)"
    }

    private static func append(
        folder: ScanNode,
        named name: String,
        level: Int,
        _ command: ScanCommand,
        into lines: inout [String]
    ) {
        let indent = String(repeating: "  ", count: level)
        lines.append("\(indent)\(size(folder.logicalSize))  \(name)")
        guard level < command.depth else { return }

        let children = ordered(folder.children).filter(\.isDirectory)
        for child in children.prefix(command.top) {
            append(folder: child, named: child.name, level: level + 1, command, into: &lines)
        }
        let hidden = children.count - min(children.count, command.top)
        if hidden > 0 {
            let childIndent = String(repeating: "  ", count: level + 1)
            lines.append("\(childIndent)+ \(hidden.formatted()) more \(hidden == 1 ? "folder" : "folders")")
        }
    }

    private static func appendAccounting(_ accounting: ScanAccounting, into lines: inout [String]) {
        guard accounting.hasFindings else { return }
        lines.append("")
        lines.append("Accounting")

        if accounting.hardlinkFileCount > 0 {
            lines.append(
                "  Hard links  \(count(accounting.hardlinkFileCount, "file", "files")) with more than one link;"
                    + " \(size(accounting.hardlinkExtraLogicalSize)) of the total counted twice"
            )
        }
        if accounting.datalessFileCount > 0 {
            lines.append(
                "  Dataless    \(count(accounting.datalessFileCount, "file", "files"));"
                    + " \(size(accounting.datalessLogicalSize)) of logical size lives in the cloud"
            )
        }

        var skipped: [String] = []
        if accounting.skippedSymlinkCount > 0 {
            skipped.append(count(accounting.skippedSymlinkCount, "symbolic link", "symbolic links"))
        }
        if accounting.skippedVolumeCount > 0 {
            skipped.append(count(accounting.skippedVolumeCount, "volume", "volumes"))
        }
        if accounting.specialFileCount > 0 {
            skipped.append(count(accounting.specialFileCount, "special file", "special files"))
        }
        if !skipped.isEmpty {
            lines.append("  Skipped     \(skipped.joined(separator: ", "))")
        }
        if accounting.excludedItemCount > 0 {
            lines.append(
                "  Exclusions  \(count(accounting.excludedItemCount, "entry", "entries")) left out;"
                    + " their contents are not in the totals"
            )
        }
    }

    // MARK: - Record

    /// The finished run as the versioned DTO history stores.
    ///
    /// The record keeps the engine's ranked-list capacity, not `--top`: the
    /// record says what the scan measured, and the command's print width has no
    /// business narrowing what a later comparison can read.
    public static func record(
        for summary: ScanSummary,
        command: ScanCommand
    ) -> ScanRecord {
        let request = ScanRequest(root: command.root)
        return ScanRecord(
            rootPath: summary.root.standardizedFileURL.path,
            startedAt: summary.startedAt,
            finishedAt: summary.finishedAt,
            totalLogicalSize: summary.totalLogicalSize,
            totalAllocatedSize: summary.totalAllocatedSize,
            fileCount: summary.fileCount,
            directoryCount: summary.directoryCount,
            inaccessibleCount: summary.inaccessibleCount,
            errorCount: summary.errorCount,
            permissionDeniedCount: summary.permissionDeniedCount,
            surfacedIssueCount: summary.surfacedIssueCount,
            categorySizes: Dictionary(
                uniqueKeysWithValues: summary.categoryBreakdown.map { ($0.key.rawValue, $0.value) }
            ),
            largestFiles: ordered(summary.largestFiles).map(RecordedEntry.init),
            largestDirectories: ordered(summary.largestDirectories).map(RecordedEntry.init),
            entryCapacity: ScanRecord.currentEntryCapacity,
            accounting: RecordedAccounting(summary.accounting),
            options: RecordedOptions(
                followSymlinks: request.followSymlinks,
                stayOnVolume: request.stayOnVolume,
                includeHidden: request.includeHidden,
                excludedPaths: request.excludedPaths.map { $0.standardizedFileURL.path }
            ),
            volume: nil
        )
    }

    /// The record as the store writes it: pretty JSON with sorted keys and ISO
    /// 8601 dates. Sorted keys are what make two runs' output comparable byte
    /// for byte apart from the run's own identifier and timestamps.
    public static func json(_ record: ScanRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Shared

    /// The scan root's own node, present once the walk has finalized it.
    ///
    /// Matched by path rather than URL equality, because a node's URL records
    /// whether it is a directory and the request's need not. A finished
    /// directory scan always carries its root here: it is the largest folder the
    /// walk measured.
    public static func rootNode(in summary: ScanSummary) -> ScanNode? {
        let path = summary.root.standardizedFileURL.path
        return summary.largestDirectories.first { $0.url.standardizedFileURL.path == path }
    }

    /// Size first, path second, so equal-size siblings — which a concurrent walk
    /// may report in any order — print in one order every run.
    private static func ordered(_ nodes: [ScanNode]) -> [ScanNode] {
        nodes.sorted { lhs, rhs in
            lhs.logicalSize == rhs.logicalSize
                ? lhs.url.standardizedFileURL.path < rhs.url.standardizedFileURL.path
                : lhs.logicalSize > rhs.logicalSize
        }
    }

    private static func size(_ bytes: Int64) -> String {
        guard bytes != 0 else { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }
}
