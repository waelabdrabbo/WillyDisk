import AppKit
import SwiftUI

/// Leaves the window itself as first responder when a screen appears.
///
/// AppKit gives the first eligible key view initial focus, which paints a focus
/// ring on whichever row or toolbar button happens to be first. macOS windows
/// otherwise show focus only after the first Tab or click, so the ring is
/// cleared once layout has settled. It is not a focus trap: Tab starts the key
/// loop from the beginning as usual.
struct WindowFocusReset: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in
            view?.window?.makeFirstResponder(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
