import SwiftUI
import DiskCore
import DiskLocalization

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
///
/// A rebuilt layout is not a new picture: each wedge is keyed by what it stands
/// for, so a wedge the new layout still draws moves there, one it drops fades
/// out, and one it adds opens outwards. `SunburstAnimator` owns that motion;
/// Reduce Motion adopts every layout at once.
public struct SunburstView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let nodes: [ScanNode]
    private let centerLabel: String
    private let selectedNodeURL: URL?
    private let maxChildren: Int
    /// Where a deeper ring's children come from. `nil` reads the node's own
    /// children, which is what a snapshot carries; a live tree supplies the
    /// entries it holds now instead.
    private let children: ((ScanNode) -> [ScanNode])?
    /// Bumped when the data behind the nodes changed without their identities
    /// changing — a live tree's edit keeps an entry's id while its bytes move.
    private let revision: Int
    /// Whether a fresh chart should start hidden and reveal itself instead of
    /// appearing settled. The results screen asks for it on every chart it puts
    /// in the pane, so a scan, a return, and a tab switch all reveal.
    private let playsEntrance: Bool
    @Binding private var hoveredURL: URL?
    private let onSelect: (ScanNode) -> Void
    /// What clicking the spindle hole does — going up one level — or nil when
    /// there is no level above this chart.
    private let onCenterTap: (() -> Void)?
    private let centerHint: String

    /// The wedge under the pointer, so the centre can name it. Holds the wedge's
    /// key, which survives a change of ring.
    @State private var hoveredKey: String?
    /// The wedge the keyboard is on, so a keyboard user is told what a pointer
    /// user is told.
    @FocusState private var focusedKey: String?
    /// Holds the rings between changes of the data they are built from.
    @State private var segmentsCache = SunburstSegmentsCache()
    /// Whether the pointer is on the centre disc, which is a control when it can
    /// go up a level.
    @State private var centerHovered = false
    /// Counts the frames the motion has drawn, which is what makes the picture
    /// redraw while a wedge is moving.
    @State private var animationFrame = 0
    /// Whether the frame driver is mounted. It is only ever true while there is
    /// something to draw between two layouts.
    @State private var isAnimating = false

    public init(
        nodes: [ScanNode],
        centerLabel: String,
        selectedNodeURL: URL? = nil,
        maxChildren: Int = DS.Sunburst.maxChildrenPerNode,
        revision: Int = 0,
        children: ((ScanNode) -> [ScanNode])? = nil,
        hoveredURL: Binding<URL?> = .constant(nil),
        onCenterTap: (() -> Void)? = nil,
        centerHint: String = L10n.string("Go up one level"),
        playsEntrance: Bool = false,
        onSelect: @escaping (ScanNode) -> Void
    ) {
        self.nodes = nodes
        self.centerLabel = centerLabel
        self.selectedNodeURL = selectedNodeURL
        self.maxChildren = maxChildren
        self.revision = revision
        self.children = children
        self._hoveredURL = hoveredURL
        self.onCenterTap = onCenterTap
        self.centerHint = centerHint
        self.playsEntrance = playsEntrance
        self.onSelect = onSelect
    }

    public var body: some View {
        // Every part of the surface reads the same rings, and they are the costly
        // part of drawing the chart — walking and ordering the node tree and
        // ranking every sibling group's colours — so they are derived once per
        // change of the data rather than once per redraw.
        let layout = segmentsCache.layout(
            for: nodes,
            maxChildren: maxChildren,
            revision: revision,
            animated: !reduceMotion,
            intro: playsEntrance
        ) {
            SunburstLayout.segments(roots: nodes, maxChildren: maxChildren, children: children)
        }
        return chartSurface(segments: layout.segments, revision: layout.revision, frame: animationFrame)
            // The chart's first layout is not a change `onChange` can see, and an
            // entrance starts moving on that very layout; the driver is started
            // here so a replay is not left standing still.
            .onAppear { updateAnimationState() }
            // Keyboard focus joins the same shared state a pointer hover does, so
            // a keyboard user sees the cross-pane link a pointer user sees, and
            // the published URL is the chart's *resolved* active wedge — the
            // pointer wins over focus — so the two panes never disagree.
            .onChange(of: focusedKey) { _, newKey in
                publish(url(for: hoveredKey ?? newKey, in: layout.segments))
            }
            // A rebuilt layout starts the frames that carry the wedges from where
            // they were to where the new layout wants them.
            .onChange(of: layout.revision) { _, _ in
                updateAnimationState()
            }
            .onChange(of: reduceMotion) { _, reduce in
                guard reduce else { return }
                segmentsCache.motion.settle()
                isAnimating = false
                // The layer compares frames, not the motion: the settled shapes
                // have to be redrawn without a frame tick to supersede them.
                animationFrame &+= 1
            }
            .overlay(alignment: .topLeading) {
                if isAnimating {
                    SunburstTicker { dt in
                        segmentsCache.motion.step(dt: dt)
                        animationFrame &+= 1
                        if segmentsCache.motion.isSettled { isAnimating = false }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.string("Storage sunburst"))
    }

    /// Starts the frame driver only when the layout left something moving.
    private func updateAnimationState() {
        guard !reduceMotion else {
            segmentsCache.motion.settle()
            isAnimating = false
            return
        }
        if !segmentsCache.motion.isSettled { isAnimating = true }
    }

    private var totalSize: Int64 { nodes.reduce(Int64(0)) { $0 + max($1.logicalSize, 0) } }

    @ViewBuilder
    private func chartSurface(segments: [SunburstSegment], revision: Int, frame: Int) -> some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                if segments.isEmpty {
                    placeholder(message: L10n.string("Nothing here is big enough to draw."))
                } else if side < DS.Sunburst.minimumSize {
                    placeholder(message: L10n.string("Enlarge this pane to see the chart"),
                                icon: "arrow.up.left.and.arrow.down.right")
                } else {
                    chart(side: side, segments: segments, revision: revision, frame: frame)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Chart

    private func chart(side: CGFloat, segments: [SunburstSegment], revision: Int, frame: Int) -> some View {
        let motion = segmentsCache.motion
        let geometry = SunburstGeometry(side: side, ringSpan: motion.ringSpan)
        // The wedge under the pointer or keyboard wins; otherwise the wedge the
        // parent asked for (a hovered explorer row) is the active one. A
        // counterpart is only resolved when its node is drawn here: the explorer
        // can hold nodes the chart left out, and a highlight is never invented for
        // a wedge that is not on screen.
        let ownActive = segments.first { $0.key == (hoveredKey ?? focusedKey) }
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
                motion: motion,
                revision: revision,
                frame: frame,
                side: side,
                geometry: geometry,
                selectedKey: selected?.key,
                focusedKey: $focusedKey,
                onSelect: onSelect
            )
            .equatable()
            // What the pointer or the keyboard emphasises, drawn over it: the
            // fade needs something to fade towards, but a selection draws its
            // outline whether or not anything is hovered. The shapes are the
            // wedges' drawn ones, so the emphasis follows a wedge mid-move.
            if active != nil || selected != nil {
                WedgeEmphasis(
                    active: active.flatMap { wedgeShape(forKey: $0.key, geometry: geometry) },
                    trail: active.map {
                        lineage(of: $0, in: segments)
                            .compactMap { wedgeShape(forKey: $0.key, geometry: geometry) }
                    } ?? [],
                    selected: selected.flatMap { wedgeShape(forKey: $0.key, geometry: geometry) },
                    side: side,
                    animates: !reduceMotion,
                    activeID: active?.key
                )
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
                guard let wedge = geometry.wedge(at: value.location, in: motion.drawn),
                      let segment = segments.first(where: { $0.key == wedge.key }),
                      segment.ring > 1,
                      let node = segment.node else { return }
                onSelect(node)
            }
        )
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let key = geometry.wedge(at: point, in: motion.drawn)?.key
                if key != hoveredKey { hoveredKey = key }
                // Publish the resolved active wedge (pointer over keyboard), and
                // an aggregate wedge — which has no node — names no counterpart.
                publish(url(for: key ?? focusedKey, in: segments))
            case .ended:
                if hoveredKey != nil { hoveredKey = nil }
                publish(url(for: focusedKey, in: segments))
            }
        }
    }

    /// The shape a wedge is drawn with right now, reveal included.
    private func wedgeShape(forKey key: String, geometry: SunburstGeometry) -> SunburstWedge? {
        segmentsCache.motion.wedge(forKey: key).map { wedgeShape(for: $0, in: geometry) }
    }

    private func wedgeShape(for wedge: SunburstAnimatedWedge, in geometry: SunburstGeometry) -> SunburstWedge {
        geometry.wedge(
            depth: wedge.depth,
            start: wedge.start,
            end: wedge.end,
            revealed: sunburstEase(wedge.grow)
        )
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

    /// The node URL of a wedge by key, for the chart's own hover and focus.
    private func url(for key: String?, in segments: [SunburstSegment]) -> URL? {
        guard let key else { return nil }
        return segments.first { $0.key == key }?.node?.url
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
        .animation(reduceMotion ? nil : .snappy, value: active?.key)

        if let onCenterTap {
            Button(action: onCenterTap) {
                disc
                    // The disc lifts a little as the pointer arrives, so the
                    // spindle reads as the control it is before it is clicked.
                    .scaleEffect(centerHovered ? 1.04 : 1)
            }
            .buttonStyle(.plain)
            .onHover { centerHovered = $0 }
            .overlay {
                Circle()
                    .strokeBorder(DS.Color.accent.opacity(centerHovered ? 0.9 : 0),
                                  lineWidth: DS.Stroke.emphasis)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: centerHovered)
            .help(centerHint)
            .accessibilityLabel(L10n.format("%@, %@", title, detail))
            .accessibilityHint(centerHint)
            .position(center)
        } else {
            disc
                .position(center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.format("%@, %@", title, detail))
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
        .accessibilityLabel(L10n.format("Storage sunburst, %@", message))
    }
}

// MARK: - Segments

/// One wedge of the sunburst: a node, or a truthful group of the smallest
/// children of a directory that has more than the chart draws individually.
struct SunburstSegment: Identifiable, Equatable {
    /// The wedge's identity in this layout: its ring and its path. It changes
    /// when a drill moves the wedge, so it orders the chart; `key` is what the
    /// motion follows.
    let id: String
    /// What the wedge stands for, independent of where it is drawn: a node's
    /// path, or the parent of an aggregate. A drill that moves a node from ring 2
    /// to ring 1 keeps this key, so the chart animates the move instead of
    /// replacing the wedge.
    let key: String
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
        return L10n.format("%lld smaller items", remainderCount)
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
        segments(roots: roots, maxChildren: maxChildren, children: nil)
    }

    /// The rings, with deeper children read from `children` when it is given.
    static func segments(
        roots: [ScanNode],
        maxChildren: Int,
        children: ((ScanNode) -> [ScanNode])?
    ) -> [SunburstSegment] {
        segments(
            roots: roots,
            maxRings: DS.Sunburst.maxRings,
            maxChildren: maxChildren,
            maxSegments: DS.Sunburst.maxSegments,
            children: children
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
        maxSegments: Int = DS.Sunburst.maxSegments,
        children: ((ScanNode) -> [ScanNode])? = nil
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
            for parent in level where parent.node.isDirectory {
                let deeper = children?(parent.node) ?? parent.node.children
                guard !deeper.isEmpty else { continue }
                appendRing(
                    children: deeper,
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
                    key: node.url.path,
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
            key: "remainder:\(parentPrefix)",
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
    /// How many rings the disc is divided into. Fractional while a rebuilt
    /// chart re-divides itself, which is what lets a shallower tree settle
    /// instead of snapping.
    let ringSpan: Double

    init(side: CGFloat, ringSpan: Double) {
        let outer = side / 2 * DS.Sunburst.outerRadiusFraction
        let inner = outer * DS.Sunburst.centerRadiusFraction
        self.center = CGPoint(x: side / 2, y: side / 2)
        self.outerRadius = outer
        self.innerRadius = inner
        self.ringSpan = max(ringSpan, 1)
    }

    init(side: CGFloat, ringCount: Int) {
        self.init(side: side, ringSpan: Double(ringCount))
    }

    /// Width of one ring at the current span.
    var thickness: CGFloat {
        (outerRadius - innerRadius) / CGFloat(max(ringSpan, 1))
    }

    /// The band at `depth`, where ring 1 is the innermost. `revealed` closes the
    /// band onto its inner edge, which is how an entering wedge opens outwards.
    /// The outer edge never passes the rim, so a wedge winding down to a
    /// shallower tree is squeezed at the rim rather than drawn over the window.
    func radii(depth: Double, revealed: Double = 1) -> (inner: CGFloat, outer: CGFloat) {
        let d = max(depth, 0)
        let inner = min(innerRadius * CGFloat(min(d, 1)) + CGFloat(max(d - 1, 0)) * thickness, outerRadius)
        let band = innerRadius + (thickness - innerRadius) * CGFloat(min(d, 1))
        let outer = min(inner + band * CGFloat(min(max(revealed, 0), 1)), outerRadius)
        return (inner, outer)
    }

    /// Radii of one ring, as the chart drew before it could rebuild between
    /// layouts.
    func radii(ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        radii(depth: Double(ring))
    }

    /// The shape of one wedge on `ring`, spanning `start...end`.
    func wedge(ring: Int, start: Double, end: Double) -> SunburstWedge {
        wedge(depth: Double(ring), start: start, end: end)
    }

    /// The shape of one wedge at a (possibly fractional) `depth`. `revealed` is
    /// the `sunburstEase` of a wedge's reveal.
    func wedge(depth: Double, start: Double, end: Double, revealed: Double = 1) -> SunburstWedge {
        let band = radii(depth: depth, revealed: revealed)
        return SunburstWedge(
            center: center,
            innerRadius: band.inner,
            outerRadius: band.outer,
            startAngle: start,
            endAngle: end,
            angularGap: DS.Sunburst.angularGap(atRadius: max((band.inner + band.outer) / 2, 1)),
            radialGap: DS.Sunburst.radialGap
        )
    }

    /// The wedge a point in the chart's local space falls in, or nil outside the
    /// rings, in a gap between wedges, or on a wedge that is still opening.
    ///
    /// Deepest drawn wedge first, so the test agrees with what is painted over
    /// what; the band is the drawn one, reveal included, so a wedge cannot be
    /// hovered where it is not yet drawn.
    func wedge(at point: CGPoint, in wedges: [SunburstAnimatedWedge]) -> SunburstAnimatedWedge? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0, distance <= outerRadius else { return nil }

        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }

        for wedge in wedges.reversed() where wedge.alpha >= 0.3 && wedge.grow > 0 {
            let band = radii(depth: wedge.depth, revealed: sunburstEase(wedge.grow))
            guard distance >= band.inner, distance <= band.outer else { continue }
            if angle >= wedge.start, angle <= wedge.end { return wedge }
            if wedge.end >= 2 * .pi, angle + 2 * .pi <= wedge.end { return wedge }
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
/// `WedgeEmphasis`, so a pointer sweep never re-makes the picture.
///
/// Its comparison is by `revision`, `frame`, `side` and the selection rather than
/// by the segments themselves: `revision` is bumped whenever the rings are
/// rebuilt, `frame` whenever the motion has advanced, and comparing the segments
/// would compare their nodes' subtrees. The wedges it paints are read from the
/// motion at draw time.
private struct SunburstWedgeLayer: View, Equatable {
    let segments: [SunburstSegment]
    let motion: SunburstAnimator
    let revision: Int
    /// Counts the frames the motion has drawn.
    let frame: Int
    let side: CGFloat
    let geometry: SunburstGeometry
    /// The key of the wedge the chart's selection names, when it draws it.
    let selectedKey: String?
    let focusedKey: FocusState<String?>.Binding
    let onSelect: (ScanNode) -> Void

    nonisolated static func == (lhs: SunburstWedgeLayer, rhs: SunburstWedgeLayer) -> Bool {
        lhs.revision == rhs.revision
            && lhs.frame == rhs.frame
            && lhs.side == rhs.side
            && lhs.selectedKey == rhs.selectedKey
    }

    var body: some View {
        ZStack {
            // The picture: one canvas paints every wedge, so a snapshot that
            // changes a size redraws pixels rather than rebuilding a view per
            // wedge. A view per wedge costs more than a frame once a chart draws
            // a couple of hundred of them.
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                for wedge in motion.drawn where wedge.alpha > 0.001 && wedge.grow > 0 {
                    let shape = geometry.wedge(
                        depth: wedge.depth,
                        start: wedge.start,
                        end: wedge.end,
                        revealed: sunburstEase(wedge.grow)
                    )
                    context.fill(shape.path(in: rect),
                                 with: .color(wedge.fill.color(depth: wedge.depth).opacity(
                                    fillOpacity(for: wedge) * wedge.alpha)))
                }
            }
            .frame(width: side, height: side)

            // The top ring keeps a control per wedge: it is what the keyboard
            // and assistive technology reach, and it is small enough to rebuild
            // while a scan runs. Deeper wedges are hit through the chart's own
            // tap gesture, resolved by the same geometry the hover uses. The
            // control wears the wedge's drawn shape, so focus and the pointer
            // agree with what is painted even while it moves.
            ForEach(segments.filter { $0.ring == 1 }) { segment in
                SunburstWedgeView(
                    id: segment.key,
                    node: segment.node,
                    label: segment.label,
                    size: segment.size,
                    isSelected: segment.key == selectedKey,
                    shape: motion.wedge(forKey: segment.key).map(wedgeShape) ?? wedgeShape(for: segment),
                    side: side,
                    focusedKey: focusedKey,
                    onSelect: onSelect
                )
                .equatable()
            }
        }
        .frame(width: side, height: side)
    }

    private func wedgeShape(for segment: SunburstSegment) -> SunburstWedge {
        geometry.wedge(depth: Double(segment.ring), start: segment.start, end: segment.end)
    }

    private func wedgeShape(for wedge: SunburstAnimatedWedge) -> SunburstWedge {
        geometry.wedge(depth: wedge.depth, start: wedge.start, end: wedge.end,
                       revealed: sunburstEase(wedge.grow))
    }

    private func fillOpacity(for wedge: SunburstAnimatedWedge) -> Double {
        wedge.key == selectedKey ? DS.Sunburst.selectedFillOpacity : DS.Sunburst.fillOpacity
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
/// unchanged control once a second. Its `id` is the wedge's key rather than its
/// layout id, so a drill that moves the wedge to another ring keeps its focus.
private struct SunburstWedgeView: View, Equatable {
    /// The wedge's identity across layouts, which is also what the keyboard's
    /// focus is held by.
    let id: String
    /// The node this wedge stands for, or `nil` for the aggregate wedge. Carried
    /// for the click action and the wedge's accessible name, never compared.
    let node: ScanNode?
    let label: String
    let size: Int64
    let isSelected: Bool
    let shape: SunburstWedge
    let side: CGFloat
    let focusedKey: FocusState<String?>.Binding
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
                .focused(focusedKey, equals: id)
                .help(L10n.format("%@ — %@", label, ByteFormat.string(size)))
                .accessibilityLabel(L10n.format("%@, %@", label, ByteFormat.string(size)))
                .accessibilityHint(L10n.string(node.isDirectory ? "Show this folder's contents" : "Show this file's details"))
                .accessibilityAddTraits(node.isDirectory ? [] : .isStaticText)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            } else {
                // The aggregate wedge stands for several children at once. It is
                // not a control, but it is part of the picture, so it is named
                // rather than hidden.
                content
                    .accessibilityElement()
                    .accessibilityLabel(L10n.format("%@, %@", label, ByteFormat.string(size)))
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
///
/// The cache owns the chart's motion too, because a rebuild is what starts it:
/// the animator is pointed at the new rings at the moment they replace the old
/// ones, so the first frame of the change is already interpolated.
private final class SunburstSegmentsCache {
    let motion = SunburstAnimator()

    private var ids: [UUID] = []
    private var maxChildren = -1
    private var sourceRevision = -1
    private var held: [SunburstSegment] = []
    private var revision = 0

    func layout(
        for nodes: [ScanNode],
        maxChildren: Int,
        revision sourceRevision: Int,
        animated: Bool,
        intro: Bool,
        build: () -> [SunburstSegment]
    ) -> (segments: [SunburstSegment], revision: Int) {
        let ids = nodes.map(\.id)
        guard ids != self.ids || maxChildren != self.maxChildren || sourceRevision != self.sourceRevision else {
            return (held, revision)
        }
        held = build()
        self.ids = ids
        self.maxChildren = maxChildren
        self.sourceRevision = sourceRevision
        revision += 1
        if held.isEmpty {
            motion.reset()
        } else {
            motion.setTarget(held, animated: animated, intro: intro)
        }
        return (held, revision)
    }
}
