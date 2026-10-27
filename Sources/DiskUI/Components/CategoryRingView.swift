import SwiftUI
import DiskCore
import DiskLocalization

/// The scan cut by file category, as one ring around the platter's centre.
///
/// The sunburst answers "what is in this folder"; this answers "what is this scan
/// made of", so it draws the whole scan at once and never drills into a folder.
/// Choosing a wedge opens that category in place; the open category stays
/// outlined and named in the centre, so the ring is the way back out as well as in.
struct CategoryRingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let breakdown: CategoryBreakdown
    let centerLabel: String
    /// The category the explorer is inside, if any.
    let selected: FileCategory?
    @Binding var hovered: FileCategory?
    let onSelect: (FileCategory) -> Void

    /// Seconds into the ring's entrance. Switching to Categories makes a new
    /// ring, and a ring whose breakdown arrives late starts its entrance then.
    @State private var elapsed: Double = 0
    @State private var isRevealing = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if breakdown.isEmpty {
                    placeholder(message: L10n.string("No file bytes to group yet"))
                } else if side < DS.Sunburst.minimumSize {
                    placeholder(message: L10n.string("Enlarge this pane to see the chart"),
                                icon: "arrow.up.left.and.arrow.down.right")
                } else {
                    ring(side: side)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .topLeading) {
            if isRevealing {
                SunburstTicker { dt in
                    elapsed = min(CategoryRingEntrance.duration, elapsed + dt)
                    if elapsed >= CategoryRingEntrance.duration { isRevealing = false }
                }
            }
        }
        // The ring opens as it appears. Reduce Motion shows it whole.
        .onAppear {
            guard !reduceMotion else { return }
            isRevealing = true
        }
        .onChange(of: breakdown.isEmpty) { _, isEmpty in
            // A scan that is still running has no breakdown when Categories is
            // opened; the ring's entrance starts when there is a ring to open.
            guard !isEmpty, !reduceMotion else { return }
            elapsed = 0
            isRevealing = true
        }
        .onChange(of: reduceMotion) { _, reduce in
            guard reduce else { return }
            elapsed = CategoryRingEntrance.duration
            isRevealing = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Scan by file category"))
    }

    // MARK: - Ring

    private func ring(side: CGFloat) -> some View {
        let geometry = SunburstGeometry(side: side, ringCount: 1)
        let segments = CategoryRingLayout.segments(from: breakdown.shares)
        // The pointer previews a category; otherwise the open category is the
        // one the centre names.
        let activeCategory = hovered ?? selected
        let active = activeCategory.flatMap { breakdown.share(of: $0) }
        let hoveredSegment = hovered.flatMap { category in
            segments.first { $0.category == category }
        }
        let selectedSegment = selected.flatMap { category in
            segments.first { $0.category == category }
        }

        return ZStack {
            Circle()
                .fill(DS.Color.enamel)
                .overlay {
                    Circle().strokeBorder(DS.Color.rule, lineWidth: DS.Stroke.hairline)
                }
                .frame(width: geometry.outerRadius * 2, height: geometry.outerRadius * 2)

            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let growth = reveal(for: segment)
                if growth > 0 {
                    let shape = wedge(segment, geometry: geometry, revealed: growth)
                    Button {
                        onSelect(segment.category)
                    } label: {
                        shape
                            .fill(ChartPalette.categoryColor(index: index, count: segments.count))
                    }
                    .buttonStyle(.plain)
                    .contentShape(shape)
                    .help(helpText(for: segment.category))
                    .accessibilityLabel(accessibilityLabel(for: segment.category))
                    .accessibilityHint(L10n.string(selected == segment.category
                                       ? "Closes this category and shows all categories"
                                       : "Shows the largest files in this category"))
                    .accessibilityAddTraits(selected == segment.category ? [.isSelected] : [])
                }
            }

            if hoveredSegment != nil || selectedSegment != nil {
                WedgeEmphasis(
                    active: hoveredSegment.map { wedge($0, geometry: geometry, revealed: reveal(for: $0)) },
                    trail: [],
                    selected: selectedSegment.map { wedge($0, geometry: geometry, revealed: reveal(for: $0)) },
                    side: side,
                    animates: !reduceMotion,
                    activeID: activeCategory?.rawValue
                )
            }

            centerDisc(radius: geometry.innerRadius, center: geometry.center, active: active)
        }
        .frame(width: side, height: side)
        // Hover is resolved against the ring's geometry rather than the wedge
        // controls: every control's frame covers the whole chart, so a
        // frame-based hover would always belong to whichever slice draws last.
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let category = CategoryRingLayout.category(at: point, in: geometry, segments: segments)
                if hovered != category { hovered = category }
            case .ended:
                if hovered != nil { hovered = nil }
            }
        }
    }

    /// How much of `segment` has opened. Reduce Motion shows the ring whole.
    private func reveal(for segment: CategoryRingLayout.Segment) -> Double {
        guard !reduceMotion else { return 1 }
        return CategoryRingEntrance.reveal(elapsed: elapsed, start: segment.start)
    }

    private func wedge(
        _ segment: CategoryRingLayout.Segment,
        geometry: SunburstGeometry,
        revealed: Double = 1
    ) -> SunburstWedge {
        geometry.wedge(depth: 1, start: segment.start, end: segment.end, revealed: revealed)
    }

    private func centerDisc(
        radius: CGFloat,
        center: CGPoint,
        active: CategoryShare?
    ) -> some View {
        let title = active?.category.displayName ?? centerLabel
        let detail = ByteFormat.string(active?.logicalSize ?? breakdown.totalLogicalSize)

        return ZStack {
            Circle()
                .fill(DS.Color.plateGround)
                .overlay {
                    Circle().strokeBorder(DS.Color.plateGroove.opacity(DS.Opacity.discBorder),
                                          lineWidth: DS.Stroke.hairline)
                }
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
                if let active {
                    Text(PercentFormat.ofWhole(active.share))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.plateGroove.opacity(0.62))
                }
            }
            .padding(DS.Spacing.small)
            .frame(width: radius * DS.Sunburst.centerLabelWidthFraction)
        }
        .frame(width: radius * 2, height: radius * 2)
        .clipShape(Circle())
        .animation(reduceMotion ? nil : .snappy, value: active?.category)
        .position(center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@, %@", title, detail))
    }

    private func helpText(for category: FileCategory) -> String {
        guard let share = breakdown.share(of: category) else { return category.displayName }
        return L10n.format(
            "%@ · %@ · %@",
            category.displayName,
            ByteFormat.string(share.logicalSize),
            PercentFormat.ofWhole(share.share)
        )
    }

    private func accessibilityLabel(for category: FileCategory) -> String {
        guard let share = breakdown.share(of: category) else { return category.displayName }
        return L10n.format(
            "%@, %@, %@ of the scan",
            category.displayName,
            ByteFormat.string(share.logicalSize),
            PercentFormat.ofWhole(share.share)
        )
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
    }
}

/// The angles of one category ring, clockwise from twelve o'clock.
enum CategoryRingLayout {
    struct Segment: Identifiable {
        let category: FileCategory
        let start: Double
        let end: Double

        var id: FileCategory { category }
        var span: Double { end - start }
    }

    /// Shares are used as they are, against the scan's total: a category list
    /// that did not account for every byte leaves the ring short rather than
    /// stretching its slices to fill a circle they do not own.
    static func segments(from shares: [CategoryShare]) -> [Segment] {
        var cursor = 0.0
        var segments: [Segment] = []
        for share in shares {
            let end = min(cursor + 2 * .pi * max(share.share, 0), 2 * .pi)
            guard end > cursor else { continue }
            segments.append(Segment(category: share.category, start: cursor, end: end))
            cursor = end
        }
        return segments
    }

    /// The slice under a point in the chart's local space, or nil outside the
    /// ring.
    ///
    /// Hover is resolved here, not from the wedge controls: every control fills
    /// the same square, so a view-level hover region would always belong to
    /// whichever slice draws last. The hairline gaps between slices count as
    /// their neighbours; a click stays bounded by each wedge's own shape.
    static func category(
        at point: CGPoint,
        in geometry: SunburstGeometry,
        segments: [Segment]
    ) -> FileCategory? {
        let band = geometry.radii(ring: 1)
        let dx = point.x - geometry.center.x
        let dy = point.y - geometry.center.y
        let distance = hypot(dx, dy)
        guard distance >= band.inner, distance <= band.outer else { return nil }

        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return segments.first { angle >= $0.start && angle <= $0.end }?.category
    }
}

/// The category breakdown as the explorer's list: one row per category, largest
/// first, with the share drawn against the scan's whole.
struct CategoryShareList: View {
    let shares: [CategoryShare]
    @Binding var hovered: FileCategory?
    let onSelect: (FileCategory) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shares) { share in
                    row(share)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Categories"))
    }

    private func row(_ share: CategoryShare) -> some View {
        let isHovered = hovered == share.category
        return Button {
            onSelect(share.category)
        } label: {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: share.category.symbolName)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: DS.Spacing.xLarge, alignment: .center)
                VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                        Text(share.category.displayName)
                            .font(DS.Typography.body)
                            .foregroundStyle(DS.Color.primaryText)
                        Spacer(minLength: DS.Spacing.small)
                        Text(ByteFormat.string(share.logicalSize))
                            .font(DS.Typography.figures)
                            .foregroundStyle(DS.Color.primaryText)
                        Text(PercentFormat.ofWhole(share.share))
                            .font(DS.Typography.figures)
                            .foregroundStyle(DS.Color.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Color.clear
                        .frame(height: DS.Size.listRowDetailMinHeight)
                        .overlay(alignment: .leading) {
                            bar(share, isHovered: isHovered)
                        }
                }
                Image(systemName: "chevron.right")
                    .font(DS.Icon.detail)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: DS.Spacing.large, alignment: .center)
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.small)
            .dsHoverableRow(isHovered: isHovered, radius: DS.Radius.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = share.category
            } else if hovered == share.category {
                hovered = nil
            }
        }
        .help(L10n.format(
            "%@ · %@ · %@",
            share.category.displayName,
            ByteFormat.string(share.logicalSize),
            PercentFormat.ofWhole(share.share)
        ))
        .accessibilityLabel(L10n.format(
            "%@, %@, %@",
            share.category.displayName,
            ByteFormat.string(share.logicalSize),
            PercentFormat.ofWhole(share.share)
        ))
        .accessibilityHint(L10n.string("Shows the largest files in this category"))
    }

    private func bar(_ share: CategoryShare, isHovered: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Color.rule.opacity(0.7))
                Capsule()
                    .fill(isHovered ? DS.Color.accent : DS.Color.graphite)
                    .frame(width: max(2, geometry.size.width * share.share))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
