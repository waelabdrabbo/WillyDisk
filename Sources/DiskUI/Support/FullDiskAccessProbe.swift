import Foundation

/// Detects Full Disk Access by probing a TCC-protected path.
///
/// macOS exposes no public API for the Full Disk Access grant, so the only
/// honest check is whether a file the system protects can actually be read.
/// A successful read means the grant is in place; a permission error, a
/// missing path, or any other failure is treated as *not* granted, because
/// assuming access that is not there would silently hide the restricted
/// locations a scan skipped.
public enum FullDiskAccessProbe {

    /// Files that are readable only with Full Disk Access, richest first.
    ///
    /// The candidates are read in order and the first successful read wins, so
    /// removing or renaming one of them on a future OS does not make the probe
    /// report a false denial.
    private static let protectedPaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/History.db",
        "Library/Messages/chat.db",
    ]

    /// Reads a protected path off the main thread — it is file I/O.
    public static func isGranted() async -> Bool {
        await Task.detached(priority: .utility) { readsProtectedPath() }.value
    }

    private static func readsProtectedPath() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for relative in protectedPaths {
            let url = home.appendingPathComponent(relative)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            if (try? handle.read(upToCount: 1)) != nil { return true }
        }
        return false
    }
}
