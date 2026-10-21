import SwiftUI
import DiskCore

/// The scan cut by file category, as one ring around the platter's centre.
///
/// The sunburst answers "what is in this folder"; this answers "what is this scan
/// made of", so it draws the whole scan at once and never drills into a folder.
/// Choosing a wedge opens that category in place; the open category stays
/// outlined and named in the centre, so the ring is the way back out as well as in.
struct CategoryRingView: View {
    let breakdown: CategoryBreakdown
    let centerLabel: String
    /// The category the explorer is inside, if any.
    let selected: FileCategory?
    @Binding var hovered: FileCategory?
    let onSelect: (FileCategory) -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if breakdown.isEmpty {
                    placeholder(message: "No file bytes to group yet")
                } else if side < DS.Sunburst.minimumSize {
                    placeholder(message: "Enlarge this pane to see the chart",
                                icon: "arrow.up.left.and.arrow.down.right")
                } else {
                    ring(side: side)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scan by file category")
    }

    // MARK: - Ring

    private func ring(side: CGFloat) -> some View {
        let geometry = SunburstGeometry(side: side, ringCount: 1)
        let segments = CategoryRingLayout.segments(from: breakdown.shares)
        // The pointer previews a category; otherwise the open category is the
        // one the centre names.
        let active = (hovered ?? selected).flatMap { breakdown.share(of: $0) }
        let outlined = hovered ?? selected
        let band = geometry.radii(ring: 1)

        return ZStack {
            Circle()
                .fill(DS.Color.enamel)
                .overlay {
                    Circle().strokeBorder(DS.Color.rule, lineWidth: DS.Stroke.hairline)
                }
                .frame(width: geometry.outerRadius * 2, height: geometry.outerRadius * 2)

            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                let shape = wedge(segment, geometry: geometry, inner: band.inner, outer: band.outer)
                Button {
                    onSelect(segment.category)
                } label: {
                    shape
                        .fill(ChartPalette.categoryColor(index: index, count: segments.count))
                        .opacity(hovered == nil || hovered == segment.category ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                .contentShape(shape)
                .onHover { inside in
                    if inside {
                        hovered = segment.category
                    } else if hovered == segment.category {
                        hovered = nil
                    }
                }
                .help(helpText(for: segment.category))
                .accessibilityLabel(accessibilityLabel(for: segment.category))
                .accessibilityHint(selected == segment.category
                                   ? "Closes this category and shows all categories"
                                   : "Shows the largest files in this category")
                .accessibilityAddTraits(selected == segment.category ? [.isSelected] : [])
            }

            if let outlined {
                let segment = segments.first { $0.category == outlined }
                if let segment {
                    wedge(segment, geometry: geometry, inner: band.inner, outer: band.outer)
                        .stroke(DS.Color.accent, lineWidth: DS.Stroke.emphasis)
                        .allowsHitTesting(false)
                }
            }

            centerDisc(radius: geometry.innerRadius, center: geometry.center, active: active)
        }
        .frame(width: side, height: side)
    }

    private func wedge(
        _ segment: CategoryRingLayout.Segment,
        geometry: SunburstGeometry,
        inner: CGFloat,
        outer: CGFloat
    ) -> SunburstWedge {
        SunburstWedge(
            center: geometry.center,
            innerRadius: inner,
            outerRadius: outer,
            startAngle: segment.start,
            endAngle: segment.end,
            angularGap: geometry.angularGap(ring: 1),
            radialGap: DS.Sunburst.radialGap
        )
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
        .position(center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
    }

    private func helpText(for category: FileCategory) -> String {
        guard let share = breakdown.share(of: category) else { return category.displayName }
        return "\(category.displayName) · \(ByteFormat.string(share.logicalSize)) · \(PercentFormat.ofWhole(share.share))"
    }

    private func accessibilityLabel(for category: FileCategory) -> String {
        guard let share = breakdown.share(of: category) else { return category.displayName }
        return "\(category.displayName), \(ByteFormat.string(share.logicalSize)), \(PercentFormat.ofWhole(share.share)) of the scan"
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
        .accessibilityLabel("Categories")
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
                VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
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
                    bar(share, isHovered: isHovered)
                }
                Image(systemName: "chevron.right")
                    .font(DS.Icon.detail)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: DS.Spacing.large, alignment: .center)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.small)
            .background {
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(isHovered ? DS.Color.accent.opacity(DS.Opacity.rowHover) : .clear)
            }
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
        .help("\(share.category.displayName) · \(ByteFormat.string(share.logicalSize)) · \(PercentFormat.ofWhole(share.share))")
        .accessibilityLabel("\(share.category.displayName), \(ByteFormat.string(share.logicalSize)), \(PercentFormat.ofWhole(share.share))")
        .accessibilityHint("Shows the largest files in this category")
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
