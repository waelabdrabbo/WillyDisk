import SwiftUI

/// What the pointer or the keyboard emphasises on a chart.
///
/// Every shape keeps the fill the chart gave it. The active shape is washed with
/// signal and outlined at the same weight, and the shapes that contain it are
/// outlined too, so the pointer reads as a path through the tree — a one-level
/// chart has no such trail. The selection is drawn here too, and over the wash,
/// because the wash covers the fill an outline would sit on. Its tone is deepened
/// with ink and it carries the heaviest line in the chart, so "what I clicked"
/// survives the pointer moving on to another shape.
///
/// Every chart paints this layer — the sunburst, the category ring, and the
/// treemap — so their hover and selection cannot drift apart.
struct ChartEmphasis: View {
    /// The shape under the pointer or the keyboard, in the chart's own
    /// coordinate space.
    let active: Path?
    /// The shapes inside `active` that contain it, innermost first.
    let trail: [Path]
    /// The shape the user selected, when the chart draws it.
    let selected: Path?
    let size: CGSize
    /// False under Reduce Motion, where the emphasis appears at once.
    let animates: Bool
    /// The active shape's identity, which the emphasis animates between.
    let activeID: String?

    var body: some View {
        ZStack {
            if let selected {
                selected
                    .fill(DS.Color.ink.opacity(DS.Chart.selectedOverlayOpacity))
            }
            if let active {
                active
                    .fill(DS.Color.signal.opacity(DS.Chart.hoverShadeOpacity))
                // Ancestors first: the shape under the pointer keeps the top line.
                ForEach(trail.indices, id: \.self) { index in
                    trail[index]
                        .stroke(DS.Color.signal, lineWidth: DS.Chart.hoverStrokeWidth)
                        .opacity(DS.Opacity.hoverAncestor)
                }
                active
                    .stroke(DS.Color.signal, lineWidth: DS.Chart.hoverStrokeWidth)
            }
            if let selected {
                // The selected shape carries the heaviest line in the chart.
                selected
                    .stroke(DS.Color.signal, lineWidth: DS.Chart.selectedStrokeWidth)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(
            animates ? .easeOut(duration: DS.Chart.emphasisAnimationDuration) : nil,
            value: activeID
        )
        // The emphasis is a picture of the pointer, never a target. The shapes
        // underneath remain the controls.
        .allowsHitTesting(false)
    }
}
