import SwiftUI
import DiskCore
import DiskLocalization

/// UI presentation mapping for the frozen `FileCategory` model.
///
/// Lives in DiskUI (not DiskCore) so the shared model stays presentation-free.
/// Provides a stable SF Symbol + display name for every category.
extension FileCategory {

    /// Human-readable name for labels and accessibility.
    public var displayName: String {
        switch self {
        case .applications: L10n.string("Applications")
        case .documents: L10n.string("Documents")
        case .images: L10n.string("Images")
        case .video: L10n.string("Video")
        case .audio: L10n.string("Audio")
        case .archives: L10n.string("Archives")
        case .code: L10n.string("Code")
        case .system: L10n.string("System")
        case .other: L10n.string("Other")
        }
    }

    /// SF Symbol used throughout the UI for this category.
    public var symbolName: String {
        switch self {
        case .applications: "app.badge"
        case .documents: "doc.text"
        case .images: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .archives: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .system: "gearshape.2"
        case .other: "square.grid.2x2"
        }
    }
}
