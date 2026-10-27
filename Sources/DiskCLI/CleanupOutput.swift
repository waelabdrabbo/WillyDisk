import Foundation
import DiskCore
import DiskLocalization

/// Turns one cleanup analysis into the two things the command line can print: a
/// short human report and a versioned record.
///
/// Both are derived from the same `CleanupReport`; nothing is recomputed here.
/// The only choice the report makes is order: rules in their declared order,
/// candidates by local size and then path, duplicate groups by size. That makes
/// two runs over an unchanged folder print the same bytes apart from the scan's
/// date.
public enum CleanupOutput {

    /// The record's own version. A consumer that reads `schemaVersion` can tell
    /// an older or newer shape apart without guessing from the keys.
    public static let currentSchemaVersion = 1

    // MARK: - Text report

    public static func text(
        root: URL,
        scannedAt: Date,
        report: CleanupReport,
        contents: DuplicateReport?
    ) -> String {
        var lines: [String] = []

        let labels = [
            L10n.string("Location"),
            L10n.string("Scanned"),
            L10n.string("Sizes"),
            L10n.string("Entries"),
            L10n.string("Status"),
        ]
        let width = max(12, (labels.map(\.count).max() ?? 0) + 3)

        lines.append(L10n.string("WillyDisk cleanup"))
        lines.append(row(labels[0], root.standardizedFileURL.path, width: width))
        lines.append(row(labels[1], date(scannedAt), width: width))
        lines.append(row(labels[2], L10n.string("bytes on disk, not logical"), width: width))
        lines.append(row(
            labels[3],
            report.visitedCount.formatted(.number.locale(L10n.locale)),
            width: width
        ))
        lines.append(row(
            labels[4],
            report.stoppedAtLimit
                ? L10n.string("sample (stopped at the cap)")
                : L10n.string("complete"),
            width: width
        ))

        let groups = report.groups.filter { $0.candidates.isEmpty == false }
        if groups.isEmpty {
            lines.append("")
            lines.append(L10n.string("Nothing to review"))
        } else {
            for tier in CleanupTier.allCases {
                let tierGroups = groups.filter { $0.rule.tier == tier }
                guard !tierGroups.isEmpty else { continue }
                lines.append("")
                lines.append("\(tier.title)")
                for group in tierGroups {
                    append(group: group, into: &lines)
                }
            }
        }

        lines.append("")
        lines.append(L10n.string("Duplicates"))
        appendDuplicateSummary(report, into: &lines)
        if let contents {
            appendContents(contents, policy: report.policy, into: &lines)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(group: CleanupGroup, into lines: inout [String]) {
        lines.append("  " + L10n.format(
            "%@ · %@ · %@",
            group.rule.title,
            size(group.totalAllocatedSize),
            L10n.format("%lld items", group.matchCount)
        ))
        if group.isTruncated {
            lines.append("    " + L10n.format("showing the largest %lld", group.candidates.count))
        }
        for candidate in group.candidates {
            lines.append("    \(size(candidate.allocatedSize))  \(candidate.url.standardizedFileURL.path)")
        }
    }

    private static func appendDuplicateSummary(_ report: CleanupReport, into lines: inout [String]) {
        guard report.duplicateGroupCount > 0 else {
            lines.append("  " + L10n.string("No possible duplicates"))
            return
        }
        lines.append("  " + L10n.format(
            "%@ · %@",
            L10n.format("%lld size groups", report.duplicateGroupCount),
            L10n.format("%lld files", report.duplicateFileCount)
        ))
        for group in report.duplicateGroups {
            if group.candidates.isEmpty { continue }
            lines.append("  " + L10n.format("%@ each", size(group.candidates[0].allocatedSize)))
            for candidate in group.candidates {
                lines.append("    \(candidate.url.standardizedFileURL.path)")
            }
        }
        if report.duplicateGroups.contains(where: { $0.isTruncated }) {
            lines.append("  " + L10n.format(
                "Each size group keeps at most %lld files; the rest are not compared.",
                report.policy.maxDuplicateFilesPerGroup
            ))
        }
        if report.duplicateGroupCount > report.duplicateGroups.count {
            lines.append("  " + L10n.format(
                "showing the largest %lld",
                report.duplicateGroups.count
            ))
        }
    }

    private static func appendContents(
        _ result: DuplicateReport,
        policy: CleanupPolicy,
        into lines: inout [String]
    ) {
        lines.append("")
        lines.append("  " + L10n.string("Identical contents"))
        if result.isEmpty {
            lines.append("  " + L10n.string("No identical contents found"))
            // Nothing was read when every candidate was a link or a clone; the
            // notes below say which, and a "compared 0 of 0" line would not.
            if result.comparedFileCount > 0 {
                lines.append("  " + L10n.format(
                    "Compared %@ of %@. The files that were read have different contents; the same size alone is not a duplicate.",
                    L10n.format("%lld files", result.comparedFileCount),
                    L10n.format("%lld files", result.candidateFileCount)
                ))
            }
        } else {
            lines.append("  " + L10n.format(
                "Compared %@ of %@. The confirmed groups below have identical contents.",
                L10n.format("%lld files", result.comparedFileCount),
                L10n.format("%lld files", result.candidateFileCount)
            ))
            for group in result.groups {
                lines.append("  " + L10n.format("%@ each", size(group.localSize)))
                for candidate in group.candidates {
                    lines.append("    \(candidate.url.standardizedFileURL.path)")
                }
            }
        }
        if result.unreadableFileCount > 0 {
            lines.append("  " + L10n.format(
                "%@ could not be read and are not called duplicates.",
                L10n.format("%lld files", result.unreadableFileCount)
            ))
        }
        if result.hardLinkFileCount > 0 {
            lines.append("  " + L10n.format(
                "Paths that are hard links to another file are not offered as copies, because moving one frees nothing until every link is gone: %@.",
                L10n.format("%lld files", result.hardLinkFileCount)
            ))
        }
        if result.cloneFileCount > 0 {
            lines.append("  " + L10n.format(
                "Paths that share storage with another file are not offered as copies, because moving one frees nothing until the others are gone: %@.",
                L10n.format("%lld files", result.cloneFileCount)
            ))
        }
    }

    private static func row(_ label: String, _ value: String, width: Int) -> String {
        "  " + label + String(repeating: " ", count: max(1, width - label.count)) + value
    }

    // MARK: - Record

    public static func record(
        root: URL,
        scannedAt: Date,
        report: CleanupReport,
        contents: DuplicateReport?
    ) -> CleanupRecord {
        let policy = report.policy
        return CleanupRecord(
            schemaVersion: currentSchemaVersion,
            rootPath: root.standardizedFileURL.path,
            scannedAt: scannedAt,
            visitedCount: report.visitedCount,
            stoppedAtLimit: report.stoppedAtLimit,
            policy: CleanupRecord.Policy(
                largeFileMinimum: policy.largeFileMinimum,
                largeFileAge: policy.largeFileAge,
                downloadAge: policy.downloadAge,
                maxCandidatesPerGroup: policy.maxCandidatesPerGroup,
                duplicateMinimum: policy.duplicateMinimum,
                maxDuplicateGroups: policy.maxDuplicateGroups,
                maxDuplicateFilesPerGroup: policy.maxDuplicateFilesPerGroup,
                maxVisitedNodes: policy.maxVisitedNodes
            ),
            groups: report.groups
                .filter { $0.candidates.isEmpty == false }
                .map(CleanupRecord.Group.init),
            duplicates: CleanupRecord.Duplicates(
                groupCount: report.duplicateGroupCount,
                fileCount: report.duplicateFileCount,
                groups: report.duplicateGroups.map(CleanupRecord.SizeGroup.init)
            ),
            contents: contents.map(CleanupRecord.Contents.init)
        )
    }

    public static func json(_ record: CleanupRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: - Shared

    private static func size(_ bytes: Int64) -> String {
        guard bytes != 0 else { return L10n.string("0 bytes") }
        return ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The versioned JSON a `WillyDisk cleanup --json` run prints.
///
/// Machine data: keys and rule identifiers are never localized, so a script can
/// read them in any interface language. Sizes are bytes on disk; the record
/// makes no claim about space being freed.
public struct CleanupRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let rootPath: String
    public let scannedAt: Date
    public let visitedCount: Int
    public let stoppedAtLimit: Bool
    public let policy: Policy
    public let groups: [Group]
    public let duplicates: Duplicates
    public let contents: Contents?

    public struct Policy: Codable, Equatable, Sendable {
        public let largeFileMinimum: Int64
        public let largeFileAge: TimeInterval
        public let downloadAge: TimeInterval
        public let maxCandidatesPerGroup: Int
        public let duplicateMinimum: Int64
        public let maxDuplicateGroups: Int
        public let maxDuplicateFilesPerGroup: Int
        public let maxVisitedNodes: Int
    }

    public struct Group: Codable, Equatable, Sendable {
        public let rule: String
        public let tier: String
        public let matchCount: Int
        public let shownCount: Int
        public let truncated: Bool
        public let totalLogicalSize: Int64
        public let totalAllocatedSize: Int64
        public let candidates: [Candidate]

        init(_ group: CleanupGroup) {
            rule = group.rule.rawValue
            tier = group.rule.tier.rawValue
            matchCount = group.matchCount
            shownCount = group.candidates.count
            truncated = group.isTruncated
            totalLogicalSize = group.totalLogicalSize
            totalAllocatedSize = group.totalAllocatedSize
            candidates = group.candidates.map(Candidate.init)
        }
    }

    public struct Candidate: Codable, Equatable, Sendable {
        public let path: String
        public let name: String
        public let isDirectory: Bool
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public let fileCount: Int
        public let modifiedAt: Date?

        init(_ candidate: CleanupCandidate) {
            path = candidate.url.standardizedFileURL.path
            name = candidate.name
            isDirectory = candidate.isDirectory
            logicalSize = candidate.logicalSize
            allocatedSize = candidate.allocatedSize
            fileCount = candidate.fileCount
            modifiedAt = candidate.modifiedAt
        }
    }

    public struct Duplicates: Codable, Equatable, Sendable {
        public let groupCount: Int
        public let fileCount: Int
        public let groups: [SizeGroup]
    }

    public struct SizeGroup: Codable, Equatable, Sendable {
        public let logicalSize: Int64
        public let matchCount: Int
        public let shownCount: Int
        public let truncated: Bool
        public let paths: [String]

        init(_ group: DuplicateSizeGroup) {
            logicalSize = group.logicalSize
            matchCount = group.matchCount
            shownCount = group.candidates.count
            truncated = group.isTruncated
            paths = group.candidates.map { $0.url.standardizedFileURL.path }
        }
    }

    public struct Contents: Codable, Equatable, Sendable {
        public let comparedFileCount: Int
        public let unreadableFileCount: Int
        public let hardLinkFileCount: Int
        public let cloneFileCount: Int
        public let candidateFileCount: Int
        public let groups: [ContentGroup]

        init(_ report: DuplicateReport) {
            comparedFileCount = report.comparedFileCount
            unreadableFileCount = report.unreadableFileCount
            hardLinkFileCount = report.hardLinkFileCount
            cloneFileCount = report.cloneFileCount
            candidateFileCount = report.candidateFileCount
            groups = report.groups.map(ContentGroup.init)
        }
    }

    public struct ContentGroup: Codable, Equatable, Sendable {
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public let paths: [String]

        init(_ group: DuplicateContentGroup) {
            logicalSize = group.logicalSize
            allocatedSize = group.localSize
            paths = group.candidates.map { $0.url.standardizedFileURL.path }
        }
    }
}
