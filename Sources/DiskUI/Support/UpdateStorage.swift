import Foundation
import DiskUpdate

/// Where an update is staged before it is verified.
///
/// Everything lives under `~/Library/Application Support/WillyDisk/Updates/`,
/// which the Homebrew cask already zaps and which holds no user file. A version
/// directory is created owner-only and replaced wholesale, so an interrupted
/// attempt cannot leave two archives for the same release behind.
public struct UpdateStorage: Sendable {
    public static var defaultRoot: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WillyDisk/Updates", isDirectory: true)
    }

    public let root: URL

    public init(root: URL = UpdateStorage.defaultRoot) {
        self.root = root
    }

    public func directory(for version: String) -> URL {
        root.appendingPathComponent(version, isDirectory: true)
    }

    public func prepare(version: String) throws -> URL {
        guard Self.isValidVersion(version) else {
            throw UpdateError.downloadFailed
        }

        let manager = FileManager.default
        let directory = directory(for: version)
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    public func discard(version: String) {
        guard Self.isValidVersion(version) else { return }
        try? FileManager.default.removeItem(at: directory(for: version))
    }

    /// A release version is one to three numeric components. Refusing anything
    /// else here matters: the same string becomes a directory name, and `..`
    /// would point at the update store's parent.
    private static func isValidVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// The space macOS says can be made available for important use, which is the
    /// number the app should compare against rather than the raw free-block count.
    public func freeSpace(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    /// Archive, expanded app, and the copy that is replaced: four times the
    /// download plus a fixed margin is comfortably above the real peak.
    public func requiredBytes(forDownloadBytes bytes: Int) -> Int64 {
        max(Int64(bytes) * 4 + 32 * 1024 * 1024, 64 * 1024 * 1024)
    }
}
