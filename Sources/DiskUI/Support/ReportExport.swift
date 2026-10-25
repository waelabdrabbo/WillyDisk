import Foundation
import AppKit
import UniformTypeIdentifiers
import DiskCore
import DiskLocalization

/// Report export (JSON + CSV) via `NSSavePanel`. Writes a real file to a
/// user-chosen location.
@MainActor
public enum ReportExport {

    // MARK: - DTOs (the frozen models are not `Codable`, so we map them)

    private struct ExportNode: Codable {
        let name: String
        let path: String
        let isDirectory: Bool
        let isSymlink: Bool
        let category: String
        let logicalSize: Int64
        let allocatedSize: Int64
        let fileCount: Int
        let directoryCount: Int
        let modifiedAt: String?
    }

    /// The same disclosures the coverage sheet shows, so an exported report
    /// does not present its totals as if every byte were distinct and local.
    private struct ExportAccounting: Codable {
        let hardlinkFileCount: Int
        let hardlinkExtraLogicalSize: Int64
        let hardlinkExtraAllocatedSize: Int64
        let datalessFileCount: Int
        let datalessLogicalSize: Int64
        let datalessAllocatedSize: Int64
        let skippedSymlinkCount: Int
        let skippedVolumeCount: Int
        let specialFileCount: Int

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
        }
    }

    private struct ExportReport: Codable {
        let root: String
        let generatedAt: String
        let totalLogicalSize: Int64
        let totalAllocatedSize: Int64
        let fileCount: Int
        let directoryCount: Int
        let inaccessibleCount: Int
        let errorCount: Int
        /// Distinct restricted locations (⊆ `inaccessibleCount`) and how many
        /// per-path details were surfaced — the same accounting the UI shows,
        /// so an exported report carries the access-restriction total too.
        let permissionDeniedCount: Int
        let surfacedIssueCount: Int
        let startedAt: String
        let finishedAt: String
        let categoryBreakdown: [String: Int64]
        let largestFiles: [ExportNode]
        let largestDirectories: [ExportNode]
        let accounting: ExportAccounting
    }

    // MARK: - Public entry points

    public static func exportJSON(summary: ScanSummary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(makeReport(summary)),
              let text = String(data: data, encoding: .utf8) else { return }
        presentSavePanel(content: text, defaultName: L10n.string("WillyDisk Report.json"), contentType: .json)
    }

    public static func exportCSV(summary: ScanSummary) {
        presentSavePanel(content: makeCSV(summary), defaultName: L10n.string("WillyDisk Report.csv"), contentType: .commaSeparatedText)
    }

    // MARK: - Report building

    private static func makeReport(_ summary: ScanSummary) -> ExportReport {
        let breakdown = Dictionary(uniqueKeysWithValues: summary.categoryBreakdown.map { ($0.key.rawValue, $0.value) })
        return ExportReport(
            root: summary.root.path,
            generatedAt: iso(summary.finishedAt),
            totalLogicalSize: summary.totalLogicalSize,
            totalAllocatedSize: summary.totalAllocatedSize,
            fileCount: summary.fileCount,
            directoryCount: summary.directoryCount,
            inaccessibleCount: summary.inaccessibleCount,
            errorCount: summary.errorCount,
            permissionDeniedCount: summary.permissionDeniedCount,
            surfacedIssueCount: summary.surfacedIssueCount,
            startedAt: iso(summary.startedAt),
            finishedAt: iso(summary.finishedAt),
            categoryBreakdown: breakdown,
            largestFiles: summary.largestFiles.map(makeNode),
            largestDirectories: summary.largestDirectories.map(makeNode),
            accounting: ExportAccounting(summary.accounting)
        )
    }

    private static func makeNode(_ node: ScanNode) -> ExportNode {
        ExportNode(
            name: node.name,
            path: node.url.path,
            isDirectory: node.isDirectory,
            isSymlink: node.isSymlink,
            category: node.category.rawValue,
            logicalSize: node.logicalSize,
            allocatedSize: node.allocatedSize,
            fileCount: node.fileCount,
            directoryCount: node.directoryCount,
            modifiedAt: node.modifiedAt.map(iso)
        )
    }

    private static func makeCSV(_ summary: ScanSummary) -> String {
        let header = [
            L10n.string("Type"), L10n.string("Name"), L10n.string("Path"),
            L10n.string("Category"), L10n.string("Logical Size"), L10n.string("Allocated Size"),
            L10n.string("Files"), L10n.string("Folders"), L10n.string("Modified"),
        ]
        var lines: [[String]] = [header]

        func append(_ node: ScanNode, _ type: String) {
            lines.append([
                type,
                csv(node.name),
                csv(node.url.path),
                node.category.rawValue,
                "\(node.logicalSize)",
                "\(node.allocatedSize)",
                "\(node.fileCount)",
                "\(node.directoryCount)",
                node.modifiedAt.map(iso) ?? "",
            ])
        }

        for node in summary.largestFiles { append(node, L10n.string("File")) }
        for node in summary.largestDirectories { append(node, L10n.string("Directory")) }

        return lines.map { $0.map(csv).joined(separator: ",") }.joined(separator: "\n")
    }

    private static func csv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Save panel

    private static func presentSavePanel(content: String, defaultName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.title = L10n.string("Export Report")
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentWriteError(error, url: url)
            }
        }
    }

    private static func presentWriteError(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Export failed")
        alert.informativeText = L10n.format("Could not write the report to %@: %@", url.lastPathComponent, error.localizedDescription)
        alert.runModal()
    }
}
