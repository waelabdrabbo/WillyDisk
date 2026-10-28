import Foundation
import Observation
import DiskCore
import DiskLocalization

/// How a cleanup rule and its tier read on screen.
///
/// The rules are `DiskCore`'s and carry no strings of their own, so the command
/// line can run them without loading a UI. Wording lives here, next to the sheet
/// that shows it.
extension CleanupRule {
    var title: String {
        switch self {
        case .caches: L10n.string("Caches")
        case .developerSupport: L10n.string("Device support")
        case .simulators: L10n.string("Simulators")
        case .logs: L10n.string("Logs")
        case .downloads: L10n.string("Old downloads")
        case .largeAndOld: L10n.string("Large and old")
        }
    }

    /// Why this rule exists, in the terms of what removing one costs.
    func explanation(policy: CleanupPolicy) -> String {
        switch self {
        case .caches:
            return L10n.string("Folders named Caches directly inside a Library, and Xcode's Derived Data, offered whole. The apps that made them rebuild them; moving one can cost a rebuild until they do.")
        case .developerSupport:
            return L10n.string("Xcode's device support folders, one per system version, offered whole. Xcode downloads the one it needs again the next time a device on that version is connected.")
        case .simulators:
            return L10n.string("Every simulator device, offered whole. Xcode makes a new one on demand; deleting one also removes the apps and the data inside it.")
        case .logs:
            return L10n.string("Log folders directly inside a Library, offered whole. Apps and macOS write new logs as they run.")
        case .downloads:
            return L10n.format(
                "Files in a folder named Downloads that have not been modified in %@.",
                cleanupAgeLabel(policy.downloadAge)
            )
        case .largeAndOld:
            return L10n.format(
                "Files that take at least %@ on disk and have not been modified in %@.",
                ByteFormat.string(policy.largeFileMinimum),
                cleanupAgeLabel(policy.largeFileAge)
            )
        }
    }
}

extension CleanupTier {
    var title: String {
        switch self {
        case .rebuildable: L10n.string("Rebuildable")
        case .personal: L10n.string("Your files")
        }
    }

    /// What the tier means for a bulk action.
    var explanation: String {
        switch self {
        case .rebuildable:
            return L10n.string("The app that made these rebuilds them. You can select a whole section here.")
        case .personal:
            return L10n.string("Nothing here is rebuilt for you. Choose each item yourself.")
        }
    }
}

/// A span of time in the units the cleanup thresholds use.
func cleanupAgeLabel(_ interval: TimeInterval) -> String {
    let days = Int(interval / 86_400)
    if days >= 360 {
        return L10n.format("%lld years", max(1, days / 365))
    }
    if days >= 30 {
        return L10n.format("%lld months", max(1, days / 30))
    }
    return L10n.format("%lld days", max(1, days))
}

/// The cleanup sheet's change token.
///
/// The sheet reads it in its own body, so a watcher batch that keeps the results
/// tree current re-runs the cleanup walk even though the sheet is a separate
/// view subtree from the results screen.
@MainActor
@Observable
public final class CleanupRefresh {
    public var revision: Int

    public init(revision: Int = 0) {
        self.revision = revision
    }
}
