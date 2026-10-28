import Foundation
import DiskCore
import DiskLocalization

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
                label: L10n.string("Files"),
                value: summary.fileCount.formatted()
            ),
            CoverageRow(
                id: "folders",
                label: L10n.string("Folders"),
                value: summary.directoryCount.formatted()
            ),
            CoverageRow(
                id: "logical",
                label: L10n.string("Logical size"),
                value: ByteFormat.string(summary.totalLogicalSize)
            ),
            CoverageRow(
                id: "allocated",
                label: L10n.string("On disk"),
                value: ByteFormat.string(summary.totalAllocatedSize)
            ),
        ]

        if let facts {
            var rows: [CoverageRow] = [
                CoverageRow(
                    id: "volume-name",
                    label: L10n.string("Volume"),
                    value: facts.name,
                    detail: L10n.format("Mount point %@", facts.mountURL.path)
                ),
                CoverageRow(
                    id: "volume-capacity",
                    label: L10n.string("Capacity"),
                    value: ByteFormat.string(facts.totalCapacity)
                ),
                CoverageRow(
                    id: "volume-used",
                    label: L10n.string("Used by the volume"),
                    value: ByteFormat.string(facts.usedCapacity)
                ),
                CoverageRow(
                    id: "volume-available",
                    label: L10n.string("Available"),
                    value: ByteFormat.string(facts.availableCapacity),
                    detail: facts.reclaimableBySystem > 0
                        ? L10n.format(
                            "macOS reports %@ more can be made available for important use by removing purgeable data.",
                            ByteFormat.string(facts.reclaimableBySystem)
                        )
                        : nil
                ),
            ]
            if facts.isReadOnly {
                rows.append(CoverageRow(
                    id: "volume-read-only",
                    label: L10n.string("Read-only"),
                    value: L10n.string("Yes"),
                    detail: L10n.string("Nothing on this volume can be moved or changed.")
                ))
            }
            volume = rows
        } else {
            volume = [CoverageRow(
                id: "volume-unavailable",
                label: L10n.string("Volume"),
                value: L10n.string("Unavailable"),
                detail: L10n.string("The volume's own capacity figures could not be read.")
            )]
        }

        let accounting = summary.accounting
        var limits: [CoverageRow] = []

        if summary.inaccessibleCount > 0 {
            limits.append(CoverageRow(
                id: "inaccessible",
                label: L10n.string("Folders not read"),
                value: summary.inaccessibleCount.formatted(),
                detail: L10n.format(
                    "Their contents are missing from the totals. %@ were reported.",
                    CountFormat.issues(summary.errorCount)
                )
            ))
        }

        if accounting.excludedItemCount > 0 {
            limits.append(CoverageRow(
                id: "exclusions",
                label: L10n.string("Skipped by your exclusions"),
                value: CountFormat.items(accounting.excludedItemCount),
                detail: L10n.string("The scan did not descend into these items, so their contents are not in the totals. The size of what was left out is therefore unknown.")
            ))
        }

        if accounting.hardlinkFileCount > 0 {
            let extra = accounting.hardlinkExtraLogicalSize
            limits.append(CoverageRow(
                id: "hardlinks",
                label: L10n.string("Hard-linked files"),
                value: CountFormat.files(accounting.hardlinkFileCount),
                detail: extra > 0
                    ? L10n.format(
                        "%@ is counted more than once, because every link the scan reached is counted as a file.",
                        ByteFormat.string(extra)
                    )
                    : L10n.string("Each file has more than one link, but only one link was reached; no bytes were counted twice.")
            ))
        }

        if accounting.datalessFileCount > 0 {
            limits.append(CoverageRow(
                id: "dataless",
                label: L10n.string("Cloud-only files"),
                value: CountFormat.files(accounting.datalessFileCount),
                detail: L10n.format(
                    "They report %@ but occupy %@ on this disk. Their data is not here.",
                    ByteFormat.string(accounting.datalessLogicalSize),
                    ByteFormat.string(accounting.datalessAllocatedSize)
                )
            ))
        }

        if accounting.skippedSymlinkCount > 0 {
            limits.append(CoverageRow(
                id: "symlinks",
                label: L10n.string("Links not followed"),
                value: accounting.skippedSymlinkCount.formatted(),
                detail: L10n.string("A link's target is not counted through the link; the link itself carries no file data.")
            ))
        }

        if accounting.skippedVolumeCount > 0 {
            limits.append(CoverageRow(
                id: "volumes",
                label: L10n.string("Folders on other volumes"),
                value: accounting.skippedVolumeCount.formatted(),
                detail: L10n.string("The scan stayed on this volume, as its options asked, so these folders were not entered.")
            ))
        }

        if accounting.specialFileCount > 0 {
            limits.append(CoverageRow(
                id: "special",
                label: L10n.string("Special files"),
                value: accounting.specialFileCount.formatted(),
                detail: L10n.string("Sockets, devices, and FIFOs hold no file data and were skipped safely.")
            ))
        }

        if limits.isEmpty {
            limits = [CoverageRow(
                id: "none",
                label: L10n.string("Overlaps and skips"),
                value: L10n.string("None found"),
                detail: L10n.string("The scan found no unreadable folders, exclusions, hard-link overlaps, cloud-only files, skipped links, other volumes, or special files.")
            )]
        }
        self.limits = limits

        switch snapshots {
        case nil:
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: L10n.string("Local snapshots"),
                value: L10n.string("Checking…")
            )
            snapshotNames = []
        case let .some(result) where !result.isAvailable:
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: L10n.string("Local snapshots"),
                value: L10n.string("Unavailable"),
                detail: L10n.format(
                    "%@ Snapshots may still hold space on this volume.",
                    result.failureMessage ?? L10n.string("The snapshot list could not be read.")
                )
            )
            snapshotNames = []
        case let .some(result) where result.names.isEmpty:
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: L10n.string("Local snapshots"),
                value: L10n.string("None listed"),
                detail: L10n.string("macOS did not report local snapshots for this volume.")
            )
            snapshotNames = []
        case let .some(result):
            self.snapshots = CoverageRow(
                id: "snapshots",
                label: L10n.string("Local snapshots"),
                value: result.count.formatted(),
                detail: L10n.string("They can keep deleted blocks on this volume until macOS removes them. macOS does not expose a snapshot's size.")
            )
            snapshotNames = result.names
        }

        scopeNote = L10n.format(
            "Scanned totals cover only the files under %@. The volume's used space also includes other folders, macOS, and space macOS manages outside the file tree. The scan totals are from the scan time above; the volume figures are read when this panel opens. This panel reports both; it does not subtract one from the other.",
            rootPath
        )

        if rootPath == "/" || rootPath == "/System/Volumes/Data" || rootPath.hasPrefix("/System/Volumes/Data/") {
            startupDiskNote = L10n.string("This is the startup disk. macOS presents its system and data halves as one volume, so a scan of the system half and a scan of the data half describe the same volume from different angles.")
        } else {
            startupDiskNote = nil
        }
    }
}
