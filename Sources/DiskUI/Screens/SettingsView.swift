import SwiftUI
import AppKit

/// The app's preferences window.
///
/// Appearance belongs to the app rather than to a scan. The scan defaults and
/// exclusions belong to every scan the user starts, and they are the same
/// `ScanOptionsStore.shared` values the source screen's Scan Options sheet
/// edits: there is one store, so the two windows cannot show different choices.
@MainActor
public struct SettingsView: View {
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    @State private var optionsStore: ScanOptionsStore
    @State private var hoveredAppearance: AppAppearance?
    @FocusState private var listFocused: Bool

    public init(optionsStore: ScanOptionsStore = .shared) {
        _optionsStore = State(initialValue: optionsStore)
    }

    public var body: some View {
        Form {
            appearanceSection
            scanDefaultsSection
            exclusionsSection
        }
        .formStyle(.grouped)
        // The window is its own scene, so it does not inherit the tint
        // `ContentView` sets for the main window; the same signal ink applies.
        .tint(DS.Color.signal)
        .frame(width: 460, height: 760)
        .onChange(of: appearance) { _, choice in
            AppAppearance.apply(choice)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
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
            .padding(.vertical, DS.Spacing.small)
            .dsHoverableRow(isHovered: hoveredAppearance == option, radius: DS.Radius.medium)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { inside in
            if inside {
                hoveredAppearance = option
            } else if hoveredAppearance == option {
                hoveredAppearance = nil
            }
        }
        .overlay {
            if listFocused && selected {
                RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                    .strokeBorder(DS.Color.accent, lineWidth: DS.Stroke.focus)
                    .padding(DS.Spacing.hairline)
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

    // MARK: - Scan defaults

    private var scanDefaultsSection: some View {
        Section {
            ScanOptionToggle(
                title: "Include hidden items",
                detail: "Names macOS hides, such as ~/Library, dotfiles, and caches.",
                isOn: optionBinding(\.includeHidden)
            )
            ScanOptionToggle(
                title: "Stay on this volume",
                detail: "Do not follow folders that point to another disk or network share.",
                isOn: optionBinding(\.stayOnVolume)
            )
            ScanOptionToggle(
                title: "Follow symbolic links",
                detail: "Count a link's target, skipping links that leave the scan.",
                isOn: optionBinding(\.followSymlinks)
            )

            Text("The same values the Scan Options sheet on the source screen edits.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Scan Options")
        }
    }

    // MARK: - Exclusions

    private var exclusionsSection: some View {
        Section {
            if optionsStore.options.excludedPaths.isEmpty {
                Text("Nothing excluded. Scans include every item they can read.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(optionsStore.options.excludedPaths, id: \.self) { url in
                    exclusionRow(url)
                }
            }

            Button("Add Path…") {
                addExclusions()
            }
            .controlSize(.small)

            Text("Excluded items are left out of every scan's totals and reported in Coverage. The scanned location always stays included.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Excluded Paths")
        }
    }

    /// A path the scans leave out, with the remove action beside it. The row
    /// shows the shortened path; the exact location is in its tooltip and its
    /// spoken label, so two folders with the same name stay distinguishable.
    private func exclusionRow(_ url: URL) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "nosign")
                .font(DS.Icon.detail)
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)

            Text(PathFormat.abbreviated(url.path))
                .font(DS.Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)

            Spacer(minLength: 0)

            IconActionButton(
                symbol: "xmark",
                help: "Stop excluding \(url.path)",
                surface: .inline
            ) {
                optionsStore.removeExclusion(url)
            }
            .accessibilityLabel("Remove exclusion \(url.path)")
        }
        .padding(.vertical, DS.Spacing.xxSmall)
    }

    private func addExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Choose files or folders every scan should leave out."
        guard panel.runModal() == .OK else { return }
        optionsStore.addExclusions(panel.urls)
    }

    /// Binds one field of the shared store, so a switch writes the store the
    /// source screen reads rather than a copy of it.
    private func optionBinding(_ keyPath: WritableKeyPath<ScanOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { optionsStore.options[keyPath: keyPath] },
            set: { optionsStore.options[keyPath: keyPath] = $0 }
        )
    }
}
