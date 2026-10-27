import SwiftUI
import AppKit

/// Fits a fixed window or sheet to the screen it opens on.
///
/// The design sizes are the content's ideal sizes. A 1280×800 Mac can have less
/// visible height than the Settings window's 760 points plus window chrome, so
/// the frame is capped to the screen's visible frame and the content's own
/// scroll area takes the difference. The margin leaves room for the titlebar,
/// the menu bar, and the Dock without guessing at each one.
enum SheetSizing {
    static let margin: CGFloat = 24

    /// The requested size, capped to the visible frame. A very small screen
    /// still gets a usable minimum rather than a negative or zero frame.
    static func fitted(width: CGFloat, height: CGFloat, visible: CGRect) -> CGSize {
        CGSize(
            width: min(width, max(320, visible.width - 2 * margin)),
            height: min(height, max(320, visible.height - 2 * margin))
        )
    }

    /// The screen a window or sheet is opening on. The main screen when there
    /// is one, otherwise the first screen; a headless renderer gets a sensible
    /// desktop-sized fallback and therefore keeps the design size.
    @MainActor
    static var visibleFrame: CGRect {
        (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

extension View {
    /// A fixed content size that fits the screen it is presented on.
    @MainActor
    func dsFittedFrame(width: CGFloat, height: CGFloat) -> some View {
        let size = SheetSizing.fitted(
            width: width,
            height: height,
            visible: SheetSizing.visibleFrame
        )
        return frame(width: size.width, height: size.height)
    }
}
