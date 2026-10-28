import Foundation
import DiskLocalization

/// The app's chart preference: the sunburst the app has always drawn, or the
/// treemap.
///
/// This is a user preference, not scan state, so it is stored in `UserDefaults`
/// under `defaultsKey` and read back through `@AppStorage` by both the Settings
/// window that offers it and the results screen that draws it — they read one
/// value, so the two cannot disagree. The sunburst stays the default: it is the
/// chart the app's identity is drawn from, and the treemap exists for folders
/// where arcs are too thin to compare.
public enum AppChartStyle: String, CaseIterable, Identifiable, Sendable {
    case sunburst
    case treemap

    /// The `UserDefaults` key the preference is stored under.
    public static let defaultsKey = "appChartStyle"

    /// The stored preference, or `sunburst` when the user has never chosen one.
    public static var stored: AppChartStyle {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap { AppChartStyle(rawValue: $0) } ?? .sunburst
    }

    public var id: String { rawValue }

    /// The name the Settings picker shows.
    public var label: String {
        switch self {
        case .sunburst: L10n.string("Sunburst")
        case .treemap: L10n.string("Treemap")
        }
    }
}
