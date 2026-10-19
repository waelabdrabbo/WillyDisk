import Foundation

/// What the volume holding a scanned folder reports about itself.
///
/// These are the system's own numbers, not a reconciliation of the scan. A
/// scanned folder's bytes are usually a fraction of the volume's used space:
/// the rest belongs to other folders, macOS, and space macOS manages outside
/// the file tree. The coverage screen shows both and never subtracts one from
/// the other.
public struct VolumeFacts: Equatable, Sendable {
    /// The volume's mount point, e.g. `/` or `/Volumes/Archive`.
    public let mountURL: URL
    public let name: String
    public let totalCapacity: Int64
    public let availableCapacity: Int64
    /// The capacity macOS reports it can make available for important use by
    /// removing purgeable data. `nil` when the system does not report it.
    public let availableForImportantUsage: Int64?
    public let isReadOnly: Bool

    public init(
        mountURL: URL,
        name: String,
        totalCapacity: Int64,
        availableCapacity: Int64,
        availableForImportantUsage: Int64?,
        isReadOnly: Bool
    ) {
        self.mountURL = mountURL
        self.name = name
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.isReadOnly = isReadOnly
    }

    public var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    public var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(1, Double(usedCapacity) / Double(totalCapacity))
    }

    /// Bytes macOS says it could make available beyond the plain available
    /// figure, by removing purgeable data. Not space the scan can count.
    public var reclaimableBySystem: Int64 {
        max(0, (availableForImportantUsage ?? availableCapacity) - availableCapacity)
    }
}

/// Reads a volume's facts off the main actor so a sheet can stay responsive on
/// a slow or network-backed volume.
public enum VolumeFactsProbe {
    public static func facts(for url: URL) async -> VolumeFacts? {
        await Task.detached(priority: .utility) { () -> VolumeFacts? in
            let keys: Set<URLResourceKey> = [
                .volumeLocalizedNameKey,
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeIsReadOnlyKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity
            else { return nil }

            let mount = MountedVolume.of(url)?.root ?? url.standardizedFileURL
            let name = values.volumeLocalizedName
                ?? values.volumeName
                ?? mount.lastPathComponent
            return VolumeFacts(
                mountURL: mount,
                name: name.isEmpty ? mount.path : name,
                totalCapacity: Int64(total),
                availableCapacity: Int64(available),
                availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage,
                isReadOnly: MountedVolume.of(url)?.isReadOnly ?? values.volumeIsReadOnly ?? false
            )
        }.value
    }
}
