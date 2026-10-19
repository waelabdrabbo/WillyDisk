import Foundation

/// The choices a scan is started with.
///
/// The source screen shows them before a scan begins, and Rescan repeats them,
/// because each one changes what the totals mean: hidden items can be most of a
/// home folder, another volume is not this one's storage, and a followed link
/// counts bytes that belong elsewhere.
public struct ScanOptions: Equatable, Sendable {

    /// Follow symbolic links instead of recording the link itself.
    public var followSymlinks: Bool

    /// Do not cross into another mounted volume through a mount point.
    public var stayOnVolume: Bool

    /// Include names macOS hides, such as `~/Library`, dotfiles, and caches.
    public var includeHidden: Bool

    /// Absolute paths the walk leaves out entirely. They are shown before the
    /// scan so the totals are never narrowed invisibly.
    public var excludedPaths: [URL]

    public init(
        followSymlinks: Bool = false,
        stayOnVolume: Bool = true,
        includeHidden: Bool = true,
        excludedPaths: [URL] = []
    ) {
        self.followSymlinks = followSymlinks
        self.stayOnVolume = stayOnVolume
        self.includeHidden = includeHidden
        self.excludedPaths = excludedPaths
    }

    /// The defaults every scan starts from.
    public static let standard = ScanOptions()

    /// One sentence naming the choices, for a caption beside the scan action.
    public var summary: String {
        let hidden = includeHidden ? "hidden items included" : "hidden items skipped"
        let volumes = stayOnVolume ? "stays on this volume" : "may cross volumes"
        let links = followSymlinks ? "follows symbolic links" : "symbolic links not followed"
        let exclusions = excludedPaths.isEmpty ? "" : " · \(excludedPaths.count) excluded"
        return "\(hidden) · \(volumes) · \(links)\(exclusions)"
    }
}

/// Remembers the last scan options across launches.
///
/// The preference is read when a scan starts, not when the app launches, so a
/// scan begun from the menu, a drop, or the QA autoscan hook uses the same
/// choices the source screen shows.
public enum ScanOptionsStore {

    private enum Key {
        static let followSymlinks = "scanOptions.followSymlinks"
        static let stayOnVolume = "scanOptions.stayOnVolume"
        static let includeHidden = "scanOptions.includeHidden"
        static let excludedPaths = "scanOptions.excludedPaths"
    }

    public static func load(defaults: UserDefaults = .standard) -> ScanOptions {
        var options = ScanOptions.standard
        if let value = defaults.object(forKey: Key.followSymlinks) as? Bool {
            options.followSymlinks = value
        }
        if let value = defaults.object(forKey: Key.stayOnVolume) as? Bool {
            options.stayOnVolume = value
        }
        if let value = defaults.object(forKey: Key.includeHidden) as? Bool {
            options.includeHidden = value
        }
        if let paths = defaults.stringArray(forKey: Key.excludedPaths) {
            options.excludedPaths = paths.map { URL(fileURLWithPath: $0) }
        }
        return options
    }

    public static func save(_ options: ScanOptions, defaults: UserDefaults = .standard) {
        defaults.set(options.followSymlinks, forKey: Key.followSymlinks)
        defaults.set(options.stayOnVolume, forKey: Key.stayOnVolume)
        defaults.set(options.includeHidden, forKey: Key.includeHidden)
        defaults.set(options.excludedPaths.map { $0.standardizedFileURL.path }, forKey: Key.excludedPaths)
    }
}
