import SwiftUI
import AppKit
import DiskCore

/// What the sunburst chart fills one node with.
///
/// The chart is one material seen at depth, not a set of colour families: ink
/// mixed from a single cool hue, darkest on the ring nearest the centre and paler
/// on each ring further out. Depth is therefore the only thing tone says. Siblings
/// on one ring cycle through three neighbouring tones so touching wedges separate,
/// and the cycle is keyed by path order, which holds still while a scan streams
/// results in.
///
/// The fill is kept as values rather than a resolved `Color`, so it survives a
/// redraw and resolves against the current light or dark appearance only when it
/// is drawn. Everything that shows a node's chart colour — a wedge, and the
/// explorer's icon for the node — reads the same value, so the two panes can
/// never disagree about it.
enum ChartFill: Equatable {
    /// A wedge on `ring` (1 is the focused directory's children) wearing sibling
    /// tone `step`, 0...2.
    case tone(ring: Int, step: Int)
    /// The neutral fill for the aggregate "smaller items" wedge, which stands for
    /// several children the chart does not draw individually.
    case aggregate
    /// The neutral fill for a node the chart does not draw — an entry with no
    /// bytes, or one below the chart's density limits.
    case neutral

    /// How the fill is drawn.
    var color: Color {
        switch self {
        case .tone(let ring, let step):
            return ChartPalette.color(ring: ring, step: step)
        case .aggregate:
            return DS.Color.rule
        case .neutral:
            // A fill fallback, never text. Graphite rather than the palest tone so
            // an icon for an undrawn node is still visible in a list.
            return DS.Color.graphite
        }
    }
}

/// Tone assignment for the sunburst chart.
///
/// A wedge's tone is a function of two things only: the ring it is drawn on, and
/// its place in its parent's path-ordered sibling list. Nothing about the current
/// pointer, selection, or the sizes the scan has counted so far takes part, so a
/// wedge keeps its fill from the first partial snapshot to the settled scan.
///
/// Siblings are ranked by path rather than by size because sizes grow as a scan
/// streams in: ranking by size would repaint the ring on every snapshot. The
/// three tones are a cycle, so the first, fourth, and seventh child of a wide
/// directory share one — the enamel gap between wedges, not the tone, is what
/// guarantees that two touching wedges separate.
enum ChartPalette {

    /// The fill of every child one ring draws, keyed by the child's path.
    ///
    /// Every presentable child takes part in the ranking. A folder that has not
    /// been walked yet still holds its place in the order, so the tones of the
    /// entries already on screen do not move as the rest of the folder arrives.
    static func fills(for children: [ScanNode], ring: Int) -> [String: ChartFill] {
        var fills: [String: ChartFill] = [:]
        for (rank, node) in children.sorted(by: { $0.url.path < $1.url.path }).enumerated()
        where node.isPresentable {
            fills[node.url.path] = .tone(ring: ring, step: step(rank: rank))
        }
        return fills
    }

    /// The fill for a wedge of `ring` wearing sibling `step`.
    static func color(ring: Int, step: Int) -> Color {
        let index = ringIndex(ring)
        let offset = DS.Sunburst.toneStepOffset * Double(clampedStep(step) - 1)
        return dynamic(
            lightSaturation: DS.Sunburst.toneLightSaturation[index],
            lightBrightness: clamp(DS.Sunburst.toneLightBrightness[index] + offset),
            darkSaturation: DS.Sunburst.toneDarkSaturation[index],
            darkBrightness: clamp(DS.Sunburst.toneDarkBrightness[index] + offset)
        )
    }

    /// The fill for one slice of the category ring.
    ///
    /// The category view has no depth to colour by, so the single hue is stepped
    /// across the ring instead: the largest slice is the darkest in the light
    /// appearance and the brightest in the dark one, and every neighbour sits a
    /// step apart. That keeps the one-material rule — no second colour family —
    /// while letting five slices read as five.
    static func categoryColor(index: Int, count: Int) -> Color {
        let slices = max(count, 1)
        let last = max(slices - 1, 1)
        let position = slices == 1 ? 0 : Double(min(max(index, 0), slices - 1)) / Double(last)
        return dynamic(
            lightSaturation: 0.20 - 0.06 * position,
            lightBrightness: 0.40 + 0.42 * position,
            darkSaturation: 0.16 - 0.04 * position,
            darkBrightness: 0.88 - 0.40 * position
        )
    }

    // MARK: - Internals

    /// A sibling's position in the three-tone cycle, by path rank.
    private static func step(rank: Int) -> Int {
        ((rank % 3) + 3) % 3
    }

    private static func clampedStep(_ step: Int) -> Int {
        min(max(step, 0), 2)
    }

    private static func ringIndex(_ ring: Int) -> Int {
        min(max(ring - 1, 0), DS.Sunburst.toneLightBrightness.count - 1)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// A single `Color` that resolves to a different tone in light and dark
    /// appearances, so the ladder keeps its order on either background.
    private static func dynamic(
        lightSaturation: Double,
        lightBrightness: Double,
        darkSaturation: Double,
        darkBrightness: Double
    ) -> Color {
        let light = nsColor(saturation: lightSaturation, brightness: lightBrightness)
        let dark = nsColor(saturation: darkSaturation, brightness: darkBrightness)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func nsColor(saturation: Double, brightness: Double) -> NSColor {
        let h = DS.Sunburst.toneHue / 60
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let base: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: base = (chroma, second, 0)
        case 1: base = (second, chroma, 0)
        case 2: base = (0, chroma, second)
        case 3: base = (0, second, chroma)
        case 4: base = (second, 0, chroma)
        default: base = (chroma, 0, second)
        }
        let match = brightness - chroma
        return NSColor(srgbRed: base.0 + match, green: base.1 + match, blue: base.2 + match, alpha: 1)
    }
}
