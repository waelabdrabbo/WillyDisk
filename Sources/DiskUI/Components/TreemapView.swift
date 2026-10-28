import SwiftUI
import DiskCore
import DiskLocalization

/// An interactive treemap of a directory's contents.
///
/// Every box is a share of the box that holds it, so a folder's area is its size
/// and a file's area is its own. The focused directory's entries fill the pane;
/// a folder large enough to read into shows its own entries inside its box,
/// inset by a band of its own fill. Clicking a folder enters it and clicking a
/// file selects it, and the selection and the hover are the same values the
/// explorer and the sunburst already share — the two charts are two drawings of
/// one tree.
///
/// The chart's names live in a readout at its foot rather than inside the boxes:
/// a box can be a few points wide, and text drawn straight on a fill has to
/// fight that fill for contrast. Hovering, or focusing a box with the keyboard,
/// names it and gives its size, which is what the sunburst's centre disc does.
///
/// A layout belongs to a pane size and to a revision of the data behind it. When
/// the focused folder is wide enough that building the boxes would be felt, the
/// building runs off the main actor and the last layout stays on screen until
/// the new one is ready.
@MainActor
public struct TreemapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let nodes: [ScanNode]
    private let centerLabel: String
    /// Identifies the entries and their revision. It must change whenever the
    /// boxes should be rebuilt; a folder's path and the results revision are
    /// enough, and it keeps the chart from hashing every entry on every redraw.
    private let inputID: String
    private let selectedNodeURL: URL?
    private let maxChildren: Int
    private let source: TreemapNodeSource
    private let playsEntrance: Bool
    @Binding private var hoveredURL: URL?
    private let onSelect: (ScanNode) -> Void

    /// Holds the boxes between changes of the data they are built from.
    @State private var cache = TreemapTilesCache()
    /// The box under the pointer, so the readout can name it.
    @State private var hoveredKey: String?
    /// The box the keyboard is on, so a keyboard user is told what a pointer
    /// user is told.
    @FocusState private var focusedKey: String?
    /// Counts the frames the motion has drawn, which is what makes the picture
    /// redraw while a box is moving.
    @State private var animationFrame = 0
    /// Whether the frame driver is mounted.
    @State private var isAnimating = false
    /// Bumped when an off-main layout lands, so the screen redraws with it.
    @State private var asyncRevision = 0

    public init(
        nodes: [ScanNode],
        centerLabel: String,
        inputID: String,
        selectedNodeURL: URL? = nil,
        maxChildren: Int = DS.Treemap.maxChildrenPerNode,
        source: TreemapNodeSource = SnapshotTreemapSource(),
        hoveredURL: Binding<URL?> = .constant(nil),
        playsEntrance: Bool = false,
        onSelect: @escaping (ScanNode) -> Void
    ) {
        self.nodes = nodes
        self.centerLabel = centerLabel
        self.inputID = inputID
        self.selectedNodeURL = selectedNodeURL
        self.maxChildren = maxChildren
        self.source = source
        self._hoveredURL = hoveredURL
        self.playsEntrance = playsEntrance
        self.onSelect = onSelect
    }

    public var body: some View {
        // The body reads both counters so a landed off-main layout and a drawn
        // animation frame each redraw the chart.
        _ = asyncRevision
        _ = animationFrame

        return GeometryReader { geo in
            let size = geo.size
            let key = layoutKey(size: size)
            let layout = cache.layout(
                for: key,
                animated: !reduceMotion,
                intro: playsEntrance
            ) {
                TreemapLayout.tiles(
                    nodes: nodes,
                    source: source,
                    maxChildren: maxChildren,
                    in: CGRect(origin: .zero, size: size)
                )
            }
            surface(layout: layout, size: size)
                .task(id: key) { await buildOffMainIfNeeded(key: key, size: size) }
                .onChange(of: layout.revision) { _, _ in updateAnimationState() }
                .onChange(of: reduceMotion) { _, reduce in
                    guard reduce else { return }
                    cache.animator.settle()
                    isAnimating = false
                    // The layer compares frames, not the motion: the settled
                    // boxes have to be redrawn without a tick to supersede them.
                    animationFrame &+= 1
                }
                .onAppear { updateAnimationState() }
        }
        .overlay(alignment: .topLeading) {
            if isAnimating {
                ChartTicker { dt in
                    cache.animator.step(dt: dt)
                    animationFrame &+= 1
                    if cache.animator.isSettled { isAnimating = false }
                }
            }
        }
    }

    /// Starts the frame driver only when the layout left something moving.
    private func updateAnimationState() {
        guard !reduceMotion else {
            cache.animator.settle()
            isAnimating = false
            return
        }
        if !cache.animator.isSettled { isAnimating = true }
    }

    // MARK: - Surface

    @ViewBuilder
    private func surface(layout: (tiles: [TreemapTile], revision: Int), size: CGSize) -> some View {
        if min(size.width, size.height) < DS.Treemap.minimumSize {
            placeholder(message: L10n.string("Enlarge this pane to see the chart"),
                        icon: "arrow.up.left.and.arrow.down.right")
        } else if layout.tiles.isEmpty {
            if cache.isBuilding {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.string("Storage treemap"))
            } else {
                placeholder(message: L10n.string("Nothing here is big enough to draw."))
            }
        } else {
            chart(layout: layout, size: size)
        }
    }

    private func chart(
        layout: (tiles: [TreemapTile], revision: Int),
        size: CGSize
    ) -> some View {
        let tiles = layout.tiles
        let animator = cache.animator
        // The selection can name a node the chart left out, so it only counts
        // here when the chart draws it.
        let selectedKey = selectedNodeURL.flatMap { url in
            tiles.first { $0.node?.url == url }?.key
        }
        let activeKey = hoveredKey ?? focusedKey
        let active = activeKey.flatMap { key in
            animator.drawn.first { $0.tile.key == key }
        }
        let selected = selectedKey.flatMap { key in
            animator.drawn.first { $0.tile.key == key }
        }

        return ZStack {
            // The picture: one canvas paints every box, so a hover only repaints
            // the emphasis above it and a snapshot changes pixels, not views.
            Canvas { context, _ in
                for drawing in animator.drawn where drawing.alpha > 0.001 {
                    let rect = boxRect(drawing.rect)
                    guard rect.width > 0.5, rect.height > 0.5 else { continue }
                    let path = Path(roundedRect: rect, cornerRadius: DS.Treemap.radius(for: rect.size))
                    let opacity = drawing.tile.key == selectedKey
                        ? DS.Chart.selectedFillOpacity
                        : DS.Treemap.fillOpacity
                    context.fill(
                        path,
                        with: .color(
                            drawing.fill.color(depth: Double(drawing.tile.depth))
                                .opacity(opacity * drawing.alpha)
                        )
                    )
                }
            }
            .allowsHitTesting(false)

            // The first level keeps a control per box: it is what the keyboard
            // and assistive technology reach. Deeper boxes are hit through the
            // chart's own gesture, resolved by the same geometry the hover uses.
            ForEach(tiles.filter { $0.depth == 1 && $0.node != nil }) { tile in
                focusStop(for: tile, animator: animator, isSelected: tile.key == selectedKey)
            }

            if active != nil || selected != nil {
                ChartEmphasis(
                    active: active.map { emphasisPath(for: $0) },
                    trail: active.map { emphasisTrail(of: $0) } ?? [],
                    selected: selected.map { emphasisPath(for: $0) },
                    size: size,
                    animates: !reduceMotion,
                    activeID: activeKey
                )
            }

            // Names are drawn over the wash so a selected box keeps its name, and
            // only where the box can hold one: a sliver is named by the readout.
            ForEach(labelBoxes(animator.drawn), id: \.tile.key) { box in
                tileLabel(box, isDark: colorScheme == .dark)
            }
        }
        // The boxes are drawn by hand in one coordinate space, so the chart is
        // laid out left to right in every language. A right-to-left environment
        // would move the positioned labels to the mirror image of their boxes
        // while the canvas stayed where it was; names are set at the leading edge
        // of their own box instead. The trail, the readout and the window around
        // the chart still follow the interface's direction.
        .environment(\.layoutDirection, .leftToRight)
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomLeading) {
            readout(active, maxWidth: size.width * DS.Treemap.readoutWidthFraction)
                .padding(DS.Spacing.small)
                .allowsHitTesting(false)
        }
        // Hover is resolved against the boxes rather than the controls: the
        // controls cover their whole box, so a view-level hover region would let
        // a parent swallow every nested box under it.
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let key = cache.animator.tile(at: point)?.tile.key
                if key != hoveredKey { hoveredKey = key }
                publish(url(for: key, in: tiles))
            case .ended:
                if hoveredKey != nil { hoveredKey = nil }
                publish(url(for: focusedKey, in: tiles))
            }
        }
        // A tap on a nested box is resolved here, because a folder's own control
        // only covers its header: a folder enters, a file selects. The first
        // level's controls own their clicks, and the aggregate is not a target.
        .gesture(
            SpatialTapGesture().onEnded { value in
                guard let drawing = cache.animator.tile(at: value.location),
                      drawing.tile.depth > 1,
                      let node = drawing.tile.node else { return }
                onSelect(node)
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.format("Storage treemap, %@", centerLabel))
    }

    // MARK: - Labels

    /// One box's name, where it can be drawn.
    private struct LabelBox {
        let tile: TreemapTile
        let rect: CGRect
        let fill: ChartFill
    }

    private func labelBoxes(_ drawn: [TreemapAnimatedTile]) -> [LabelBox] {
        drawn.compactMap { drawing in
            guard drawing.alpha > 0.5 else { return nil }
            let rect = boxRect(drawing.rect)
            guard rect.width >= DS.Treemap.labelMinimumWidth,
                  rect.height >= DS.Treemap.labelMinimumHeight else { return nil }
            let labelRect = labelRect(for: drawing.tile, in: rect)
            guard labelRect.width > 8, labelRect.height > 8 else { return nil }
            return LabelBox(tile: drawing.tile, rect: labelRect, fill: drawing.fill)
        }
    }

    /// A folder's name sits in the header band it keeps for its contents; a file
    /// is named inside its own box.
    private func labelRect(for tile: TreemapTile, in rect: CGRect) -> CGRect {
        if tile.isNested {
            return CGRect(
                x: rect.minX + DS.Treemap.labelPadding,
                y: rect.minY,
                width: rect.width - 2 * DS.Treemap.labelPadding,
                height: DS.Treemap.headerHeight
            )
        }
        return rect.insetBy(dx: DS.Treemap.labelPadding, dy: DS.Treemap.labelPadding)
    }

    /// The name is set on the box's own fill, in the plate colour that fill takes,
    /// so it stays legible on a dark tone and on a pale one. It sits at the
    /// leading edge of its box, which is the right one when the interface reads
    /// right to left.
    private func tileLabel(_ box: LabelBox, isDark: Bool) -> some View {
        Text(box.tile.label)
            .font(DS.Typography.caption)
            .fontWeight(box.tile.isNested ? .semibold : .regular)
            .foregroundStyle(box.fill.textColor(depth: Double(box.tile.depth), isDark: isDark))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(
                width: max(box.rect.width, 1),
                height: max(box.rect.height, 1),
                alignment: Alignment(
                    horizontal: L10n.isRightToLeft ? .trailing : .leading,
                    vertical: box.tile.isNested ? .center : .top
                )
            )
            .position(x: box.rect.midX, y: box.rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Controls

    /// One first-level box's control: its keyboard stop, its accessible name,
    /// and the click on its own header.
    ///
    /// The box itself is painted by the canvas. A folder's control covers only
    /// the header band that names it, so a click on the contents reaches the
    /// chart's own gesture and the deepest box wins; a file has no contents, so
    /// its control is the whole box. Its frame follows the animated box, so the
    /// focus ring and the emphasis agree with what is painted.
    private func focusStop(
        for tile: TreemapTile,
        animator: TreemapAnimator,
        isSelected: Bool
    ) -> some View {
        let rect = boxRect(animator.tile(forKey: tile.key)?.rect ?? tile.rect)
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let header = tile.isNested
            ? min(DS.Treemap.headerHeight, height - 1)
            : height
        return Button {
            if let node = tile.node { onSelect(node) }
        } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, height: height, alignment: .top)
        .contentShape(
            Path(CGRect(x: 0, y: 0, width: width, height: max(header, 1)))
        )
        .position(x: rect.midX, y: rect.midY)
        .focusEffectDisabled()
        .focused($focusedKey, equals: tile.key)
        .accessibilityLabel(L10n.format("%@, %@", tile.label, ByteFormat.string(tile.size)))
        .accessibilityHint(L10n.string(tile.node?.isDirectory == true
                                        ? "Show this folder's contents"
                                        : "Show this file's details"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The active box and its size, named where the sunburst names one in its
    /// spindle. Hidden from assistive technology: the controls already carry the
    /// same words.
    @ViewBuilder
    private func readout(_ active: TreemapAnimatedTile?, maxWidth: CGFloat) -> some View {
        if let active, active.alpha > 0.5 {
            HStack(spacing: DS.Spacing.xSmall) {
                Text(active.tile.label)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ByteFormat.string(active.tile.size))
                    .font(DS.Typography.metadataFigures)
                    .foregroundStyle(DS.Color.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.xxSmall)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(DS.Color.enamel, in: Capsule())
            .overlay {
                Capsule().strokeBorder(DS.Color.rule, lineWidth: DS.Stroke.hairline)
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Geometry

    private func boxRect(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: DS.Treemap.gap / 2, dy: DS.Treemap.gap / 2)
    }

    /// The shape a box is drawn with, which the emphasis follows.
    private func emphasisPath(for drawing: TreemapAnimatedTile) -> Path {
        let rect = boxRect(drawing.rect)
        return Path(roundedRect: rect, cornerRadius: DS.Treemap.radius(for: rect.size))
    }

    /// The boxes that contain `active`, innermost first — the trail a pointer
    /// reads as a path through the tree.
    private func emphasisTrail(of active: TreemapAnimatedTile) -> [Path] {
        cache.animator.drawn
            .filter {
                $0.alpha > 0.5
                    && $0.tile.depth < active.tile.depth
                    && $0.rect.contains(active.rect)
            }
            .sorted { $0.tile.depth < $1.tile.depth }
            .map { emphasisPath(for: $0) }
    }

    // MARK: - Layout and input

    private func layoutKey(size: CGSize) -> TreemapLayoutKey {
        TreemapLayoutKey(
            input: inputID,
            count: nodes.count,
            maxChildren: maxChildren,
            width: max(Int(size.width.rounded()), 1),
            height: max(Int(size.height.rounded()), 1),
            isInline: nodes.count <= DS.Treemap.inlineLayoutLimit
        )
    }

    /// Builds a wide folder's boxes away from the main actor. The last layout
    /// stays on screen until the new one lands; a build whose key is gone is
    /// dropped rather than applied.
    private func buildOffMainIfNeeded(key: TreemapLayoutKey, size: CGSize) async {
        guard cache.needsAsyncBuild(for: key) else { return }
        cache.beginBuild(for: key)
        defer { cache.clearBuild(for: key) }

        let nodes = self.nodes
        let source = self.source
        let maxChildren = self.maxChildren
        let rect = CGRect(origin: .zero, size: size)
        let built = await Task.detached(priority: .userInitiated) {
            TreemapLayout.tiles(nodes: nodes, source: source, maxChildren: maxChildren, in: rect)
        }.value

        guard !Task.isCancelled else { return }
        cache.adopt(built, for: key, animated: !reduceMotion, intro: playsEntrance)
        asyncRevision &+= 1
        updateAnimationState()
    }

    /// Sets the shared hovered URL only when it actually changes, so sweeping
    /// the pointer does not re-render the screen on every mouse move.
    private func publish(_ url: URL?) {
        if hoveredURL != url { hoveredURL = url }
    }

    private func url(for key: String?, in tiles: [TreemapTile]) -> URL? {
        guard let key else { return nil }
        return tiles.first { $0.key == key }?.node?.url
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
        .accessibilityLabel(L10n.format("Storage treemap, %@", message))
    }
}

// MARK: - Layout key

/// The inputs that decide a treemap's boxes. Two layouts with the same key are
/// the same picture.
struct TreemapLayoutKey: Hashable {
    let input: String
    let count: Int
    let maxChildren: Int
    let width: Int
    let height: Int
    let isInline: Bool
}

// MARK: - Layout cache

/// Holds the treemap's boxes while the data they are built from holds still.
///
/// A focus, a hover, a resize of the pane or a redraw therefore reuses the boxes
/// instead of walking the tree again. The cache owns the chart's motion too,
/// because adopting a layout is what starts it.
final class TreemapTilesCache {
    let animator = TreemapAnimator()

    private(set) var tiles: [TreemapTile] = []
    /// Counts the adopted layouts, which is what the view watches to start the
    /// frame driver.
    private(set) var revision = 0
    var isBuilding: Bool { buildingKey != nil }

    private var heldKey: TreemapLayoutKey?
    private var pendingKey: TreemapLayoutKey?
    private var buildingKey: TreemapLayoutKey?

    func layout(
        for key: TreemapLayoutKey,
        animated: Bool,
        intro: Bool,
        build: () -> [TreemapTile]
    ) -> (tiles: [TreemapTile], revision: Int) {
        guard key != heldKey else { return (tiles, revision) }
        if key.isInline {
            adopt(build(), for: key, animated: animated, intro: intro)
        } else if pendingKey != key, buildingKey != key {
            pendingKey = key
        }
        return (tiles, revision)
    }

    func needsAsyncBuild(for key: TreemapLayoutKey) -> Bool {
        pendingKey == key && key != heldKey && buildingKey != key
    }

    func beginBuild(for key: TreemapLayoutKey) {
        buildingKey = key
        pendingKey = key
    }

    func clearBuild(for key: TreemapLayoutKey) {
        if buildingKey == key { buildingKey = nil }
    }

    func adopt(_ newTiles: [TreemapTile], for key: TreemapLayoutKey, animated: Bool, intro: Bool) {
        heldKey = key
        pendingKey = nil
        buildingKey = nil
        tiles = newTiles
        revision &+= 1
        if newTiles.isEmpty {
            animator.reset()
        } else {
            animator.setTarget(newTiles, animated: animated, intro: intro)
        }
    }
}
