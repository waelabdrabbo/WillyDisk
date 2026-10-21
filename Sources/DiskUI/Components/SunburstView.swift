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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let nodes: [ScanNode]
    private let centerLabel: String
    private let selectedNodeURL: URL?
    private let maxChildren: Int
    @Binding private var hoveredURL: URL?
    private let onSelect: (ScanNode) -> Void
    /// What clicking the spindle hole does — going up one level — or nil when
    /// there is no level above this chart.
    private let onCenterTap: (() -> Void)?
    private let centerHint: String

    /// The wedge under the pointer, so the centre can name it.
    @State private var hoveredID: String?
    /// The wedge the keyboard is on, so a keyboard user is told what a pointer
    /// user is told.
    @FocusState private var focusedID: String?
    /// Holds the rings between changes of the data they are built from.
    @State private var segmentsCache = SunburstSegmentsCache()
    /// Whether the pointer is on the centre disc, which is a control when it can
    /// go up a level.
    @State private var centerHovered = false

    public init(
        nodes: [ScanNode],
        centerLabel: String,
        selectedNodeURL: URL? = nil,
        maxChildren: Int = DS.Sunburst.maxChildrenPerNode,
        hoveredURL: Binding<URL?> = .constant(nil),
        onCenterTap: (() -> Void)? = nil,
        centerHint: String = "Go up one level",
        onSelect: @escaping (ScanNode) -> Void
    ) {
        self.nodes = nodes
        self.centerLabel = centerLabel
        self.selectedNodeURL = selectedNodeURL
        self.maxChildren = maxChildren
        self._hoveredURL = hoveredURL
        self.onCenterTap = onCenterTap
        self.centerHint = centerHint
        self.onSelect = onSelect
    }

    public var body: some View {
        // Every part of the surface reads the same rings, and they are the costly
        // part of drawing the chart — walking and ordering the node tree and
        // ranking every sibling group's colours — so they are derived once per
        // change of the data rather than once per redraw.
        let layout = segmentsCache.layout(for: nodes, maxChildren: maxChildren) {
            SunburstLayout.segments(roots: nodes, maxChildren: maxChildren)
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
                    placeholder(message: "Nothing here is big enough to draw.")
                } else if side < DS.Sunburst.minimumSize {
                    placeholder(message: "Enlarge this pane to see the chart",
                                icon: "arrow.up.left.and.arrow.down.right")
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
            // The platter: the disc the rings are cut into. Painting it makes
            // the gaps between wedges, and the empty end of a sparse outer ring,
            // the platter's surface rather than the window behind the chart.
            Circle()
                .fill(DS.Color.enamel)
                .overlay {
                    Circle().strokeBorder(DS.Color.rule, lineWidth: DS.Stroke.hairline)
                }
                .frame(width: geometry.outerRadius * 2, height: geometry.outerRadius * 2)
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
                SunburstEmphasis(active: active,
                                 trail: active.map { lineage(of: $0, in: segments) } ?? [],
                                 selected: selected,
                                 geometry: geometry,
                                 side: side,
                                 animates: !reduceMotion)
            }
            centerDisc(radius: geometry.innerRadius, center: geometry.center, active: active)
        }
        .frame(width: side, height: side)
        // Hover is resolved against the wedge geometry rather than the segment
        // views: every segment fills the same square, so a view-level hover
        // region would let whichever segment is on top swallow the whole chart.
        .contentShape(Rectangle())
        // The top ring is made of real controls; a tap on a deeper wedge is
        // resolved here, by the geometry, and selects what it landed on.
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                guard let id = geometry.segmentID(at: value.location, in: segments),
                      let segment = segments.first(where: { $0.id == id }),
                      segment.ring > 1,
                      let node = segment.node else { return }
                onSelect(node)
            }
        )
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

    /// The wedges that contain `segment` on the rings inside it — the groove
    /// trace's errand. A child's span always sits inside its parent's, so
    /// containment is the whole test.
    private func lineage(of segment: SunburstSegment, in segments: [SunburstSegment]) -> [SunburstSegment] {
        segments
            .filter { $0.ring < segment.ring && $0.start <= segment.start && $0.end >= segment.end }
            .sorted { $0.ring < $1.ring }
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

    @ViewBuilder
    private func centerDisc(radius: CGFloat, center: CGPoint, active: SunburstSegment?) -> some View {
        let title = active?.label ?? centerLabel
        let detail = ByteFormat.string(active?.size ?? totalSize)

        // The disc is the platter's spindle hole and uses the platter's own
        // fixed palette, so it stays ink in both appearances: a printed disc on a
        // light window, a dark well with a hairline rim on a dark one.
        let disc = ZStack {
            Circle()
                .fill(DS.Color.plateGround)
                .overlay(Circle().strokeBorder(DS.Color.plateGroove.opacity(DS.Opacity.discBorder),
                                               lineWidth: DS.Stroke.hairline))
            VStack(spacing: DS.Spacing.xxSmall) {
                Text(title)
                    .font(DS.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.Color.plateGroove)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(DS.Typography.figures)
                    .foregroundStyle(DS.Color.plateGroove.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(DS.Spacing.small)
            .frame(width: radius * DS.Sunburst.centerLabelWidthFraction)
        }
        .frame(width: radius * 2, height: radius * 2)
        // Keeps a long two-line name inside the disc instead of letting it spill
        // into the first ring.
        .clipShape(Circle())
        .animation(reduceMotion ? nil : .snappy, value: active?.id)

        if let onCenterTap {
            Button(action: onCenterTap) {
                disc
            }
            .buttonStyle(.plain)
            .onHover { centerHovered = $0 }
            .overlay {
                if centerHovered {
                    Circle()
                        .strokeBorder(DS.Color.accent.opacity(0.8),
                                      lineWidth: DS.Stroke.emphasis)
                }
            }
            .help(centerHint)
            .accessibilityLabel("\(title), \(detail)")
            .accessibilityHint(centerHint)
            .position(center)
        } else {
            disc
                .position(center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title), \(detail)")
        }
    }

    private func placeholder(message: String, icon: String? = nil) -> some View {
        VStack(spacing: DS.Spacing.small) {
            if let icon {
                Image(systemName: icon)
                    .font(DS.Icon.medium)
                    .foregroundStyle(DS.Color.mutedText)
            } else {
                WillyDiskMark(size: 40)
            }
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
    }

    /// The rings the chart draws, at the density it ships with.
    ///
    /// The chart itself, and everything else that needs to know which wedge a node
    /// was drawn as, reads the layout from here: one call, one answer.
    static func segments(roots: [ScanNode]) -> [SunburstSegment] {
        segments(roots: roots, maxChildren: DS.Sunburst.maxChildrenPerNode)
    }

    /// The rings when the explorer has revealed more children than the chart's
    /// default density. The ceiling still applies, so a very long list turns
    /// its tail into the truthful aggregate instead of unbounded controls.
    static func segments(roots: [ScanNode], maxChildren: Int) -> [SunburstSegment] {
        segments(
            roots: roots,
            maxRings: DS.Sunburst.maxRings,
            maxChildren: maxChildren,
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
        fillsByPath(roots: roots, maxChildren: DS.Sunburst.maxChildrenPerNode)
    }

    /// The fill of every node drawn at the same density the chart is using.
    /// The explorer must call this with the chart's current page, not the
    /// default, or a row that is on the chart would keep a neutral icon.
    static func fillsByPath(roots: [ScanNode], maxChildren: Int) -> [String: ChartFill] {
        var fills: [String: ChartFill] = [:]
        for segment in segments(roots: roots, maxChildren: maxChildren) {
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

        // Tone ranks the siblings by path, not by size, and ranks every child the
        // parent holds — including one whose bytes have not been counted yet. A
        // sibling arriving during a scan therefore takes a place of its own
        // instead of moving the tones already on screen; the relative order of
        // paths never changes.
        let fills = ChartPalette.fills(for: children, ring: ring)

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
            level.append(Placed(node: node, start: angle, end: nodeEnd, prefix: prefix))
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

    /// The half-gap, in radians, that keeps `wedgeGap` points of enamel between
    /// this ring's neighbours however far out the ring sits.
    func angularGap(ring: Int) -> Double {
        let band = radii(ring: ring)
        return DS.Sunburst.angularGap(atRadius: (band.inner + band.outer) / 2)
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
/// The picture is one canvas rather than a view per wedge: with up to
/// `DS.Sunburst.maxSegments` wedges, a control each costs more than a frame
/// every time the data changes, and a live scan changes it once a second. The
/// top ring also gets a control per wedge (see `SunburstWedgeView`) for the
/// keyboard, assistive technology, and tooltips; deeper rings are hit through
/// the chart's own tap gesture, which resolves them from the same geometry the
/// hover uses.
///
/// Nothing here depends on where the pointer or the keyboard is: the wedges a
/// hover fades and the outline it draws are painted over this layer by
/// `SunburstEmphasis`, so a pointer sweep never re-makes the picture.
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
            // The picture: one canvas paints every wedge, so a snapshot that
            // changes a size redraws pixels rather than rebuilding a view per
            // wedge. A view per wedge costs more than a frame once a chart draws
            // a couple of hundred of them.
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                for segment in segments {
                    context.fill(wedgeShape(for: segment).path(in: rect),
                                 with: .color(segment.fill.color.opacity(
                                    fillOpacity(for: segment))))
                }
            }
            .frame(width: side, height: side)

            // The top ring keeps a control per wedge: it is what the keyboard
            // and assistive technology reach, and it is small enough to rebuild
            // while a scan runs. Deeper wedges are hit through the chart's own
            // tap gesture, resolved by the same geometry the hover uses.
            ForEach(segments.filter { $0.ring == 1 }) { segment in
                SunburstWedgeView(
                    id: segment.id,
                    node: segment.node,
                    label: segment.label,
                    size: segment.size,
                    isSelected: segment.node.map { $0.url == selectedURL } ?? false,
                    shape: wedgeShape(for: segment),
                    side: side,
                    focusedID: focusedID,
                    onSelect: onSelect
                )
                .equatable()
            }
        }
        .frame(width: side, height: side)
    }

    private func wedgeShape(for segment: SunburstSegment) -> SunburstWedge {
        SunburstWedge(
            center: geometry.center,
            innerRadius: geometry.radii(ring: segment.ring).inner,
            outerRadius: geometry.radii(ring: segment.ring).outer,
            startAngle: segment.start,
            endAngle: segment.end,
            angularGap: geometry.angularGap(ring: segment.ring),
            radialGap: DS.Sunburst.radialGap
        )
    }

    private func fillOpacity(for segment: SunburstSegment) -> Double {
        let isSelected = segment.node.map { $0.url == selectedURL } ?? false
        return isSelected ? DS.Sunburst.selectedFillOpacity : DS.Sunburst.fillOpacity
    }
}

// MARK: - Emphasis

/// What the pointer or the keyboard emphasises on the chart.
///
/// Every wedge keeps the fill the layer gave it. The active wedge is washed with
/// signal and outlined at the same weight, and the bands that contain it are
/// outlined too, so the pointer reads as a path through the tree rather than as
/// one lit wedge.
///
/// The selection is drawn here too, and over the wash, because the wash covers
/// the fill an outline would sit on. Its tone is deepened with ink and it carries
/// the heaviest line in the chart, so "what I clicked" survives the pointer moving
/// on to another wedge.
private struct SunburstEmphasis: View {
    let active: SunburstSegment?
    /// The wedges inside `active` that contain it, innermost first.
    let trail: [SunburstSegment]
    /// The wedge the user selected, when the chart draws it.
    let selected: SunburstSegment?
    let geometry: SunburstGeometry
    let side: CGFloat
    /// False under Reduce Motion, where the emphasis appears at once.
    let animates: Bool

    var body: some View {
        ZStack {
            if let selected {
                SunburstShade(wedges: [wedge(selected)])
                    .fill(DS.Color.ink.opacity(DS.Sunburst.selectedOverlayOpacity))
            }
            if let active {
                SunburstShade(wedges: [wedge(active)])
                    .fill(DS.Color.signal.opacity(DS.Sunburst.hoverShadeOpacity))
                // Ancestors first: the wedge under the pointer keeps the top line.
                ForEach(trail) { ancestor in
                    wedge(ancestor)
                        .stroke(DS.Color.signal, lineWidth: DS.Sunburst.hoverStrokeWidth)
                        .opacity(DS.Opacity.hoverAncestor)
                }
                wedge(active)
                    .stroke(DS.Color.signal, lineWidth: DS.Sunburst.hoverStrokeWidth)
            }
            if let selected {
                // The selected wedge carries the heaviest line in the chart.
                wedge(selected)
                    .stroke(DS.Color.signal, lineWidth: DS.Sunburst.selectedStrokeWidth)
            }
        }
        .frame(width: side, height: side)
        .animation(animates ? .easeOut(duration: 0.12) : nil, value: active?.id)
        // The emphasis is a picture of the pointer, never a target. It covers
        // only the active wedge; the wedges underneath remain the controls.
        .allowsHitTesting(false)
    }

    private func wedge(_ segment: SunburstSegment) -> SunburstWedge {
        SunburstWedge(
            center: geometry.center,
            innerRadius: geometry.radii(ring: segment.ring).inner,
            outerRadius: geometry.radii(ring: segment.ring).outer,
            startAngle: segment.start,
            endAngle: segment.end,
            angularGap: geometry.angularGap(ring: segment.ring),
            radialGap: DS.Sunburst.radialGap
        )
    }
}

/// The active wedge, filled as a shape of its own.
///
/// The chart is drawn on the platter, so washing one wedge with a translucent
/// surface deepens that wedge without touching its neighbours or the enamel gaps
/// between wedges.
private struct SunburstShade: Shape {
    var wedges: [SunburstWedge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for wedge in wedges {
            path.addPath(wedge.path(in: rect))
        }
        return path
    }
}

// MARK: - Wedge

/// One top-ring wedge's control.
///
/// The layer paints the wedge; this view adds what a picture cannot: its hit
/// region, its keyboard focus stop, its tooltip and its accessible name. Only the
/// top ring has one, because a control per wedge across the whole chart costs
/// more than a frame once there are a couple of hundred of them.
///
/// Equality is by the node's path rather than by its `id`: the engine mints new
/// ids for every node on every snapshot, and comparing those would rebuild every
/// unchanged control once a second.
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
    let shape: SunburstWedge
    let side: CGFloat
    let focusedID: FocusState<String?>.Binding
    let onSelect: (ScanNode) -> Void

    nonisolated static func == (lhs: SunburstWedgeView, rhs: SunburstWedgeView) -> Bool {
        lhs.id == rhs.id
            // Identity by path, not by the node's id: the engine mints a new id
            // for every node on every snapshot, and comparing it would redraw
            // every unchanged wedge once a second for the whole scan.
            && lhs.node?.url == rhs.node?.url
            && lhs.label == rhs.label
            && lhs.size == rhs.size
            && lhs.isSelected == rhs.isSelected
            && lhs.shape == rhs.shape
            && lhs.side == rhs.side
    }

    var body: some View {
        // The canvas paints this wedge. The control is a hit region with a focus
        // stop, a tooltip and an accessible name, and nothing to draw.
        let content = Color.clear.contentShape(shape)

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
    private var maxChildren = -1
    private var held: [SunburstSegment] = []
    private var revision = 0

    func layout(for nodes: [ScanNode], maxChildren: Int, build: () -> [SunburstSegment])
        -> (segments: [SunburstSegment], revision: Int) {
        let ids = nodes.map(\.id)
        guard ids != self.ids || maxChildren != self.maxChildren else {
            return (held, revision)
        }
        held = build()
        self.ids = ids
        self.maxChildren = maxChildren
        revision += 1
        return (held, revision)
    }
}
