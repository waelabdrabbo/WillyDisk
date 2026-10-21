import SwiftUI

/// What the pointer or the keyboard emphasises on a wedge chart.
///
/// Every wedge keeps the fill the chart gave it. The active wedge is washed with
/// signal and outlined at the same weight, and the wedges that contain it are
/// outlined too, so the pointer reads as a path through the tree — a one-ring
/// chart has no such trail. The selection is drawn here too, and over the wash,
/// because the wash covers the fill an outline would sit on. Its tone is deepened
/// with ink and it carries the heaviest line in the chart, so "what I clicked"
/// survives the pointer moving on to another wedge.
///
/// The sunburst and the category ring both paint this layer, so their hover and
/// selection cannot drift apart.
struct WedgeEmphasis: View {
    /// The wedge under the pointer or the keyboard.
    let active: SunburstWedge?
    /// The wedges inside `active` that contain it, innermost first.
    let trail: [SunburstWedge]
    /// The wedge the user selected, when the chart draws it.
    let selected: SunburstWedge?
    let side: CGFloat
    /// False under Reduce Motion, where the emphasis appears at once.
    let animates: Bool
    /// The active wedge's identity, which the emphasis animates between.
    let activeID: String?

    var body: some View {
        ZStack {
            if let selected {
                WedgeShade(wedges: [selected])
                    .fill(DS.Color.ink.opacity(DS.Sunburst.selectedOverlayOpacity))
            }
            if let active {
                WedgeShade(wedges: [active])
                    .fill(DS.Color.signal.opacity(DS.Sunburst.hoverShadeOpacity))
                // Ancestors first: the wedge under the pointer keeps the top line.
                ForEach(trail.indices, id: \.self) { index in
                    trail[index]
                        .stroke(DS.Color.signal, lineWidth: DS.Sunburst.hoverStrokeWidth)
                        .opacity(DS.Opacity.hoverAncestor)
                }
                active
                    .stroke(DS.Color.signal, lineWidth: DS.Sunburst.hoverStrokeWidth)
            }
            if let selected {
                // The selected wedge carries the heaviest line in the chart.
                selected
                    .stroke(DS.Color.signal, lineWidth: DS.Sunburst.selectedStrokeWidth)
            }
        }
        .frame(width: side, height: side)
        .animation(
            animates ? .easeOut(duration: DS.Sunburst.emphasisAnimationDuration) : nil,
            value: activeID
        )
        // The emphasis is a picture of the pointer, never a target. The wedges
        // underneath remain the controls.
        .allowsHitTesting(false)
    }
}

/// The emphasised wedges, filled as shapes of their own.
///
/// A chart is drawn on the platter, so washing one wedge with a translucent
/// surface deepens that wedge without touching its neighbours or the enamel gaps
/// between wedges.
private struct WedgeShade: Shape {
    var wedges: [SunburstWedge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for wedge in wedges {
            path.addPath(wedge.path(in: rect))
        }
        return path
    }
}
