import Foundation
import DiskCore
import DiskLocalization

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

        let topLabels = [
            L10n.string("Location"),
            L10n.string("Logical"),
            L10n.string("On disk"),
            L10n.string("Files"),
            L10n.string("Folders"),
            L10n.string("Issues"),
            L10n.string("Options"),
        ]
        let topWidth = labelWidth(topLabels, minimum: 11, gap: 3)

        lines.append(L10n.string("WillyDisk scan"))
        lines.append(row(topLabels[0], summary.root.standardizedFileURL.path, width: topWidth))
        lines.append(row(
            topLabels[1],
            L10n.format(
                "%@ (%@ bytes)",
                size(summary.totalLogicalSize),
                number(summary.totalLogicalSize)
            ),
            width: topWidth
        ))
        lines.append(row(
            topLabels[2],
            L10n.format(
                "%@ (%@ bytes)",
                size(summary.totalAllocatedSize),
                number(summary.totalAllocatedSize)
            ),
            width: topWidth
        ))
        lines.append(row(topLabels[3], number(summary.fileCount), width: topWidth))
        lines.append(row(topLabels[4], number(summary.directoryCount), width: topWidth))
        lines.append(row(topLabels[5], issues(summary), width: topWidth))
        lines.append(row(
            topLabels[6],
            L10n.string("hidden items included, stays on this volume, symbolic links not followed"),
            width: topWidth
        ))

        if let root = rootNode(in: summary) {
            lines.append("")
            lines.append(folderHeading(command))
            append(folder: root, named: root.url.standardizedFileURL.path, level: 0, command, into: &lines)
        }

        let files = ordered(summary.largestFiles).prefix(command.top)
        lines.append("")
        lines.append(L10n.format("Largest files (%@)", number(files.count)))
        if files.isEmpty {
            lines.append("  " + L10n.string("(none)"))
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
        lines.append(L10n.format("By category (%@)", number(categories.count)))
        if categories.isEmpty {
            lines.append("  " + L10n.string("(nothing measured)"))
        }
        for (category, bytes) in categories {
            lines.append("  \(size(bytes))  \(L10n.string(category.rawValue.capitalized))")
        }

        appendAccounting(summary.accounting, into: &lines)

        return lines.joined(separator: "\n") + "\n"
    }

    private static func issues(_ summary: ScanSummary) -> String {
        guard summary.permissionDeniedCount > 0 else {
            return number(summary.errorCount)
        }
        return L10n.format(
            "%lld (%lld permission denied)",
            summary.errorCount,
            summary.permissionDeniedCount
        )
    }

    private static func folderHeading(_ command: ScanCommand) -> String {
        guard command.depth > 0 else { return L10n.string("Folders (root only)") }
        return L10n.format(
            "Folders (%@, %@ per level)",
            L10n.format("%lld levels", command.depth),
            number(command.top)
        )
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
            let more = L10n.format("%lld more folders", hidden)
            lines.append("\(childIndent)+ \(more)")
        }
    }

    private static func appendAccounting(_ accounting: ScanAccounting, into lines: inout [String]) {
        guard accounting.hasFindings else { return }
        lines.append("")
        lines.append(L10n.string("Accounting"))

        let labels = [
            L10n.string("Hard links"),
            L10n.string("Dataless"),
            L10n.string("Skipped"),
            L10n.string("Exclusions"),
        ]
        let width = labelWidth(labels, minimum: 12, gap: 2)

        if accounting.hardlinkFileCount > 0 {
            lines.append(row(
                labels[0],
                L10n.format(
                    "%@ with more than one link; %@ of the total counted twice",
                    L10n.format("%lld files", accounting.hardlinkFileCount),
                    size(accounting.hardlinkExtraLogicalSize)
                ),
                width: width
            ))
        }
        if accounting.datalessFileCount > 0 {
            lines.append(row(
                labels[1],
                L10n.format(
                    "%@; %@ of logical size lives in the cloud",
                    L10n.format("%lld files", accounting.datalessFileCount),
                    size(accounting.datalessLogicalSize)
                ),
                width: width
            ))
        }

        var skipped: [String] = []
        if accounting.skippedSymlinkCount > 0 {
            skipped.append(L10n.format("%lld symbolic links", accounting.skippedSymlinkCount))
        }
        if accounting.skippedVolumeCount > 0 {
            skipped.append(L10n.format("%lld volumes", accounting.skippedVolumeCount))
        }
        if accounting.specialFileCount > 0 {
            skipped.append(L10n.format("%lld special files", accounting.specialFileCount))
        }
        if !skipped.isEmpty {
            lines.append(row(labels[2], L10n.list(skipped), width: width))
        }
        if accounting.excludedItemCount > 0 {
            lines.append(row(
                labels[3],
                L10n.format(
                    "%@ left out; their contents are not in the totals",
                    L10n.format("%lld entries", accounting.excludedItemCount)
                ),
                width: width
            ))
        }
    }

    /// One `  label   value` row. The label column is as wide as the widest
    /// label in the block, so a translation that is longer than English keeps
    /// every value on one line instead of pushing the column out of alignment.
    private static func row(_ label: String, _ value: String, width: Int) -> String {
        "  " + label + String(repeating: " ", count: max(1, width - label.count)) + value
    }

    private static func labelWidth(_ labels: [String], minimum: Int, gap: Int) -> Int {
        max(minimum, (labels.map(\.count).max() ?? 0) + gap)
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(L10n.locale))
    }

    private static func number(_ value: Int64) -> String {
        value.formatted(.number.locale(L10n.locale))
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
        guard bytes != 0 else { return L10n.string("0 bytes") }
        return ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}
