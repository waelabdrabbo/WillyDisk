import SwiftUI
import DiskCore

/// An interactive sunburst chart of a directory's contents.
///
/// The focused directory sits at the centre; its children fill the first ring —
/// each wedge's angular span proportional to that child's logical size — and
/// their descendants fill the outer rings, so depth and distribution read at a
/// glance. Clicking a directory asks `onSelect` to drill into it (the parent
/// owns the breadcrumb state); clicking a file selects it, and the selected
/// wedge keeps the brightest fill and the heaviest outline in the chart.
/// Hovering or focusing a wedge names it in the centre and lets the other wedges
/// recede. A wedge is coloured by where its node sits in the tree: each child of
/// the focused directory takes a hue of its own and every node below it keeps
/// that hue as a paler tint on each ring further out (`ChartPalette`), so one
/// subtree reads as a single colour family. Built entirely on custom SwiftUI shapes — no third-party
/// dependencies.
///
/// Hover is shared with the rest of the screen through `hoveredURL`: the chart
/// publishes the node URL of the wedge under the pointer (or the keyboard) and
/// highlights the wedge whose node URL the parent sets, so the explorer list can
/// light the chart and the chart can light the list. Wedges are matched by node
/// URL, never by `id` — an `id` is a ring/position path that changes as the tree
/// changes shape.
public struct SunburstView: View {
    private let nodes: [ScanNode]
    private let centerLabel: String
    private let selectedNodeURL: URL?
    @Binding private var hoveredURL: URL?
    private let onSelect: (ScanNode) -> Void

    /// The wedge under the pointer, so the centre can name it.
    @State private var hoveredID: String?
    /// The wedge the keyboard is on, so a keyboard user is told what a pointer
    /// user is told.
    @FocusState private var focusedID: String?
    /// Holds the rings between changes of the data they are built from.
    @State private var segmentsCache = SunburstSegmentsCache()

    public init(
        nodes: [ScanNode],
        centerLabel: String,
        selectedNodeURL: URL? = nil,
        hoveredURL: Binding<URL?> = .constant(nil),
        onSelect: @escaping (ScanNode) -> Void
    ) {
        self.nodes = nodes
        self.centerLabel = centerLabel
        self.selectedNodeURL = selectedNodeURL
        self._hoveredURL = hoveredURL
        self.onSelect = onSelect
    }

    public var body: some View {
        // Every part of the surface reads the same rings, and they are the costly
        // part of drawing the chart — walking and ordering the node tree and
        // ranking every sibling group's colours — so they are derived once per
        // change of the data rather than once per redraw.
        let layout = segmentsCache.layout(for: nodes) {
            SunburstLayout.segments(roots: nodes)
        }
        return chartSurface(segments: layout.segments, revision: layout.revision)
            // Keyboard focus joins the same shared state a pointer hover does, so
            // a keyboard user sees the cross-pane link a pointer user sees, and
            // the published URL is the chart's *resolved* active wedge — the
            // pointer wins over focus — so the two panes never disagree.
            .onChange(of: focusedID) { _, newID in
                publish(url(for: hoveredID ?? newID, in: layout.segments))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Storage sunburst")
    }

    private var totalSize: Int64 { nodes.reduce(Int64(0)) { $0 + max($1.logicalSize, 0) } }

    @ViewBuilder
    private func chartSurface(segments: [SunburstSegment], revision: Int) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if segments.isEmpty {
                    placeholder(icon: "chart.pie", message: "Nothing to show here")
                } else if side < DS.Sunburst.minimumSize {
                    placeholder(icon: "arrow.up.left.and.arrow.down.right",
                                message: "Enlarge this pane to see the chart")
                } else {
                    chart(side: side, segments: segments, revision: revision)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Chart

    private func chart(side: CGFloat, segments: [SunburstSegment], revision: Int) -> some View {
        let geometry = SunburstGeometry(
            side: side,
            ringCount: segments.map(\.ring).max() ?? 1
        )
        // The wedge under the pointer or keyboard wins; otherwise the wedge the
        // parent asked for (a hovered explorer row) is the active one. A
        // counterpart is only resolved when its node is drawn here: the explorer
        // can hold nodes the chart left out, and a highlight is never invented for
        // a wedge that is not on screen.
        let ownActive = segments.first { $0.id == (hoveredID ?? focusedID) }
        let counterpart = hoveredURL.flatMap { url in
            segments.first { $0.node?.url == url }
        }
        let active = ownActive ?? counterpart
        // The selection can name a node the chart left out, so it is only a
        // wedge here when the chart draws it.
        let selected = selectedNodeURL.flatMap { url in
            segments.first { $0.node?.url == url }
        }

        return ZStack {
            // The picture itself, which no hover changes.
            SunburstWedgeLayer(
                segments: segments,
                revision: revision,
                side: side,
                geometry: geometry,
                selectedURL: selectedNodeURL,
                focusedID: $focusedID,
                onSelect: onSelect
            )
            .equatable()
            // What the pointer or the keyboard emphasises, drawn over it: the
            // fade needs something to fade towards, but a selection draws its
            // outline whether or not anything is hovered.
            if active != nil || selected != nil {
                SunburstEmphasis(active: active, selected: selected,
                                 geometry: geometry, side: side)
            }
            centerDisc(radius: geometry.innerRadius, center: geometry.center, active: active)
        }
        .frame(width: side, height: side)
        // Hover is resolved against the wedge geometry rather than the segment
        // views: every segment fills the same square, so a view-level hover
        // region would let whichever segment is on top swallow the whole chart.
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let id = geometry.segmentID(at: point, in: segments)
                if id != hoveredID { hoveredID = id }
                // Publish the resolved active wedge (pointer over keyboard), and
                // an aggregate wedge — which has no node — names no counterpart.
                publish(url(for: id ?? focusedID, in: segments))
            case .ended:
                if hoveredID != nil { hoveredID = nil }
                publish(url(for: focusedID, in: segments))
            }
        }
    }

    /// Sets the shared hovered URL only when it actually changes, so sweeping
    /// the pointer does not re-render the screen on every mouse move.
    private func publish(_ url: URL?) {
        if hoveredURL != url { hoveredURL = url }
    }

    /// The node URL of a wedge by `id`, for the chart's own hover and focus.
    private func url(for id: String?, in segments: [SunburstSegment]) -> URL? {
        guard let id else { return nil }
        return segments.first { $0.id == id }?.node?.url
    }

    private func centerDisc(radius: CGFloat, center: CGPoint, active: SunburstSegment?) -> some View {
        let title = active?.label ?? centerLabel
        let detail = ByteFormat.string(active?.size ?? totalSize)

        return ZStack {
            Circle()
                .fill(DS.Color.controlBackground)
                .overlay(Circle().strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.hairline))
            VStack(spacing: DS.Spacing.xxSmall) {
                Text(title)
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Color.primaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
            }
            .padding(DS.Spacing.small)
            .frame(width: radius * DS.Sunburst.centerLabelWidthFraction)
        }
        .frame(width: radius * 2, height: radius * 2)
        // Keeps a long two-line name inside the disc instead of letting it spill
        // into the first ring.
        .clipShape(Circle())
        .position(center)
        .animation(.snappy, value: active?.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private func placeholder(icon: String, message: String) -> some View {
        VStack(spacing: DS.Spacing.small) {
            Image(systemName: icon)
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.tertiaryText)
            Text(message)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Storage sunburst, \(message)")
    }
}

// MARK: - Segments

/// One wedge of the sunburst: a node, or a truthful group of the smallest
/// children of a directory that has more than the chart draws individually.
struct SunburstSegment: Identifiable, Equatable {
    let id: String
    let node: ScanNode?
    let remainderCount: Int
    let ring: Int
    /// Angular span, measured in radians from 12 o'clock and increasing clockwise.
    let start: Double
    let end: Double
    let size: Int64
    /// The wedge's chart colour, shared with the explorer's icon for the node.
    let fill: ChartFill

    var label: String {
        if let node { return node.name }
        return "\(remainderCount) smaller \(remainderCount == 1 ? "item" : "items")"
    }
}

/// Builds the sunburst's rings from the focused directory's children.
///
/// Ring 1 spans the full circle; every deeper ring splits its parent's span in
/// proportion to each child's logical size, so a wedge's angle always reflects
/// its share of its parent. Directories with more children than the chart draws
/// get one aggregate wedge for the remainder, keeping every parent's angles
/// truthful to its real total. `maxSegments` is a ceiling on the whole chart
/// rather than on one parent: once it is spent the chart stops drawing deeper
/// rings, so the number of live controls stays bounded however wide the tree is.
///
/// Each wedge is also handed its fill here, because colour depends on a node's
/// siblings: a child of the focused directory takes a hue of its own and a
/// descendant keeps its ancestor's hue as the paler tint of the ring it is drawn
/// on (`ChartPalette`).
enum SunburstLayout {

    private struct Placed {
        let node: ScanNode
        let start: Double
        let end: Double
        let prefix: String
        /// The fill this node's own wedge carries. Descendants keep its hue, so
        /// it is also what opens their colour family.
        let fill: ChartFill
    }

    /// The rings the chart draws, at the density it ships with.
    ///
    /// The chart itself, and everything else that needs to know which wedge a node
    /// was drawn as, reads the layout from here: one call, one answer.
    static func segments(roots: [ScanNode]) -> [SunburstSegment] {
        segments(
            roots: roots,
            maxRings: DS.Sunburst.maxRings,
            maxChildren: DS.Sunburst.maxChildrenPerNode,
            maxSegments: DS.Sunburst.maxSegments
        )
    }

    /// The fill of every node the chart draws, keyed by path.
    ///
    /// Read straight off the rings, so a node's fill is the one its own wedge is
    /// painted with, on whichever ring it was drawn. A node the chart leaves out —
    /// one with no bytes, or one past the chart's density limits — has no entry, so
    /// a caller showing a node's chart colour draws it neutral rather than claim a
    /// wedge the chart never painted.
    static func fillsByPath(roots: [ScanNode]) -> [String: ChartFill] {
        var fills: [String: ChartFill] = [:]
        for segment in segments(roots: roots) {
            guard let node = segment.node else { continue }
            fills[node.url.path] = segment.fill
        }
        return fills
    }

    static func segments(
        roots: [ScanNode],
        maxRings: Int,
        maxChildren: Int,
        maxSegments: Int = DS.Sunburst.maxSegments
    ) -> [SunburstSegment] {
        var result: [SunburstSegment] = []
        var level: [Placed] = []

        appendRing(
            children: roots,
            start: 0,
            end: 2 * .pi,
            ring: 1,
            parentPrefix: "",
            parentFill: nil,
            maxChildren: maxChildren,
            maxSegments: maxSegments,
            into: &result,
            level: &level
        )

        var ring = 2
        while ring <= maxRings, !level.isEmpty, result.count < maxSegments {
            var next: [Placed] = []
            for parent in level where parent.node.isDirectory && !parent.node.children.isEmpty {
                appendRing(
                    children: parent.node.children,
                    start: parent.start,
                    end: parent.end,
                    ring: ring,
                    parentPrefix: parent.prefix,
                    parentFill: parent.fill,
                    maxChildren: maxChildren,
                    maxSegments: maxSegments,
                    into: &result,
                    level: &next
                )
            }
            level = next
            ring += 1
        }

        return result
    }

    private static func appendRing(
        children: [ScanNode],
        start: Double,
        end: Double,
        ring: Int,
        parentPrefix: String,
        parentFill: ChartFill?,
        maxChildren: Int,
        maxSegments: Int,
        into result: inout [SunburstSegment],
        level: inout [Placed]
    ) {
        let ordered = children
            .filter(\.isPresentable)
            .sorted { $0.logicalSize > $1.logicalSize }
        guard !ordered.isEmpty, end > start else { return }

        let total = ordered.reduce(Int64(0)) { $0 + $1.logicalSize }
        guard total > 0 else { return }

        // Nothing left to spend: the chart keeps the wedges it has rather than
        // adding one more per parent below.
        let slots = maxSegments - result.count
        guard slots > 0 else { return }

        // Colour ranks the siblings by path, not by size, and ranks every child
        // the parent holds — including one whose bytes have not been counted yet.
        // A sibling arriving during a scan therefore takes a place of its own
        // instead of moving the colours already on screen; the relative order of
        // paths never changes.
        let fills = ChartPalette.fills(for: children, ring: ring, parentFill: parentFill)

        // A parent whose children do not all fit needs a slot for the aggregate
        // wedge as well as for the children it draws; when only that slot is left
        // the whole group is drawn as the one wedge.
        var shownCount = min(min(ordered.count, maxChildren), slots)
        if ordered.count > shownCount {
            shownCount = min(shownCount, slots - 1)
        }
        guard shownCount > 0 else {
            result.append(remainderSegment(ring: ring, parentPrefix: parentPrefix, count: ordered.count,
                                           start: start, end: end, size: total))
            return
        }

        let shown = ordered.prefix(shownCount)
        let shownTotal = shown.reduce(Int64(0)) { $0 + $1.logicalSize }
        let hiddenTotal = total - shownTotal

        let span = end - start
        var angle = start

        for node in shown {
            let width = span * Double(node.logicalSize) / Double(total)
            let nodeEnd = angle + width
            // Identify a wedge by the node's path, not its `id`: the engine
            // rebuilds every node value on each progressive snapshot, so paths
            // are what stay stable while a scan streams results in.
            let prefix = parentPrefix + node.url.path
            let fill = fills[node.url.path] ?? .neutral
            result.append(
                SunburstSegment(
                    id: "\(ring)\(prefix)",
                    node: node,
                    remainderCount: 0,
                    ring: ring,
                    start: angle,
                    end: nodeEnd,
                    size: node.logicalSize,
                    fill: fill
                )
            )
            level.append(Placed(node: node, start: angle, end: nodeEnd, prefix: prefix, fill: fill))
            angle = nodeEnd
        }

        if hiddenTotal > 0 {
            // The aggregate wedge runs to the end of the parent's span, so the
            // ring still accounts for every byte of that parent.
            result.append(remainderSegment(ring: ring, parentPrefix: parentPrefix,
                                           count: ordered.count - shownCount,
                                           start: angle, end: end, size: hiddenTotal))
        }
    }

    private static func remainderSegment(
        ring: Int,
        parentPrefix: String,
        count: Int,
        start: Double,
        end: Double,
        size: Int64
    ) -> SunburstSegment {
        SunburstSegment(
            id: "\(ring)\(parentPrefix)/remainder",
            node: nil,
            remainderCount: count,
            ring: ring,
            start: start,
            end: end,
            size: size,
            fill: .aggregate
        )
    }
}

// MARK: - Geometry

/// Ring radii and pointer→wedge resolution for one chart size.
struct SunburstGeometry {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let thickness: CGFloat
    let ringCount: Int

    init(side: CGFloat, ringCount: Int) {
        let outer = side / 2 * DS.Sunburst.outerRadiusFraction
        let inner = outer * DS.Sunburst.centerRadiusFraction
        self.center = CGPoint(x: side / 2, y: side / 2)
        self.outerRadius = outer
        self.innerRadius = inner
        self.ringCount = max(ringCount, 1)
        self.thickness = (outer - inner) / CGFloat(max(ringCount, 1))
    }

    /// Radii of one ring: ring 1 is the innermost, each deeper generation moves out.
    func radii(ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        let outer = outerRadius - CGFloat(ringCount - ring) * thickness
        return (outer - thickness, outer)
    }

    /// The wedge a point in the chart's local space falls in, or nil outside the
    /// rings or in a gap between wedges.
    func segmentID(at point: CGPoint, in segments: [SunburstSegment]) -> String? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0, distance <= outerRadius else { return nil }

        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }

        for segment in segments {
            let band = radii(ring: segment.ring)
            guard distance >= band.inner, distance <= band.outer else { continue }
            if angle >= segment.start, angle <= segment.end { return segment.id }
            if segment.end >= 2 * .pi, angle + 2 * .pi <= segment.end { return segment.id }
        }
        return nil
    }
}

/// A single annulus sector.
///
/// Angles are measured in radians from 12 o'clock and increase clockwise, which
/// is how a sunburst reads. The outline is built from explicit polar points
/// rather than arc primitives, so the sweep direction does not depend on how the
/// arc flag interacts with a y-down coordinate space.
struct SunburstWedge: Shape, Equatable {
    var center: CGPoint
    var innerRadius: CGFloat
    var outerRadius: CGFloat
    var startAngle: Double
    var endAngle: Double
    var angularGap: Double
    var radialGap: CGFloat

    func path(in rect: CGRect) -> Path {
        let start = startAngle + angularGap
        let end = max(start + DS.Sunburst.minimumWedgeSweep, endAngle - angularGap)
        let outer = max(outerRadius - radialGap, 0)
        let inner = min(max(innerRadius + radialGap, 0), max(outer - DS.Sunburst.minimumBandWidth, 0))
        let sweep = end - start
        // ~1° of arc per segment keeps the curve visually smooth.
        let steps = max(4, Int((sweep / (Double.pi / 180)).rounded(.up)))

        func point(angle: Double, radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
        }

        var path = Path()
        for step in 0...steps {
            let angle = start + sweep * Double(step) / Double(steps)
            let p = point(angle: angle, radius: outer)
            step == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        for step in stride(from: steps, through: 0, by: -1) {
            let angle = start + sweep * Double(step) / Double(steps)
            path.addLine(to: point(angle: angle, radius: inner))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Wedge layer

/// Every wedge of the chart, drawn as it stands with nothing emphasised.
///
/// Nothing here depends on where the pointer or the keyboard is: the wedges a
/// hover fades and the outline it draws are painted over this layer by
/// `SunburstEmphasis`. That is what keeps a sweep across the explorer's rows from
/// re-making the wedges — up to `DS.Sunburst.maxSegments` buttons, each with a
/// tooltip, a focus binding and a hit region of its own, which is more than a
/// frame can pay for every time the pointer leaves one row for the next.
///
/// Its comparison is by `revision` and `side` rather than by the segments
/// themselves: `revision` is bumped whenever the rings are rebuilt, and comparing
/// the segments would compare their nodes' subtrees.
private struct SunburstWedgeLayer: View, Equatable {
    let segments: [SunburstSegment]
    let revision: Int
    let side: CGFloat
    let geometry: SunburstGeometry
    let selectedURL: URL?
    let focusedID: FocusState<String?>.Binding
    let onSelect: (ScanNode) -> Void

    nonisolated static func == (lhs: SunburstWedgeLayer, rhs: SunburstWedgeLayer) -> Bool {
        lhs.revision == rhs.revision && lhs.side == rhs.side && lhs.selectedURL == rhs.selectedURL
    }

    var body: some View {
        ZStack {
            ForEach(segments) { segment in
                SunburstWedgeView(
                    id: segment.id,
                    node: segment.node,
                    label: segment.label,
                    size: segment.size,
                    // The selection is matched through the node, never by URL
                    // alone: an aggregate wedge has no node, and a bare
                    // comparison would read it as the one selected whenever
                    // nothing is.
                    isSelected: segment.node.map { $0.url == selectedURL } ?? false,
                    fill: segment.fill,
                    shape: SunburstWedge(
                        center: geometry.center,
                        innerRadius: geometry.radii(ring: segment.ring).inner,
                        outerRadius: geometry.radii(ring: segment.ring).outer,
                        startAngle: segment.start,
                        endAngle: segment.end,
                        angularGap: DS.Sunburst.angularGap,
                        radialGap: DS.Sunburst.radialGap
                    ),
                    side: side,
                    focusedID: focusedID,
                    onSelect: onSelect
                )
                // A wedge is redrawn when what it draws changes and not
                // otherwise, which is what keeps the whole layer out of the way
                // of everything that is not new data.
                .equatable()
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Emphasis

/// What the pointer or the keyboard emphasises on the chart.
///
/// The wedge that is active keeps the fill the layer already gave it; every other
/// wedge fades back by being covered with the surface it is drawn on. The fade is
/// one filled path — the chart's square with the active and the selected wedges
/// cut out of it — so a hover costs a path rather than the chart.
///
/// Nothing is outlined for a hover: a wedge at rest draws no outline, and adding
/// one as the pointer arrives would read as the wedge growing under it. The fade
/// alone is what moves the emphasis.
///
/// The selection's outline is drawn here, over the fade, because the fade covers
/// the fill a wedge draws its outline around: an outline under it would lose its
/// outer half.
private struct SunburstEmphasis: View {
    let active: SunburstSegment?
    /// The wedge the user selected, when the chart draws it.
    let selected: SunburstSegment?
    let geometry: SunburstGeometry
    let side: CGFloat

    /// The wedges the fade leaves alone: the active one, and the selection, which
    /// keeps the fill it was given.
    private func faded(around active: SunburstSegment) -> [SunburstWedge] {
        guard let selected, selected.id != active.id else { return [wedge(active)] }
        return [wedge(active), wedge(selected)]
    }

    var body: some View {
        ZStack {
            if let active {
                SunburstShade(wedges: faded(around: active))
                    .fill(DS.Color.windowBackground.opacity(DS.Sunburst.shadeOpacity),
                          style: FillStyle(eoFill: true))
            }
            if let selected {
                // The selected wedge carries the heaviest outline in the chart.
                wedge(selected)
                    .stroke(DS.Color.primaryText.opacity(DS.Sunburst.selectedStrokeOpacity),
                            lineWidth: DS.Stroke.selection)
            }
        }
        .frame(width: side, height: side)
        // The fade covers the whole chart, and the wedges underneath it are the
        // controls: the emphasis is a picture of the pointer, never a target.
        .allowsHitTesting(false)
    }

    private func wedge(_ segment: SunburstSegment) -> SunburstWedge {
        SunburstWedge(
            center: geometry.center,
            innerRadius: geometry.radii(ring: segment.ring).inner,
            outerRadius: geometry.radii(ring: segment.ring).outer,
            startAngle: segment.start,
            endAngle: segment.end,
            angularGap: DS.Sunburst.angularGap,
            radialGap: DS.Sunburst.radialGap
        )
    }
}

/// The chart's square with a set of wedges cut out of it.
///
/// Filled even-odd, so the wedges it is given become holes and everything else is
/// covered. The chart is drawn directly on the window's background
/// (`DS.Color.windowBackground`), which is what makes covering it a fade rather
/// than a repaint: the covered wedges end up at `DS.Sunburst.shadeOpacity` of the
/// fill they already carry, and the gaps between them and the space around the
/// chart are painted their own colour back.
private struct SunburstShade: Shape {
    var wedges: [SunburstWedge]

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        for wedge in wedges {
            path.addPath(wedge.path(in: rect))
        }
        return path
    }
}

// MARK: - Wedge

/// One drawn wedge of the chart.
///
/// A wedge draws the fill it stands for, and nothing about where the pointer or
/// the selection is: the outlines are drawn over the layer by `SunburstEmphasis`.
/// Comparing the values it draws is what lets SwiftUI keep the wedges that are
/// already right as they are.
///
/// The comparison deliberately covers the node's `id` rather than the node
/// itself: the engine mints new ids for every snapshot, so a rebuilt node means a
/// wedge worth drawing again, while walking a node's subtree to compare it would
/// put a whole folder back on the redraw path.
private struct SunburstWedgeView: View, Equatable {
    /// The wedge's identity in the layout — a ring and path derivation, which is
    /// also what the keyboard's focus is held by.
    let id: String
    /// The node this wedge stands for, or `nil` for the aggregate wedge. Carried
    /// for the click action and the wedge's accessible name, never compared.
    let node: ScanNode?
    let label: String
    let size: Int64
    let isSelected: Bool
    let fill: ChartFill
    let shape: SunburstWedge
    let side: CGFloat
    let focusedID: FocusState<String?>.Binding
    let onSelect: (ScanNode) -> Void

    nonisolated static func == (lhs: SunburstWedgeView, rhs: SunburstWedgeView) -> Bool {
        lhs.id == rhs.id
            && lhs.node?.id == rhs.node?.id
            && lhs.label == rhs.label
            && lhs.size == rhs.size
            && lhs.isSelected == rhs.isSelected
            && lhs.fill == rhs.fill
            && lhs.shape == rhs.shape
            && lhs.side == rhs.side
    }

    var body: some View {
        // The fill only: the outlines the chart draws — the selection's and the
        // emphasis's — belong to `SunburstEmphasis`, which draws them over the
        // fade rather than under it.
        let content = shape
            .fill(fill.color.opacity(isSelected ? DS.Sunburst.selectedFillOpacity : DS.Sunburst.fillOpacity))

        return Group {
            if let node {
                Button {
                    onSelect(node)
                } label: {
                    content
                }
                .buttonStyle(.plain)
                // The wedge, not the enclosing square, is what a click can land
                // on and what shows focus: every wedge shares the same square, so
                // the default focus effect would ring the whole chart.
                .contentShape(shape)
                .focusEffectDisabled()
                .focused(focusedID, equals: id)
                .help("\(label) — \(ByteFormat.string(size))")
                .accessibilityLabel("\(label), \(ByteFormat.string(size))")
                .accessibilityHint(node.isDirectory ? "Show this folder's contents" : "Show this file's details")
                .accessibilityAddTraits(node.isDirectory ? [] : .isStaticText)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                // The aggregate wedge stands for several children at once. It is
                // not a control, but it is part of the picture, so it is named
                // rather than hidden.
                content
                    .accessibilityElement()
                    .accessibilityLabel("\(label), \(ByteFormat.string(size))")
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .frame(width: side, height: side)
    }
}

// MARK: - Segment cache

/// Holds the chart's rings while the data they are built from holds still.
///
/// The engine mints a new id for every node on every snapshot, so the ids of the
/// chart's roots are what identify its data: while they hold, a hover, a resize or
/// a selection reuses the held rings instead of walking the tree, ordering every
/// sibling group and ranking every colour again. `revision` counts the rebuilds,
/// which lets the wedge layer tell new rings from the ones it has already drawn
/// without comparing the segments themselves.
private final class SunburstSegmentsCache {
    private var ids: [UUID] = []
    private var held: [SunburstSegment] = []
    private var revision = 0

    func layout(for nodes: [ScanNode], build: () -> [SunburstSegment])
        -> (segments: [SunburstSegment], revision: Int) {
        let ids = nodes.map(\.id)
        guard ids != self.ids else { return (held, revision) }
        held = build()
        self.ids = ids
        revision += 1
        return (held, revision)
    }
}
