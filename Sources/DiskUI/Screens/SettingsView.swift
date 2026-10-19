import SwiftUI

/// The app's preferences window.
///
/// Appearance is the one preference that belongs to the app rather than to a
/// scan, so it lives here instead of in the Home toolbar. The value is the same
/// `@AppStorage` entry the app shell applies at launch; changing it updates
/// every open window immediately.
@MainActor
public struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    @FocusState private var listFocused: Bool

    public init() {}

    public var body: some View {
        Form {
            Section {
                VStack(spacing: 0) {
                    ForEach(Array(AppAppearance.allCases.enumerated()), id: \.element) { index, option in
                        appearanceRow(option)
                        if index < AppAppearance.allCases.count - 1 {
                            Divider()
                                .padding(.leading, DS.Spacing.xLarge + DS.Spacing.medium)
                        }
                    }
                }
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .accessibilityLabel("Appearance")

                Text("System follows your Mac. Light or Dark holds that appearance for WillyDisk alone.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Appearance")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 300)
        .onChange(of: appearance) { _, choice in
            AppAppearance.apply(choice)
        }
    }

    /// A full-row control: the label, symbol, and radio are one button so any
    /// part of the row selects the option. Keyboard focus belongs to the list,
    /// not to the individual rows, which keeps the accent ring on the active
    /// choice while the arrow keys move the selection.
    private func appearanceRow(_ option: AppAppearance) -> some View {
        let selected = appearance == option
        return Button {
            appearance = option
            listFocused = true
        } label: {
            HStack(spacing: DS.Spacing.small) {
                Image(systemName: option.symbolName)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: DS.Spacing.xLarge, alignment: .center)
                Text(option.label)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Color.primaryText)
                Spacer(minLength: 0)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(DS.Typography.title2)
                    .foregroundStyle(selected ? DS.Color.accent : DS.Color.secondaryText)
            }
            .padding(.horizontal, DS.Spacing.small)
            .padding(.vertical, DS.Spacing.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .overlay {
            if listFocused && selected {
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .strokeBorder(DS.Color.accent, lineWidth: 2)
                    .padding(1)
            }
        }
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func moveSelection(by offset: Int) {
        let options = AppAppearance.allCases
        guard let index = options.firstIndex(of: appearance) else { return }
        let next = min(max(index + offset, 0), options.count - 1)
        guard next != index else { return }
        appearance = options[next]
    }
}
