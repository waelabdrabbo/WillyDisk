import Foundation
import DiskCore

/// One explanatory line in the coverage sheet.
public struct CoverageRow: Identifiable, Equatable, Sendable {
    /// Stable within a report, so a `ForEach` can animate updates.
    public let id: String
    public let label: String
    public let value: String
    public let detail: String?

    public init(id: String, label: String, value: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
    }
}

/// The words a coverage sheet shows, derived only from the scan and the
/// system's volume answers.
///
/// The report never subtracts the scanned total from the volume's used space:
/// the two measure different things, and a difference is not an explanation.
/// Every row says what was counted, what was skipped, or what the scan cannot
/// see.
public struct CoverageReport: Equatable, Sendable {
    public let rootPath: String
    public let isLive: Bool
    public let scanned: [CoverageRow]
    public let volume: [CoverageRow]
    public let limits: [CoverageRow]
    public let snapshots: CoverageRow
    public let snapshotNames: [String]
    public let scopeNote: String
    public let startupDiskNote: String?

    public init(
        summary: ScanSummary,
        volume facts: VolumeFacts?,
        snapshots: LocalSnapshots?,
        isLive: Bool
    ) {
        let rootPath = summary.root.path
        self.rootPath = rootPath
        self.isLive = isLive

        scanned = [
            CoverageRow(
                id: "files",
                label: "Files",
                value: summary.fileCount.formatted()
            ),
            CoverageRow(
                id: "folders",
                label: "Folders",
                value: summary.directoryCount.formatted()
            ),
            CoverageRow(
                id: "logical",
                label: "Reported size",
                value: ByteFormat.string(summary.totalLogicalSize)
            ),
            CoverageRow(
                id: "allocated",
                label: "On disk",
                value: ByteFormat.string(summary.totalAllocatedSize)
            ),
        ]

        if let facts {
            var rows: [CoverageRow] = [
                CoverageRow(
                    id: "volume-name",
                    label: "Volume",
                    value: facts.name,
                    detail: "Mount point \(facts.mountURL.path)"
                ),
                CoverageRow(
                    id: "volume-capacity",
                    label: "Capacity",
                    value: ByteFormat.string(facts.totalCapacity)
                ),
                CoverageRow(
                    id: "volume-used",
                    label: "Used by the volume",
                    value: ByteFormat.string(facts.usedCapacity)
                ),
                CoverageRow(
                    id: "volume-available",
                    label: "Available",
                    value: ByteFormat.string(facts.availableCapacity),
                    detail: facts.reclaimableBySystem > 0
                        ? "macOS reports \(ByteFormat.string(facts.reclaimableBySystem)) more can be made available for important use by removing purgeable data."
                        : nil
                ),
            ]
            if facts.isReadOnly {
                rows.append(CoverageRow(
                    id: "volume-read-only",
                    label: "Read-only",
                    value: "Yes",
                    detail: "Nothing on this volume can be moved or changed."
                ))
            }
            volume = rows
        } else {
            volume = [CoverageRow(
                id: "volume-unavailable",
                label: "Volume",
                value: "Unavailable",
                detail: "The volume's own capacity figures could not be read."
            )]
        }

        let accounting = summary.accounting
        var limits: [CoverageRow] = []

        if summary.inaccessibleCount > 0 {
            limits.append(CoverageRow(
                id: "inaccessible",
                label: "Folders not read",
                value: summary.inaccessibleCount.formatted(),
                detail: "Their contents are missing from the totals. \(summary.errorCount.formatted()) issue\(summary.errorCount == 1 ? "" : "s") were reported."
            ))
        }

        if accounting.hardlinkFileCount > 0 {
            let extra = accounting.hardlinkExtraLogicalSize
            limits.append(CoverageRow(
                id: "hardlinks",
                label: "Hard-linked files",
                value: CountFormat.files(accounting.hardlinkFileCount),
                detail: extra > 0
                    ? "\(ByteFormat.string(extra)) is counted more than once, because every link the walk reached is counted as a file."
                    : "Each file has more than one link, but only one link was reached; no bytes were counted twice."
            ))
        }

        if accounting.datalessFileCount > 0 {
            limits.append(CoverageRow(
                id: "dataless",
                label: "Cloud-only files",
                value: CountFormat.files(accounting.datalessFileCount),
                detail: "They report \(ByteFormat.string(accounting.datalessLogicalSize)) but occupy \(ByteFormat.string(accounting.datalessAllocatedSize)) on this disk. Their data is not here."
            ))
        }

        if accounting.skippedSymlinkCount > 0 {
            limits.append(CoverageRow(
                id: "symlinks",
                label: "Links not followed",
                value: accounting.skippedSymlinkCount.formatted(),
                detail: "A link's target is not counted through the link; the link itself carries no file data."
            ))
        }

        if accounting.skippedVolumeCount > 0 {
            limits.append(CoverageRow(
                id: "volumes",
                label: "Folders on other volumes",
                value: accounting.skippedVolumeCount.formatted(),
                detail: "The scan stayed on this volume, as its options asked, so these folders were not entered."
            ))
        }

        if accounting.specialFileCount > 0 {
            limits.append(CoverageRow(
                id: "special",
                label: "Special files",
                value: accounting.specialFileCount.formatted(),
                detail: "Sockets, devices, and FIFOs hold no file data and were skipped safely."
            ))
        }

        if limits.isEmpty {
            limits = [CoverageRow(
                id: "none",
                label: "Overlaps and skips",
                value: "None found",
                detail: "The scan found no unreadable folders, hard-link overlaps, cloud-only files, skipped links, other volumes, or special files."
            )]
        }
        self.limits = limits

        switch snapshots {
        case nil:
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: "Local snapshots",
                value: "Checking…"
            )
            snapshotNames = []
        case let .some(result) where !result.isAvailable:
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: "Local snapshots",
                value: "Unavailable",
                detail: (result.failureMessage ?? "The snapshot list could not be read.")
                    + " Snapshots may still hold space on this volume."
            )
            snapshotNames = []
        case let .some(result) where result.names.isEmpty:
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: "Local snapshots",
                value: "None listed",
                detail: "macOS did not report local snapshots for this volume."
            )
            snapshotNames = []
        case let .some(result):
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: "Local snapshots",
                value: result.count.formatted(),
                detail: "They can keep deleted blocks on this volume until macOS removes them. macOS does not expose a snapshot's size."
            )
            snapshotNames = result.names
        }

        scopeNote = "Scanned totals cover only the files under \(rootPath). The volume's used space also includes other folders, macOS, and space macOS manages outside the file tree. The scan totals are from the scan time above; the volume figures are read when this panel opens. This panel reports both; it does not subtract one from the other."

        if rootPath == "/" || rootPath == "/System/Volumes/Data" || rootPath.hasPrefix("/System/Volumes/Data/") {
            startupDiskNote = "This is the startup disk. macOS presents its system and data halves as one volume, so a scan of the system half and a scan of the data half describe the same volume from different angles."
        } else {
            startupDiskNote = nil
        }
    }
}
