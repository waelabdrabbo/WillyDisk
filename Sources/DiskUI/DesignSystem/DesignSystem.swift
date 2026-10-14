import SwiftUI
import AppKit

/// WillyDisk design tokens — the single source of truth for spacing, corner
/// radii, typography, and semantic colors.
///
/// UI never hard-codes magic numbers; it references these tokens so the visual
/// language stays consistent and easy to adjust. Typography is SF Pro (the
/// system font on macOS); semantic colors adapt to light and dark automatically.
public enum DS {

    // MARK: - Spacing (8-pt base grid)

    public enum Spacing {
        public static let hairline: CGFloat = 1
        public static let xxSmall: CGFloat = 2
        public static let xSmall: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xLarge: CGFloat = 20
        public static let xxLarge: CGFloat = 24
        public static let section: CGFloat = 32
    }

    // MARK: - Corner radii

    public enum Radius {
        public static let small: CGFloat = 4
        public static let medium: CGFloat = 6
        public static let large: CGFloat = 8
        public static let panel: CGFloat = 12
    }

    // MARK: - Icon sizes

    /// Point sizes for SF Symbol glyphs, so decorative imagery stays on the
    /// same scale as the type ramp.
    public enum Icon {
        public static let hero: SwiftUI.Font = .system(size: 54)
        public static let large: SwiftUI.Font = .system(size: 42)
        public static let dropTarget: SwiftUI.Font = .system(size: 34)
        public static let medium: SwiftUI.Font = .system(size: 28)
        public static let small: SwiftUI.Font = .system(size: 20)
        public static let inline: SwiftUI.Font = .system(size: 11)
        public static let detail: SwiftUI.Font = .system(size: 10)
        public static let disclosure: SwiftUI.Font = .system(size: 10, weight: .semibold)
        public static let crumb: SwiftUI.Font = .system(size: 9, weight: .semibold)
    }

    // MARK: - Element sizes

    public enum Size {
        /// Minimum width for an action button, so labels align across screens.
        public static let actionMinWidth: CGFloat = 120
        /// Minimum width for the widest primary action (source pickers).
        public static let wideActionMinWidth: CGFloat = 180
        /// Fixed width of a volume's usage gauge.
        public static let gaugeWidth: CGFloat = 120
        /// Pane bounds in the results screen's split view.
        public static let chartPaneMinWidth: CGFloat = 320
        public static let chartPaneIdealWidth: CGFloat = 460
        public static let explorerPaneMinWidth: CGFloat = 300
        public static let explorerPaneIdealWidth: CGFloat = 360
        /// Width of the strip that covers the results split's dividing line. It is
        /// centred on the split, so it spans the divider's hairline and overlaps
        /// each pane by half its width, leaving chart and explorer reading as one
        /// surface.
        public static let splitDividerCoverWidth: CGFloat = 3
        /// Progress bar bounds in the in-progress header.
        public static let progressBarMinWidth: CGFloat = 160
        public static let progressBarMaxWidth: CGFloat = 320
        /// Width of the compact progress bar a source row shows while its
        /// location is being scanned.
        public static let rowProgressWidth: CGFloat = 88
        /// Height of the scan-status strip at the bottom of the chart pane.
        /// Fixed, so the chart keeps its size whether or not a scan is running.
        public static let scanStatusStripHeight: CGFloat = 40
        /// Minimum height of the results footer's storage strip: the bar, one
        /// legend line and the strip's padding. Held even before results arrive,
        /// so the panes above never resize once the first snapshot lands.
        public static let storageStripMinHeight: CGFloat = 54
        /// Label column width in a detail row.
        public static let detailLabelWidth: CGFloat = 60
        /// Diameter of a small status dot (the live-results badge).
        public static let statusDot: CGFloat = 6
        /// Height of the slim storage-by-category bar in the footer strip.
        public static let storageBarHeight: CGFloat = 8
        /// Diameter of a legend swatch.
        public static let legendSwatch: CGFloat = 8
        /// Tallest the restricted-locations list grows before it scrolls.
        public static let accessListMaxHeight: CGFloat = 150
    }

    // MARK: - Opacity

    /// Fill opacities for the explorer rows. Hover sits clearly below
    /// selection, so "where the pointer is" never reads as "what I clicked".
    public enum Opacity {
        public static let rowHover: Double = 0.08
        public static let rowSelection: Double = 0.15
    }

    // MARK: - Strokes

    public enum Stroke {
        /// Border width for surfaces, wells, and chart separators.
        public static let hairline: CGFloat = 0.5
        /// Emphasis border for a highlighted or focused element.
        public static let emphasis: CGFloat = 1.5
        /// Border width for the element the explorer has selected. Wider than the
        /// hover/focus emphasis so a selection stays legible where it crosses the
        /// chart's own separators.
        public static let selection: CGFloat = 2.5
    }

    // MARK: - Sunburst chart geometry

    /// Geometry and density limits for the sunburst chart. Angles are derived
    /// from node sizes; these are the presentation constants on top of that.
    public enum Sunburst {
        /// Outer radius as a fraction of the chart's half-extent, leaving a
        /// hairline of breathing room inside the pane.
        public static let outerRadiusFraction: CGFloat = 0.98
        /// Centre disc radius as a fraction of the outer radius.
        public static let centerRadiusFraction: CGFloat = 0.26
        /// Rings drawn below the centre (ring 1 = the focused directory's children).
        public static let maxRings = 3
        /// Largest number of children a single ring draws before the rest are
        /// grouped into one truthful "smaller items" wedge.
        public static let maxChildrenPerNode = 12
        /// Hard ceiling on the wedges drawn at once.
        ///
        /// `maxChildrenPerNode` caps one parent, not the chart: ring 2 can hold a
        /// wedge for every child of every ring-1 directory, and ring 3 multiplies
        /// that again, so a folder of many medium subdirectories would otherwise
        /// put thousands of live controls on screen. Once the budget is spent the
        /// chart stops drawing deeper rings; each parent that is already drawn
        /// keeps its own truthful angle, and children it does not draw
        /// individually are still accounted for by its aggregate wedge.
        public static let maxSegments = 256
        /// Smallest angular sweep a wedge keeps (radians), so a tiny share still
        /// draws as a hairline instead of collapsing to nothing.
        public static let minimumWedgeSweep: Double = 0.0005
        /// Smallest radial band a wedge keeps, in points.
        public static let minimumBandWidth: CGFloat = 0.5
        /// Below this side length the chart is too small to read and a compact
        /// list state is shown instead.
        public static let minimumSize: CGFloat = 140
        /// Angular gap between adjacent wedges at the inner radius.
        public static let angularGap: Double = 0.006
        /// Radial gap between rings, in points.
        public static let radialGap: CGFloat = 1
        /// Width of the centre disc's label block, as a fraction of its radius.
        public static let centerLabelWidthFraction: CGFloat = 1.7
        /// Wedge opacity, and the opacity other wedges drop to while one is hovered.
        /// A chart-coloured icon wears it too, so a node's icon and its wedge land
        /// on the same colour against the same background.
        public static let fillOpacity: Double = 0.92
        public static let dimmedOpacity: Double = 0.45
        /// Fill opacity of the selected wedge: at full strength it reads as the
        /// brightest wedge in the chart, including while another is hovered.
        public static let selectedFillOpacity: Double = 1
        /// Opacity of the selected wedge's outline. High enough to stand apart
        /// from both the hairlines between the other wedges and the softer
        /// hover/focus emphasis.
        public static let selectedStrokeOpacity: Double = 0.85

        // MARK: Tree-position palette
        //
        // The chart is coloured by where a node sits in the tree, so one subtree
        // reads as a single colour family and unrelated folders never share a
        // fill. These are the hues and shades behind that mapping; the sibling
        // ordering and hue arithmetic live in `ChartPalette`.
        //
        // Each array is indexed by distance from the focused directory: entry 0
        // is the focused directory's children, the entry after it their children,
        // and so on. One family is one hue, with every ring a tint of it: the
        // nearest ring is the most saturated and each ring further out is paler —
        // saturation down, brightness up. Depth therefore reads as the same colour
        // going lighter, and the rim is the airiest ring in the chart.

        /// Hue, in degrees, of the first child of the focused directory. The rest
        /// of the ring follows evenly around the wheel.
        public static let paletteFirstHue: Double = 205
        /// How far, in degrees either side, a descendant's hue may drift from its
        /// subtree's hue. Small enough that a family reads as one hue while
        /// sibling folders in it still differ.
        public static let paletteFamilySpread: Double = 6
        /// Saturation of a palette wedge, nearest ring first, in the light
        /// appearance.
        public static let paletteSaturation: [Double] = [0.72, 0.50, 0.28]
        /// Brightness of a palette wedge, nearest ring first, light appearance.
        public static let paletteBrightness: [Double] = [0.91, 0.94, 0.97]
        /// Saturation of a palette wedge, nearest ring first, dark appearance.
        public static let paletteDarkSaturation: [Double] = [0.78, 0.56, 0.34]
        /// Brightness of a palette wedge, nearest ring first, dark appearance.
        public static let paletteDarkBrightness: [Double] = [0.93, 0.96, 0.98]
        /// Brightness range shared across the siblings of one descendant group,
        /// so folders in the same family never land on the same fill.
        public static let paletteSiblingBrightnessSpread: Double = 0.14
    }

    // MARK: - Typography (SF Pro roles)

    public enum Typography {
        public static let largeTitle: SwiftUI.Font = .system(size: 26, weight: .bold)
        public static let title: SwiftUI.Font = .system(size: 22, weight: .bold)
        public static let title2: SwiftUI.Font = .system(size: 17, weight: .semibold)
        public static let headline: SwiftUI.Font = .system(size: 15, weight: .semibold)
        public static let body: SwiftUI.Font = .system(size: 13, weight: .regular)
        public static let callout: SwiftUI.Font = .system(size: 12, weight: .regular)
        public static let caption: SwiftUI.Font = .system(size: 11, weight: .regular)
        public static let metric: SwiftUI.Font = .system(size: 28, weight: .semibold, design: .rounded)
        public static let monospaced: SwiftUI.Font = .system(size: 12, weight: .regular, design: .monospaced)
    }

    // MARK: - Semantic colors (light + dark adaptive)

    public enum Color {
        public static let accent: SwiftUI.Color = .accentColor
        public static let primaryText: SwiftUI.Color = .primary
        public static let secondaryText: SwiftUI.Color = .secondary
        public static let tertiaryText: SwiftUI.Color = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        public static let quaternaryText: SwiftUI.Color = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        public static let separator: SwiftUI.Color = SwiftUI.Color(nsColor: .separatorColor)
        public static let windowBackground: SwiftUI.Color = SwiftUI.Color(nsColor: .windowBackgroundColor)
        public static let controlBackground: SwiftUI.Color = SwiftUI.Color(nsColor: .controlBackgroundColor)
        public static let success: SwiftUI.Color = SwiftUI.Color(nsColor: .systemGreen)
        public static let warning: SwiftUI.Color = SwiftUI.Color(nsColor: .systemOrange)
        public static let danger: SwiftUI.Color = SwiftUI.Color(nsColor: .systemRed)
        /// Neutral fill for a chart wedge that groups several small items.
        public static let chartRemainder: SwiftUI.Color = SwiftUI.Color(nsColor: .systemGray)
    }
}

extension View {

    /// Premium surface treatment.
    ///
    /// - macOS 26+ : Liquid Glass.
    /// - macOS 15  : native vibrancy material.
    /// - macOS 14  : solid native control surface.
    ///
    /// The `#available` guard keeps the newer API out of the macOS 14/15 code
    /// path entirely, per the compatibility rules in the architecture contract.
    @ViewBuilder
    public func dsSurface(cornerRadius: CGFloat = DS.Radius.panel) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 15.0, *) {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(DS.Color.controlBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Secondary/inset surface (slightly quieter than `dsSurface`).
    @ViewBuilder
    public func dsInsetSurface(cornerRadius: CGFloat = DS.Radius.large) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 15.0, *) {
            self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(DS.Color.controlBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
