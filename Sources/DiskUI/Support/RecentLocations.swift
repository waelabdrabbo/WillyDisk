import Foundation

/// A small, `UserDefaults`-backed list of recently scanned locations.
public enum RecentLocations {
    private static let key = "WillyDisk.RecentLocations"
    private static let maxCount = 8

    /// Loads recently scanned roots, filtering out ones that no longer exist.
    public static func load() -> [URL] {
        guard let strings = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return strings
            .compactMap(URL.init(string:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Records a location at the front of the list (deduplicated, capped).
    public static func record(_ url: URL) {
        var list = load()
        list.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        list.insert(url, at: 0)
        list = Array(list.prefix(maxCount))
        UserDefaults.standard.set(list.map(\.absoluteString), forKey: key)
    }
}
