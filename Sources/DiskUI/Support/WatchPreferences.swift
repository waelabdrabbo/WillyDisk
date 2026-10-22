import Foundation
import Observation

/// The stored choice to keep settled results current.
///
/// This is a preference about the screen, not a scan option: it never changes
/// what a scan measures, and it does not travel with a `ScanRecord`. The
/// Settings window and the view model read the same object, so turning it off
/// while results are on screen stops the watch at once.
@MainActor
@Observable
public final class WatchPreferences {
    public static let shared = WatchPreferences()

    private static let key = "results.watchForChanges"

    private let defaults: UserDefaults

    public var keepsResultsCurrent: Bool {
        didSet {
            guard keepsResultsCurrent != oldValue else { return }
            defaults.set(keepsResultsCurrent, forKey: Self.key)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.keepsResultsCurrent = defaults.object(forKey: Self.key) as? Bool ?? true
    }
}
