import Foundation

/// A mounted local volume with its capacity metadata, used on Screen A to show
/// "available disk/volume info" and to let the user pick a volume to scan.
public struct VolumeInfo: Identifiable, Equatable {
    public let url: URL
    public let name: String
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?
    public let isInternal: Bool
    public let isReadOnly: Bool

    public var id: URL { url }

    public var usedCapacity: Int64? {
        guard let total = totalCapacity, let available = availableCapacity else { return nil }
        return max(0, total - available)
    }

    /// Fraction of the volume that is used (0...1), or nil when unknown.
    public var usedFraction: Double? {
        guard let total = totalCapacity, total > 0, let used = usedCapacity else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    /// Whether `url` is the directory this volume is mounted at.
    ///
    /// Compares paths rather than URLs: the two sides reach here from different
    /// places — a `URL` recorded from a scan and one enumerated from
    /// `mountedVolumeURLs` — and can differ in trailing separators while naming
    /// the same mount point.
    public static func isMountPoint(_ url: URL, ofVolumes volumes: [VolumeInfo]) -> Bool {
        let path = url.standardizedFileURL.path
        return volumes.contains { $0.url.standardizedFileURL.path == path }
    }

    /// Enumerates mounted local volumes with their capacity values.
    public static func enumerate() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsReadOnlyKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            let displayName = values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent
            return VolumeInfo(
                url: url,
                name: displayName,
                totalCapacity: (values?.volumeTotalCapacity).map(Int64.init),
                availableCapacity: (values?.volumeAvailableCapacity).map(Int64.init),
                isInternal: values?.volumeIsInternal ?? true,
                isReadOnly: values?.volumeIsReadOnly ?? false
            )
        }
        .sorted { ($0.isInternal ? 0 : 1, $0.name.lowercased()) < ($1.isInternal ? 0 : 1, $1.name.lowercased()) }
    }
}
