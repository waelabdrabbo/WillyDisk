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

    /// The display names shared by more than one of `urls`.
    ///
    /// A recent row shows the path of a colliding name instead of its last run:
    /// two rows reading only "Documents" cannot be told apart, and the path can
    /// say which one is which.
    public static func repeatedNames(in urls: [URL]) -> Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for url in urls {
            let name = LocationName.of(url)
            if !seen.insert(name).inserted {
                repeated.insert(name)
            }
        }
        return repeated
    }
}
