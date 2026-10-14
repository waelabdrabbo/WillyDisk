import SwiftUI
import DiskCore

/// UI presentation mapping for the frozen `FileCategory` model.
///
/// Lives in DiskUI (not DiskCore) so the shared model stays presentation-free.
/// Provides a stable color + SF Symbol + display name for every category.
extension FileCategory {

    /// Human-readable name for labels and accessibility.
    public var displayName: String {
        switch self {
        case .applications: "Applications"
        case .documents: "Documents"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .archives: "Archives"
        case .code: "Code"
        case .system: "System"
        case .other: "Other"
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

    /// A consistent, accessible tint for this category (light + dark adaptive).
    ///
    /// Each category keeps a hue of its own: the chart also draws a neutral wedge
    /// for the small items it groups together, so no category may take that grey.
    public var tint: SwiftUI.Color {
        switch self {
        case .applications: SwiftUI.Color(nsColor: .systemBlue)
        case .documents: SwiftUI.Color(nsColor: .systemGreen)
        case .images: SwiftUI.Color(nsColor: .systemPurple)
        case .video: SwiftUI.Color(nsColor: .systemPink)
        case .audio: SwiftUI.Color(nsColor: .systemOrange)
        case .archives: SwiftUI.Color(nsColor: .systemTeal)
        case .code: SwiftUI.Color(nsColor: .systemIndigo)
        case .system: SwiftUI.Color(nsColor: .systemYellow)
        case .other: SwiftUI.Color(nsColor: .systemBrown)
        }
    }
}
