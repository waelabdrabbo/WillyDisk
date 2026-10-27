import SwiftUI

// MARK: - Row hover

extension View {
    /// The one hover surface for a clickable row.
    ///
    /// `radius` follows the row's structure: pass `nil` only for a surface that
    /// must meet a hard edge, and `DS.Radius.medium` for the app's inset rows.
    /// Selection is drawn by the row, never here; this modifier only answers
    /// "where is the pointer".
    public func dsHoverableRow(
        isHovered: Bool,
        radius: CGFloat? = DS.Radius.medium
    ) -> some View {
        modifier(DSHoverableRowModifier(isHovered: isHovered, radius: radius))
    }
}

private struct DSHoverableRowModifier: ViewModifier {
    let isHovered: Bool
    let radius: CGFloat?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? 0, style: .continuous)
        content
            .background(shape.fill(DS.Color.accent.opacity(isHovered ? DS.Opacity.rowHover : 0)))
    }
}

// MARK: - Text actions

/// A text action that reads as a link: the app's accent (or the warning tint for
/// a stale result), one type step, a hover wash, and the same 28-pt hit target an
/// icon button reserves.
struct InlineActionButton: View {
    enum Tone: Equatable {
        case accent
        case warning
    }

    /// Which side of the label the glyph sits on.
    ///
    /// A leading glyph names the object an action works on; a disclosure
    /// chevron goes after the label, where the reader looks for more.
    enum IconPlacement: Equatable {
        case leading
        case trailing
    }

    let title: String
    let systemImage: String?
    let iconPlacement: IconPlacement
    let tone: Tone
    let fillsWidth: Bool
    let action: () -> Void

    @State private var isHovered = false

    init(
        _ title: String,
        systemImage: String? = nil,
        iconPlacement: IconPlacement = .leading,
        tone: Tone = .accent,
        fillsWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.iconPlacement = iconPlacement
        self.tone = tone
        self.fillsWidth = fillsWidth
        self.action = action
    }

    private var tint: Color {
        tone == .accent ? DS.Color.accent : DS.Color.warning
    }

    @ViewBuilder
    private var icon: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(DS.Icon.detail)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xxSmall) {
                if iconPlacement == .leading {
                    icon
                }
                Text(title)
                    .font(DS.Typography.callout)
                    .lineLimit(1)
                if iconPlacement == .trailing {
                    icon
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Spacing.xSmall)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(minHeight: DS.Size.iconButton)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(tint.opacity(isHovered ? DS.Opacity.rowHover : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Icon actions

/// An icon-only action with one hit target on every surface.
///
/// A header group gives its icons the bordered chip; a row or a banner uses the
/// borderless form. Both reserve `DS.Size.iconButton`, and both carry the same
/// tooltip and spoken label.
struct IconActionButton: View {
    enum Surface: Equatable {
        case header
        case inline
    }

    let symbol: String
    let help: String
    var surface: Surface = .header
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        switch surface {
        case .header:
            button
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .inline:
            button.buttonStyle(.borderless)
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Icon.inline)
                .foregroundStyle(surface == .header ? DS.Color.primaryText : DS.Color.secondaryText)
        }
        .frame(width: DS.Size.iconButton, height: DS.Size.iconButton)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Section labels

/// A section's name on a custom surface: one caption step in graphite, with an
/// optional rule that runs to the panel edge. Settings keeps the native grouped
/// Form headers; this is for the hand-built screens.
struct SectionLabel: View {
    let title: String
    let rule: Bool

    init(_ title: String, rule: Bool = false) {
        self.title = title
        self.rule = rule
    }

    var body: some View {
        HStack(spacing: DS.Spacing.small) {
            Text(title)
                .font(DS.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DS.Color.graphite)
                .fixedSize()
            if rule {
                Rectangle()
                    .fill(DS.Color.rule)
                    .frame(height: DS.Stroke.hairline)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Warnings

/// One inline warning: an icon, an optional title, and the message, on the one
/// warning wash. Full-width banners and inset refusal blocks share it, so the
/// same warning has the same shape everywhere.
struct WarningNotice: View {
    let title: String?
    let message: String
    let systemImage: String

    init(
        _ message: String,
        title: String? = nil,
        systemImage: String = "exclamationmark.triangle.fill"
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: title == nil ? .center : .top, spacing: DS.Spacing.small) {
            Image(systemName: systemImage)
                .font(DS.Icon.inline)
                .foregroundStyle(DS.Color.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                if let title {
                    Text(title)
                        .font(DS.Typography.callout.weight(.semibold))
                }
                Text(message)
                    .font(title == nil ? DS.Typography.callout : DS.Typography.caption)
                    .foregroundStyle(title == nil ? DS.Color.primaryText : DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            DS.Color.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}
