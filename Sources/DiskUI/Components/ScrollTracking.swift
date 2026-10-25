import SwiftUI

// MARK: - Scroll tracking

/// Reports a scroll view's phases to its owner.
///
/// A list that keeps its hover off the rows moving under a still pointer needs to
/// know when the content moves. `ScrollPhase` arrives with macOS 15; on macOS 14
/// the view keeps the behaviour it had before.
struct ScrollActivityReporter: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                onChange(phase.isScrolling)
            }
        } else {
            content
        }
    }
}

/// Reports a scroll view's content offset to its owner.
///
/// The offset changes on every frame of a scroll and is read once, when the
/// scroll settles, so the owner should keep it in a reference box rather than
/// view state.
struct ScrollOffsetReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                onChange(offset)
            }
        } else {
            content
        }
    }
}
