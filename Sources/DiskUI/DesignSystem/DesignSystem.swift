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
        // Glyphs beside text follow the text ramp so they grow together.
        public static let inline: SwiftUI.Font = .subheadline
        public static let detail: SwiftUI.Font = .caption
        public static let disclosure: SwiftUI.Font = .caption.weight(.semibold)
    }

    // MARK: - Element sizes

    public enum Size {
        /// Square hit target for an icon-only control. A bare glyph is too small
        /// to click reliably, so icon buttons reserve this even when the symbol
        /// itself is drawn smaller.
        public static let iconButton: CGFloat = 28
        /// Minimum width for an action button, so labels align across screens.
        public static let actionMinWidth: CGFloat = 120
        /// Minimum width for a secondary footer action, so a sheet's pair of
        /// buttons keeps one baseline instead of hugging each label.
        public static let secondaryActionMinWidth: CGFloat = 84
        /// Fixed width of a volume's usage gauge.
        public static let gaugeWidth: CGFloat = 120
        /// Side of a volume row's capacity arc. The arc replaces a bar because the
        /// row already reads as a dial: the same concentric geometry as the mark.
        public static let capacityArcSize: CGFloat = 44
        /// The optical box a preset's location symbol occupies.
        public static let presetGlyph: CGFloat = 20
        /// Stroke of that arc, and the fraction of a full turn it covers. Three
        /// quarters leave the gap at the bottom, under the name.
        public static let capacityArcWidth: CGFloat = 3.5
        public static let capacityArcSweep: CGFloat = 0.75
        /// Rotation that puts the arc's gap at six o'clock.
        public static let capacityArcRotation: Double = 135
        /// How many explorer rows the list builds before offering "Show More".
        public static let explorerPageSize = 15
        /// Progress bar bounds in the in-progress header.
        public static let progressBarMinWidth: CGFloat = 160
        public static let progressBarMaxWidth: CGFloat = 320
        /// Width of the compact progress bar a source row shows while its
        /// location is being scanned.
        public static let rowProgressWidth: CGFloat = 88
        /// One line of caption text. A list row's detail line keeps this height,
        /// so a bar and a subtitle occupy the same second line.
        public static let listRowDetailMinHeight: CGFloat = 14
        /// Height of the scan-status strip at the bottom of the chart pane.
        /// Fixed, so the chart keeps its size whether or not a scan is running.
        public static let scanStatusStripHeight: CGFloat = 40
        /// Fixed width of the floating scan readout, so growing counts never
        /// make the capsule resize as the scan progresses.
        public static let scanStatusWidth: CGFloat = 440
        /// Label column width in a detail row.
        public static let detailLabelWidth: CGFloat = 60
        /// Leading column an access row reserves for its icon, so the paths of a
        /// restricted and a failed location line up under one another.
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
        /// Tint behind the row that holds the only result, above hover.
        public static let rowPrimary: Double = 0.10
        /// Hover on the row whose results are already open. Sits above the
        /// row's resting tint and below a selection.
        public static let rowCurrentHover: Double = 0.12
        /// A selected row in a window that is not key. Its value matches hover,
        /// but it names a different state so callers stop borrowing the hover
        /// token.
        public static let rowSelectionInactive: Double = 0.08
        /// Dimming applied to rows that cannot act during a scan.
        public static let disabled: Double = 0.5
        /// How much of the active wedge's outline an ancestor keeps, so the
        /// groove trace reads as one line from the centre outwards.
        public static let hoverAncestor: Double = 0.6
        /// The hairline that separates the spire from the platter it sits on.
        public static let discBorder: Double = 0.3
        /// Tint painted behind a content panel so it separates from the window
        /// without becoming a floating control.
        public static let contentPanel: Double = 0.04
        /// The tone a notice takes over its opaque surface, so success and
        /// failure read at a glance without letting the screen show through.
        public static let noticeWash: Double = 0.10
        /// Opaque stand-in when Reduce Transparency is on, and the macOS 14
        /// fallback. `controlBackground` alone is the window color and would
        /// leave the control invisible.
        public static let controlSurface: Double = 0.08
    }

    // MARK: - Strokes

    public enum Stroke {
        /// Border width for surfaces, wells, and chart separators.
        public static let hairline: CGFloat = 0.5
        /// Emphasis border for a highlighted or focused element.
        public static let emphasis: CGFloat = 1.5
        /// Border width for the keyboard-focus ring around a custom control.
        public static let focus: CGFloat = 2
        /// Border width for the element the explorer has selected. Wider than the
        /// hover/focus emphasis so a selection stays legible where it crosses the
        /// chart's own separators.
        public static let selection: CGFloat = 2.5
    }

    // MARK: - Elevation

    /// The lift under a surface that floats over content. A notice is the app's
    /// only floating band; everything else is inset into the window.
    public enum Shadow {
        public static let floatingRadius: CGFloat = 12
        public static let floatingOffset: CGFloat = 3
        public static let floatingOpacity: Double = 0.16
    }

    // MARK: - Timing

    public enum Timing {
        /// How long a notice holds before it dismisses itself. The countdown
        /// pauses while the pointer is over the notice, so its actions stay
        /// reachable for as long as they are being used.
        public static let notice: Swift.Duration = .seconds(8)
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
        /// Width of the enamel gap between adjacent wedges, in points. Held
        /// constant at every radius, so a sliver near the centre and a wide wedge
        /// at the rim are separated by the same line.
        public static let wedgeGap: CGFloat = 1.5
        /// Radial gap between rings, in points.
        public static let radialGap: CGFloat = 1.5

        /// Half a wedge gap expressed as an angle at `radius`. The wedge shape
        /// insets each edge by this much, so two neighbours end up `wedgeGap`
        /// apart however far out they sit.
        public static func angularGap(atRadius radius: CGFloat) -> Double {
            guard radius > 0 else { return 0 }
            return Double(wedgeGap / 2) / Double(radius)
        }
        /// Width of the centre disc's label block, as a fraction of its radius.
        public static let centerLabelWidthFraction: CGFloat = 1.7
        /// Wedge opacity. A chart-coloured icon wears it too, so a node's icon and
        /// its wedge land on the same colour against the same background.
        public static let fillOpacity: Double = 0.92
        /// A wash of signal painted over the active wedge only.
        public static let hoverShadeOpacity: Double = 0.12
        /// Fill opacity of the selected wedge: at full strength it reads as the
        /// heaviest wedge in the chart, including while another is hovered.
        public static let selectedFillOpacity: Double = 1
        /// How much ink a selected wedge takes on top of its own tone, so the
        /// selection is the chart's darkest mark in light and its brightest in
        /// dark without repainting the wedge underneath.
        public static let selectedOverlayOpacity: Double = 0.34
        /// Outline of the selected wedge, and of the wedge under the pointer.
        public static let selectedStrokeWidth: CGFloat = 2
        public static let hoverStrokeWidth: CGFloat = 1.5
        /// How long the emphasis takes to move from one wedge to the next. One
        /// value for both wedge charts, so their hover feels the same.
        public static let emphasisAnimationDuration: Double = 0.12
        /// The groove trace: the hairline that runs from the spindle to the rim
        /// while a wedge is hovered, and the tangential tick that ends it.

        // MARK: Tone ladder
        //
        // The chart is one material at depth, not a set of colour families. Ring 1
        // (the focused directory's children) is the darkest, each ring further out
        // is paler, so depth reads as distance from the centre. Within a ring,
        // siblings cycle through three neighbouring tones so touching wedges
        // separate; the cycle is keyed by path order, which stays put while a scan
        // streams in.
        //
        // Arrays are indexed by ring: entry 0 is ring 1.

        /// The one hue every wedge is mixed from: a cool ink, not a colour.
        public static let toneHue: Double = 188
        /// Brightness nearest the centre, light appearance.
        public static let toneLightBrightness: [Double] = [0.46, 0.68, 0.83]
        /// Brightness nearest the centre, dark appearance. Depth inverts: the
        /// nearest ring is the brightest so it still reads as the strongest.
        public static let toneDarkBrightness: [Double] = [0.88, 0.72, 0.58]
        /// How much colour the ink carries, nearest ring first.
        public static let toneLightSaturation: [Double] = [0.20, 0.14, 0.09]
        public static let toneDarkSaturation: [Double] = [0.16, 0.12, 0.09]
        /// Brightness step between the three sibling tones, so a tone is ± this
        /// from its ring's base.
        public static let toneStepOffset: Double = 0.055
    }

    // MARK: - Typography (SF Pro roles)

    /// Semantic text styles, so the whole app follows the system text size.
    ///
    /// SF Pro only: the identity comes from weight, width, and figures, not from a
    /// bundled font. Sizes, counts, percentages, and durations are set in
    /// `DS.Typography.figures` or with `.monospacedDigit()` so columns hold still
    /// as a scan streams numbers in.
    ///
    /// `caption` uses `.subheadline` (11 pt) rather than `.caption` (10 pt):
    /// metadata and paths are already the smallest text in the app and 10 pt is
    /// below the legibility floor on an inspector surface.
    public enum Typography {
        public static let largeTitle: SwiftUI.Font = .system(.largeTitle, weight: .bold)
        public static let title: SwiftUI.Font = .system(.title, weight: .bold)
        public static let title2: SwiftUI.Font = .system(.title2, weight: .semibold)
        public static let headline: SwiftUI.Font = .headline
        public static let body: SwiftUI.Font = .body
        public static let callout: SwiftUI.Font = .callout
        public static let caption: SwiftUI.Font = .subheadline
        /// The one number that rules a screen: a scan's total on the results
        /// header, a volume's share on the home screen.
        public static let metric: SwiftUI.Font = .system(size: 26, weight: .semibold)
        /// A figure inside running text — a size in a row, a count in a caption.
        public static let figures: SwiftUI.Font = .system(.body).monospacedDigit()
        /// Figures inside a metadata line, one step below a row's primary size.
        public static let metadataFigures: SwiftUI.Font = .system(.subheadline).monospacedDigit()
        /// Figures set inside a gauge too small for `figures`.
        public static let gaugeFigures: SwiftUI.Font = .system(size: 9, weight: .semibold).monospacedDigit()
        public static let monospaced: SwiftUI.Font = .system(.callout, design: .monospaced)
        /// Lockup tracking for the wordmark and screen titles, in points. Type set
        /// at title size and above closes up a little; body text does not.
        public static let displayTracking: CGFloat = -0.4
    }

    // MARK: - Semantic colors (light + dark adaptive)

    public enum Color {
        // The app has one material and one signal. Ink is what text is set in and
        // what the chart is drawn with; signal is the only colour that means
        // anything, and madder is the only colour that means trouble. Nothing else
        // is tinted for decoration — a second hue would dilute the signal.

        /// Text, figures, the mark's groove at rest, and the chart's darkest tone.
        public static let ink = dynamic(light: 0x16191B, dark: 0xEDEFEC)
        /// The platter: panels, the chart's centre disc, and the mark's groove on
        /// the icon.
        public static let enamel = dynamic(light: 0xF2F3F1, dark: 0x171A1B)
        /// The explorer's whole-height panel: a step below the window's own
        /// surface, so the column reads as part of the window rather than as a
        /// card floating on it.
        public static let sidebar = dynamic(light: 0xE9EBE7, dark: 0x2A2E2F)
        /// Secondary text, glyphs at rest, and the chart's middle tone: the quiet
        /// step between ink and rule.
        public static let graphite = dynamic(light: 0x5F676C, dark: 0xA9B1B2)
        /// Hairlines, dividers, and the chart's palest tone.
        public static let rule = dynamic(light: 0xD5D9D8, dark: 0x3A4042)

        // The mark is an object, not a glyph: it keeps the ink ground and enamel
        // grooves the app icon is drawn with, in both appearances. The ground
        // disappears into a dark window instead of turning white.
        public static let plateGround = dynamic(light: 0x16191B, dark: 0x16191B)
        public static let plateGroove = dynamic(light: 0xF2F3F1, dark: 0xF2F3F1)
        public static let plateSignal = dynamic(light: 0x0E6E70, dark: 0x0E6E70)
        /// The live thing: selection, focus, progress, and the mark's live sector.
        /// The only accent in the app.
        public static let signal = dynamic(light: 0x0E6E70, dark: 0x56B7AE)
        /// Text and glyphs on a `signal` fill: pale ink on the deep teal in
        /// light, deep ink on the pale mint in dark.
        public static let onSignal = dynamic(light: 0xFFFFFF, dark: 0x16191B)
        /// Destruction and failure. Never used for ordinary emphasis.
        public static let madder = dynamic(light: 0x8A3B2E, dark: 0xE08A73)

        public static let accent: SwiftUI.Color = signal
        public static let primaryText: SwiftUI.Color = ink
        public static let secondaryText: SwiftUI.Color = graphite
        /// De-emphasised text — paths, counts under a name, hidden entries. A third
        /// step below `secondaryText` that still clears 4.5:1 over the window.
        public static let mutedText = dynamic(light: 0x6B7377, dark: 0x8F9798)
        /// A chart fill fallback only. Never use this for text or a control.
        public static let tertiaryText: SwiftUI.Color = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        public static let quaternaryText: SwiftUI.Color = SwiftUI.Color(nsColor: .quaternaryLabelColor)
        public static let separator: SwiftUI.Color = rule
        public static let windowBackground: SwiftUI.Color = SwiftUI.Color(nsColor: .windowBackgroundColor)
        public static let controlBackground: SwiftUI.Color = SwiftUI.Color(nsColor: .controlBackgroundColor)
        /// The shadow under a floating surface. Black in both appearances: a
        /// shadow is an absence of light, not an ink tone.
        public static let shadow: SwiftUI.Color = .black
        public static let success: SwiftUI.Color = signal
        public static let warning: SwiftUI.Color = madder
        public static let danger: SwiftUI.Color = madder
        /// Neutral fill for a chart wedge that groups several small items.
        public static let chartRemainder: SwiftUI.Color = rule

        /// A palette colour that resolves per appearance. The values are sRGB
        /// hex, so a token can be stated once and checked against a contrast
        /// calculator without running the app.
        static func dynamic(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            let lightColor = nsColor(hex: light)
            let darkColor = nsColor(hex: dark)
            return SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
            })
        }

        private static func nsColor(hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1)
        }
    }
}

extension View {

    /// A functional-layer surface: toolbar-like controls, floating actions, and
    /// popovers. Liquid Glass on macOS 26, a native material on macOS 15, and a
    /// solid control surface on macOS 14.
    ///
    /// Glass is deliberately not a general-purpose content card treatment; the
    /// compatibility guard keeps the newer API out of the 14/15 code path.
    public func dsGlassControl(
        cornerRadius: CGFloat = DS.Radius.panel,
        interactive: Bool = false
    ) -> some View {
        modifier(DSGlassControlModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// The explorer's view switch: native, small, text-only, and hugging its
    /// labels.
    ///
    /// The cleanup sheet's header carries a different control — three
    /// destinations with their own counts and sizes — so the two do not share a
    /// shape.
    public func dsSegmentedSwitch() -> some View {
        self
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            // The control carries the app's one ink itself, so it reads the
            // same in a sheet, a preview, and the window that already sets it.
            .tint(DS.Color.signal)
    }
}

private struct DSGlassControlModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let strokeWidth = contrast == .increased ? DS.Stroke.emphasis : DS.Stroke.hairline
        if reduceTransparency {
            content
                .background(DS.Color.primaryText.opacity(DS.Opacity.controlSurface), in: shape)
                .overlay(shape.strokeBorder(DS.Color.separator, lineWidth: strokeWidth))
        } else if #available(macOS 26.0, *) {
            Group {
                if interactive {
                    content.glassEffect(.regular.interactive(), in: shape)
                } else {
                    content.glassEffect(.regular, in: shape)
                }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.emphasis)
                }
            }
        } else if #available(macOS 15.0, *) {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.emphasis)
                    }
                }
        } else {
            content
                .background(DS.Color.primaryText.opacity(DS.Opacity.controlSurface), in: shape)
                .overlay(shape.strokeBorder(DS.Color.separator, lineWidth: strokeWidth))
        }
    }
}
