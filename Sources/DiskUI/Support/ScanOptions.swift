import Foundation
import Observation

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
        let hidden = includeHidden ? "Hidden items included" : "Hidden items skipped"
        let volumes = stayOnVolume ? "stays on this volume" : "may cross volumes"
        let links = followSymlinks ? "follows symbolic links" : "symbolic links not followed"
        let exclusions = excludedPaths.isEmpty ? "" : ", \(excludedPaths.count) excluded"
        return "\(hidden), \(volumes), \(links)\(exclusions)"
    }
}

/// Remembers the scan options across launches and shares them with every view
/// that edits them.
///
/// There is one store, not one copy per window: the source screen's Scan
/// Options sheet and the Settings window read and write `shared`, so a change
/// made in either place is immediately the value the other shows. Every
/// mutation is written to `UserDefaults`, and a scan begun from the menu, a
/// drop, or the QA autoscan hook reads the same persisted values.
@MainActor
@Observable
public final class ScanOptionsStore {

    /// The store the app and its windows use.
    public static let shared = ScanOptionsStore()

    private let defaults: UserDefaults

    /// The choices the next scan and Rescan use. Mutating any field persists it
    /// at once, so the value cannot outlive the store and disagree with what a
    /// later launch reads.
    public var options: ScanOptions {
        didSet {
            guard options != oldValue else { return }
            ScanOptionsStore.save(options, defaults: defaults)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.options = ScanOptionsStore.load(defaults: defaults)
    }

    /// Restores every scan option, including the exclusions, to the defaults.
    public func reset() {
        options = .standard
    }

    /// Adds paths the scan should leave out, standardizing each one and ignoring
    /// duplicates that differ only by `..` or a trailing slash.
    public func addExclusions(_ urls: [URL]) {
        var next = options
        var seen = Set(next.excludedPaths.map { $0.standardizedFileURL.path })
        for url in urls {
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            next.excludedPaths.append(standardized)
        }
        guard next.excludedPaths.count != options.excludedPaths.count else { return }
        options = next
    }

    /// Stops excluding a path, matched the same way the scan matches it.
    public func removeExclusion(_ url: URL) {
        let path = url.standardizedFileURL.path
        var next = options
        next.excludedPaths.removeAll { $0.standardizedFileURL.path == path }
        guard next.excludedPaths.count != options.excludedPaths.count else { return }
        options = next
    }

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
