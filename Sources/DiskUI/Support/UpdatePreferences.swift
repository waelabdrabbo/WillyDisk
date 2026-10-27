import Foundation
import Observation
import DiskUpdate

/// The stored preferences for update checking.
///
/// This is a preference about the app, not about a scan: it never travels with a
/// scan record. The Settings window and the update controller read the same
/// object, so turning automatic checks off stops the next launch's check without
/// touching the release already offered on screen.
@MainActor
@Observable
public final class UpdatePreferences {
    public static let shared = UpdatePreferences()

    /// How long an attempt, successful or not, defers the next automatic one.
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    private enum Key {
        static let automatic = "updates.checksAutomatically"
        static let lastCheck = "updates.lastCheck"
        static let lastAttempt = "updates.lastAttempt"
        static let skippedVersion = "updates.skippedVersion"
    }

    private let defaults: UserDefaults

    public var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            defaults.set(checksAutomatically, forKey: Key.automatic)
        }
    }

    /// The last check that finished with an answer from the feed. A failure sets
    /// only `lastAttempt`, so Settings never claims a failed request was a check.
    public private(set) var lastCheck: Date?

    /// The last attempt of either kind. This is what the daily interval measures,
    /// so an offline Mac does not retry on every launch.
    public private(set) var lastAttempt: Date?

    public private(set) var skippedVersion: String?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.checksAutomatically = defaults.object(forKey: Key.automatic) as? Bool ?? true
        self.lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
        self.lastAttempt = defaults.object(forKey: Key.lastAttempt) as? Date
        self.skippedVersion = defaults.string(forKey: Key.skippedVersion)
    }

    public func shouldCheck(now: Date = Date()) -> Bool {
        guard checksAutomatically else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Self.checkInterval
    }

    public func recordAttempt(at date: Date) {
        lastAttempt = date
        defaults.set(date, forKey: Key.lastAttempt)
    }

    public func recordSuccess(at date: Date) {
        lastCheck = date
        lastAttempt = date
        defaults.set(date, forKey: Key.lastCheck)
        defaults.set(date, forKey: Key.lastAttempt)
    }

    public func skip(_ version: ReleaseVersion) {
        let text = version.description
        skippedVersion = text
        defaults.set(text, forKey: Key.skippedVersion)
    }

    /// A skipped version hides only that version. A newer release is offered
    /// again; a manual check ignores the skip entirely.
    public func isSkipped(_ version: ReleaseVersion) -> Bool {
        guard let skippedVersion, let skipped = ReleaseVersion(skippedVersion) else {
            return false
        }
        return skipped == version
    }

    public func clearSkip() {
        skippedVersion = nil
        defaults.removeObject(forKey: Key.skippedVersion)
    }
}
