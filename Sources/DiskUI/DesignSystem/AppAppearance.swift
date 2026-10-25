import AppKit
import DiskLocalization

/// The app's appearance preference: follow the system, or hold one appearance.
///
/// This is a user preference, not scan state, so it is stored in `UserDefaults`
/// under `defaultsKey` and read back through `@AppStorage` by both the control
/// that offers it and the app shell that applies it — they read one value, so
/// they cannot disagree. The app shell applies it as the app's `NSAppearance`;
/// `system` hands the decision back, which is what `nil` means.
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// The `UserDefaults` key the preference is stored under.
    public static let defaultsKey = "appAppearance"

    /// The stored preference, or `system` when the user has never chosen one.
    /// The app shell reads this before it builds a window, so a held-over choice
    /// is in place from the first frame; the appearance menu reads the same value
    /// through `@AppStorage`.
    public static var stored: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap { AppAppearance(rawValue: $0) } ?? .system
    }

    public var id: String { rawValue }

    /// The name the appearance menu shows.
    public var label: String {
        switch self {
        case .system: L10n.string("System")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    /// The symbol the appearance menu shows beside the name.
    public var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Applies the preference to the app object, which every window, panel and
    /// menu inherits. `nil` hands the choice back to the system.
    @MainActor
    public static func apply(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// The appearance the app is pinned to, as the app object takes it. `nil`
    /// follows the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
