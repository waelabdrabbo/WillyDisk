import Foundation
import DiskLocalization

/// The app's interface-language preference: follow the system, or hold one of
/// the catalog's finished languages.
///
/// This is a user preference, not scan state, so it is stored in `UserDefaults`
/// under `defaultsKey` and read through `@AppStorage` by both the Settings
/// picker and the app shell that applies it. The choice pins `L10n` directly, so
/// the interface can change without relaunch; `system` leaves the override
/// empty, which is what lets the catalog follow the preferred languages macOS
/// reports — including a per-app language chosen in System Settings.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case arabic

    /// The `UserDefaults` key the preference is stored under.
    public static let defaultsKey = "appLanguage"

    public var id: String { rawValue }

    /// The catalog language this choice pins, or `nil` to follow the system.
    public var catalogLanguage: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .arabic: "ar"
        }
    }

    /// The stored preference, or `system` when the user has never chosen one.
    public static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: defaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Pins the catalog to the stored preference. The app entry calls this
    /// before SwiftUI builds a menu or a window, so a held-over choice is in
    /// place from the first frame.
    public static func applyStored(in defaults: UserDefaults = .standard) {
        stored(in: defaults).apply()
    }

    /// Pins `L10n` to this choice. `nil` hands the language back to the system.
    public func apply() {
        L10n.overrideLanguage(catalogLanguage)
    }

    /// The name the language picker shows. English and Arabic are written in
    /// their own script, so a reader can find their language whatever language
    /// the interface is currently in; `system` is prose and is translated.
    public var label: String {
        switch self {
        case .system: L10n.string("System")
        case .english: L10n.string("English")
        case .arabic: L10n.string("العربية")
        }
    }
}
