import SwiftUI
import AppKit
import DiskCore

/// What the sunburst chart fills one node with.
///
/// The chart colours by a node's place in the tree, not by its file category: a
/// directory carries no category of its own — it is categorised by its name — so
/// a category-driven chart paints unrelated folders one colour and the tree stops
/// reading. A child of the focused directory therefore opens a colour family of
/// its own, everything below it keeps that family's hue as a paler tint on each
/// ring further out, and the whole subtree reads as one colour.
///
/// The fill is kept as values rather than a resolved `Color`, so it survives a
/// redraw and resolves against the current light or dark appearance only when it
/// is drawn. Everything that shows a node's chart colour — a wedge, and the
/// explorer's icon for the node — reads the same value, so the two panes can
/// never disagree about it.
enum ChartFill: Equatable {
    /// A position in the tree: `hue` in degrees, drawn on `ring` among `rank`
    /// siblings.
    case palette(hue: Double, ring: Int, rank: Int)
    /// The neutral fill for the aggregate "smaller items" wedge, which stands for
    /// several children the chart does not draw individually.
    case aggregate
    /// The neutral fill for a node the chart does not draw — an entry with no
    /// bytes, or one below the chart's density limits.
    case neutral

    /// How the fill is drawn.
    var color: Color {
        switch self {
        case .palette(let hue, let ring, let rank):
            return ChartPalette.color(hue: hue, ring: ring, rank: rank)
        case .aggregate:
            return DS.Color.chartRemainder
        case .neutral:
            return DS.Color.tertiaryText
        }
    }
}

/// Colour assignment for the sunburst chart.
///
/// The chart is coloured by a node's place in the scanned tree, not by its file
/// category. A directory carries no category of its own — it is categorised by
/// its name — so a category-driven chart paints unrelated folders one colour and
/// the tree stops reading. Here every child of the focused directory takes a hue
/// of its own and everything below it keeps that hue as a paler tint on each
/// ring further out, so one subtree reads as a single colour family while the
/// rings stay legible.
///
/// Colour is keyed off a node's path — never its `id`, its category, or its
/// size. The scan engine rebuilds every node value on each progressive snapshot,
/// so paths, and the order of sibling paths, are what hold still while results
/// stream in.
enum ChartPalette {

    /// The hue of one child of the focused directory, in degrees.
    ///
    /// Siblings are ranked by path and spread with a van der Corput
    /// (bit-reversal) sequence. That keeps the wheel well covered however wide
    /// the directory is, and puts entries whose names sit next to each other —
    /// a run of numbered files, say — on opposite sides of the wheel rather than
    /// side by side. Ranking by path, not by size, means a wedge does not change
    /// colour as its neighbours grow during a scan.
    static func rootHue(rank: Int) -> Double {
        normalized(DS.Sunburst.paletteFirstHue + fraction(rank) * 360)
    }

    /// The hue of a node below the first ring, in degrees.
    ///
    /// It stays within `paletteFamilySpread` degrees of its subtree's hue, so
    /// the whole subtree reads as one family, while the siblings inside it still
    /// differ from one another.
    static func descendantHue(familyHue: Double, rank: Int) -> Double {
        let spread = DS.Sunburst.paletteFamilySpread
        return normalized(familyHue - spread + fraction(rank) * 2 * spread)
    }

    /// The fill of every child one ring draws, keyed by the child's path.
    ///
    /// One parent's children are ranked here exactly as they are when the chart
    /// is laid out — by path — so a caller that needs a node's chart colour, such
    /// as the explorer's icon tint, resolves the very fill the wedge is drawn
    /// with. `ring` is the ring those children are drawn in, and `parentFill` the
    /// fill of the parent's own wedge, or `nil` for the focused directory's
    /// children: a child of the focused directory opens a colour family of its
    /// own, and everything below keeps the family hue as the paler tint of the
    /// ring it is drawn on.
    ///
    /// Only the ring's *hue* decision is shared. Whether a child is drawn at all
    /// — the chart's density limits — is the caller's to apply.
    static func fills(
        for children: [ScanNode],
        ring: Int,
        parentFill: ChartFill?
    ) -> [String: ChartFill] {
        let ordered = children.filter(\.isPresentable)
        let ranks = rankByPath(ordered)
        let familyHue: Double? = if case .palette(let hue, _, _) = parentFill { hue } else { nil }

        var fills: [String: ChartFill] = [:]
        for node in ordered {
            let rank = ranks[node.url.path] ?? 0
            let hue = familyHue.map {
                descendantHue(familyHue: $0, rank: rank)
            } ?? rootHue(rank: rank)
            fills[node.url.path] = .palette(hue: hue, ring: ring, rank: rank)
        }
        return fills
    }

    /// The fill for a wedge of `ring` drawn in `hue`.
    ///
    /// `rank` places the wedge among its siblings. Below the first ring it also
    /// shifts the brightness a little, so siblings that share a family hue never
    /// land on the very same fill.
    static func color(hue: Double, ring: Int, rank: Int) -> Color {
        let index = shadeIndex(forRing: ring)
        let nudge = ring >= 2 ? (fraction(rank) - 0.5) * DS.Sunburst.paletteSiblingBrightnessSpread : 0
        return dynamic(
            hue: hue,
            lightSaturation: DS.Sunburst.paletteSaturation[index],
            lightBrightness: clamp(DS.Sunburst.paletteBrightness[index] + nudge),
            darkSaturation: DS.Sunburst.paletteDarkSaturation[index],
            darkBrightness: clamp(DS.Sunburst.paletteDarkBrightness[index] + nudge)
        )
    }

    // MARK: - Internals

    /// One sibling group's ranks, keyed by path.
    ///
    /// Siblings are ranked by path rather than by size: sizes grow as a scan
    /// streams in, and a node's colour must not move while its neighbours
    /// arrive; the relative order of paths never changes.
    private static func rankByPath(_ children: [ScanNode]) -> [String: Int] {
        var ranks: [String: Int] = [:]
        for (index, node) in children.sorted(by: { $0.url.path < $1.url.path }).enumerated() {
            ranks[node.url.path] = index
        }
        return ranks
    }

    /// Van der Corput sequence in base 2: a low-discrepancy spread of `[0, 1)`
    /// across rank numbers, so both early ranks and any handful of them stay far
    /// apart.
    private static func fraction(_ rank: Int) -> Double {
        var value = 0.0
        var denominator = 2.0
        var remaining = max(rank, 0)
        while remaining > 0 {
            value += Double(remaining % 2) / denominator
            remaining /= 2
            denominator *= 2
        }
        return value
    }

    private static func shadeIndex(forRing ring: Int) -> Int {
        min(max(ring - 1, 0), DS.Sunburst.paletteSaturation.count - 1)
    }

    private static func normalized(_ hue: Double) -> Double {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    /// A single `Color` that resolves to a different shade in light and dark
    /// appearances, so the palette keeps its contrast on either background.
    private static func dynamic(
        hue: Double,
        lightSaturation: Double,
        lightBrightness: Double,
        darkSaturation: Double,
        darkBrightness: Double
    ) -> Color {
        let light = nsColor(hue: hue, saturation: lightSaturation, brightness: lightBrightness)
        let dark = nsColor(hue: hue, saturation: darkSaturation, brightness: darkBrightness)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func nsColor(hue: Double, saturation: Double, brightness: Double) -> NSColor {
        let h = normalized(hue) / 60
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
