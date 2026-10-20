import Foundation

/// A one-click location from the source screen.
///
/// A preset is only a starting point: it starts the same scan as choosing the
/// folder by hand, with the same options and the same permission handling.
public struct ScanPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let symbolName: String
    public let url: URL
    /// Whether the location exists on this Mac right now.
    public var isAvailable: Bool

    public init(id: String, name: String, symbolName: String, url: URL, isAvailable: Bool = true) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.url = url
        self.isAvailable = isAvailable
    }
}

/// The preset locations WillyDisk offers.
public enum ScanPresetCatalog {

    /// The presets worth offering, before checking which exist.
    public static let candidates: [ScanPreset] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ScanPreset(
                id: "home",
                name: "Home",
                symbolName: "house",
                url: home
            ),
            ScanPreset(
                id: "downloads",
                name: "Downloads",
                symbolName: "arrow.down.circle",
                url: home.appendingPathComponent("Downloads", isDirectory: true)
            ),
            ScanPreset(
                id: "applications",
                name: "Applications",
                symbolName: "macwindow",
                url: URL(fileURLWithPath: "/Applications", isDirectory: true)
            ),
            ScanPreset(
                id: "caches",
                name: "Caches",
                symbolName: "archivebox",
                url: home.appendingPathComponent("Library/Caches", isDirectory: true)
            ),
            ScanPreset(
                id: "derived-data",
                name: "Derived Data",
                symbolName: "hammer",
                url: home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
            ),
            ScanPreset(
                id: "trash",
                name: "Trash",
                symbolName: "trash",
                url: home.appendingPathComponent(".Trash", isDirectory: true)
            ),
        ]
    }()

    /// Checks which presets exist without touching the filesystem on the main
    /// actor. A missing location stays in the list, visibly unavailable, rather
    /// than disappearing between launches.
    public static func resolved() async -> [ScanPreset] {
        let candidates = candidates
        return await Task.detached(priority: .utility) {
            candidates.map { preset in
                var preset = preset
                preset.isAvailable = FileManager.default.fileExists(atPath: preset.url.path)
                return preset
            }
        }.value
    }
}
