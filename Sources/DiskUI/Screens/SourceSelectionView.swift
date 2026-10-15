import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskCore

/// Screen A — source selection, and the home for a scan running in the
/// background.
///
/// Distinctive identity, headline + supporting text, mounted volumes and recent
/// locations each with an inline Scan/View action, and "Choose a Folder…"
/// (native `NSOpenPanel`). A folder picked or dropped stages into a card with a
/// real "Start Scan" action. Every control performs a real action on real scan
/// data.
///
/// The location that occupies the engine's single scan slot is shown in its own
/// row as that scan's status with a View action instead of a start action, and
/// the other start actions are held back while a scan runs, so this screen can
/// be used mid-scan without ever starting a second scan or hiding the first.
///
/// The toolbar holds the app's appearance choice, which is a preference rather
/// than scan state: `AppAppearance` carries the value and the app shell applies
/// it to the app.
@MainActor
public struct SourceSelectionView: View {
    @State private var viewModel: ScanViewModel
    @State private var selectedURL: URL?
    @State private var isDragOver = false
    @State private var recentLocations: [URL] = RecentLocations.load()
    @State private var volumes: [VolumeInfo] = []
    /// The app's appearance preference. The toolbar menu writes it and the app
    /// shell reads the same stored value, so the menu reports what the window
    /// actually shows.
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system

    public init(viewModel: ScanViewModel = ScanViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    /// The recent locations this screen lists, which excludes any that a volume
    /// row already covers.
    ///
    /// A volume is recorded as recent each time it is scanned, so without this a
    /// drive would be offered twice: once under Volumes with its capacity, and
    /// again under Recent. The drive keeps the volume row, which says more about
    /// it, and drops out of Recent; a location inside a volume is not that
    /// volume, so it stays.
    private var recentLocationsShown: [URL] {
        recentLocations.filter { !VolumeInfo.isMountPoint($0, ofVolumes: volumes) }
    }

    public var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: DS.Spacing.section) {
                    hero
                    if case .failed(let message) = viewModel.phase {
                        failureBanner(message)
                    }
                    if let url = selectedURL {
                        selectedSourceCard(url)
                    }
                    volumesSection
                    recentSection
                    chooseFolderSection
                }
                .padding(DS.Spacing.xxLarge)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: selectedURL)
            }

            if isDragOver {
                dropOverlay
            }
        }
        .task { volumes = VolumeInfo.enumerate() }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                appearanceMenu
            }
        }
    }

    /// The gear: the app's appearance, as one menu of the three choices.
    ///
    /// The menu reports and writes the stored preference the app shell applies to
    /// the app, so picking an appearance here changes every window at once and the
    /// choice survives the next launch.
    private var appearanceMenu: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Label(option.label, systemImage: option.symbolName)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Appearance", systemImage: "gearshape")
        }
        .help("Choose the app appearance: system, light, or dark")
        .accessibilityLabel("Appearance")
        .accessibilityValue(appearance.label)
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "internaldrive.fill")
                .font(DS.Icon.hero)
                .foregroundStyle(DS.Color.accent)
            Text("WillyDisk")
                .font(DS.Typography.largeTitle)
            Text("See what's taking up space, then find and reclaim it.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DS.Spacing.section)
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Color.warning)
            Text(message)
                .font(DS.Typography.callout)
        }
        .padding(DS.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func selectedSourceCard(_ url: URL) -> some View {
        let slot = viewModel.scanSlot(for: url)
        let sourceName = LocationName.of(url)
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(DS.Color.accent)
                    .accessibilityHidden(true)
                Text(sourceName)
                    .font(DS.Typography.title2)
                Spacer()
                Button {
                    selectedURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Clear selection")
                .accessibilityLabel("Clear selection")
            }
            Text(url.path)
                .font(DS.Typography.monospaced)
                .foregroundStyle(DS.Color.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if let slot {
                scanStatusBlock(slot)
                Button {
                    viewModel.showResults()
                } label: {
                    Label("View Results", systemImage: "chart.pie")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Open the results of the scan of this location")
                .accessibilityLabel("View scan results for \(sourceName)")
            } else {
                Button {
                    startScan(url)
                } label: {
                    Label("Start Scan", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isScanning)
                .help(startHelp(sourceName))
                .accessibilityHint(startHint(sourceName))
            }
        }
        .padding(DS.Spacing.large)
        .dsSurface()
    }

    @ViewBuilder
    private var volumesSection: some View {
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                sectionHeader("Volumes")
                VStack(spacing: DS.Spacing.small) {
                    ForEach(volumes) { volume in
                        volumeRow(volume)
                    }
                }
                .padding(DS.Spacing.large)
                .dsSurface()
            }
        }
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        let slot = viewModel.scanSlot(for: volume.url)
        return HStack(spacing: DS.Spacing.medium) {
            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                .font(DS.Icon.small)
                .foregroundStyle(DS.Color.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                Text(volume.name)
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.Color.primaryText)
                if let total = volume.totalCapacity {
                    let used = volume.usedCapacity ?? 0
                    Text("\(ByteFormat.string(used)) of \(ByteFormat.string(total)) used")
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                // The location on the engine's scan slot reports that scan's
                // status in place of a start-scan action.
                if let slot {
                    scanStatusBlock(slot)
                }
            }
            // One composed label for the row's facts — including the status of a
            // scan this location is running. The gauge below repeats the capacity
            // visually, so it stays out of the accessibility tree.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(volumeRowLabel(volume, slot: slot))
            Spacer()
            if let fraction = volume.usedFraction {
                Gauge(value: fraction) {}
                    .gaugeStyle(.accessoryLinearCapacity)
                    .frame(width: DS.Size.gaugeWidth)
                    .accessibilityHidden(true)
            }
            sourceRowAction(for: volume.url, name: volume.name, slot: slot)
        }
        .padding(.vertical, DS.Spacing.xSmall)
        .accessibilityElement(children: .contain)
    }

    /// The row's spoken facts: the location, its capacity, and — when it is the
    /// location being scanned — that scan's state and honest counters.
    private func volumeRowLabel(_ volume: VolumeInfo, slot: ScanSlotPresentation?) -> String {
        guard let slot else { return volumeSummary(volume) }
        return "\(volumeSummary(volume)), \(slot.accessibilityLabel)"
    }

    /// The status of the scan running on a location, as its source row reads it.
    ///
    /// Live counters come straight from the engine; nothing here is inferred, and
    /// a completion fraction appears only when the engine reports a reliable one.
    ///
    /// The status is the row's wording and its counts, never the directory the
    /// engine happens to be reading: that path is a long monospaced run that
    /// changes many times a second, and it pushed the row taller for a fact the
    /// counters already cover.
    @ViewBuilder
    private func scanStatusBlock(_ slot: ScanSlotPresentation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
            HStack(spacing: DS.Spacing.xSmall) {
                if slot.isLive {
                    scanProgressIndicator(slot)
                } else {
                    Image(systemName: slot.state == .finished ? "checkmark.circle.fill" : "stop.circle")
                        .font(DS.Icon.detail)
                        .foregroundStyle(slot.state == .finished ? DS.Color.success : DS.Color.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(slot.label)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.primaryText)
                if let detail = slot.detail {
                    Text(detail)
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func scanProgressIndicator(_ slot: ScanSlotPresentation) -> some View {
        if let fraction = slot.fraction {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .frame(width: DS.Size.rowProgressWidth)
                .accessibilityHidden(true)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
    }

    /// The trailing action a source row offers for a location.
    ///
    /// When the location occupies the engine's scan slot the row already reports
    /// that scan inline, so this is a View that opens its results; otherwise it
    /// is an inline start that is held back while another scan runs. Volumes and
    /// Recent rows share this one helper so the two never drift apart.
    @ViewBuilder
    private func sourceRowAction(for url: URL, name: String, slot: ScanSlotPresentation?) -> some View {
        if slot != nil {
            Button {
                viewModel.showResults()
            } label: {
                Label("View", systemImage: "chart.pie")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Open the scan results for \(name)")
            .accessibilityLabel("View scan results for \(name)")
        } else {
            Button {
                startScan(url)
            } label: {
                Label("Scan", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.isScanning)
            .help(startHelp(name))
            .accessibilityLabel("Scan \(name)")
            .accessibilityHint(startHint(name))
        }
    }

    /// Why a start action is unavailable, or what it starts.
    private func startHelp(_ name: String) -> String {
        viewModel.isScanning
            ? "A scan is already running — open it with View, or stop it to start another"
            : "Scan \(name)"
    }

    /// What a start action does, or why it cannot act right now.
    private func startHint(_ name: String) -> String {
        viewModel.isScanning
            ? "Unavailable while another scan is running"
            : "Starts scanning \(name)"
    }

    /// The volume's name, usage, free space, and fullness, as one spoken phrase.
    private func volumeSummary(_ volume: VolumeInfo) -> String {
        var parts = [volume.name]
        if let total = volume.totalCapacity, let used = volume.usedCapacity {
            parts.append("\(ByteFormat.string(used)) of \(ByteFormat.string(total)) used")
        }
        if let available = volume.availableCapacity {
            parts.append("\(ByteFormat.string(available)) available")
        }
        if let fraction = volume.usedFraction {
            parts.append("\(Int((fraction * 100).rounded()))% full")
        }
        if volume.isReadOnly {
            parts.append("read only")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentLocationsShown.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.medium) {
                sectionHeader("Recent")
                VStack(spacing: 0) {
                    ForEach(recentLocationsShown, id: \.self) { url in
                        recentRow(url)
                        if url != recentLocationsShown.last {
                            Divider()
                        }
                    }
                }
                .padding(DS.Spacing.large)
                .dsSurface()
            }
        }
    }

    private func recentRow(_ url: URL) -> some View {
        let slot = viewModel.scanSlot(for: url)
        let name = LocationName.of(url)
        return HStack(spacing: DS.Spacing.medium) {
            Image(systemName: "clock")
                .foregroundStyle(DS.Color.tertiaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Color.primaryText)
                Text(url.path)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The location on the engine's scan slot reports that scan's
                // status in place of a start-scan action.
                if let slot {
                    scanStatusBlock(slot)
                }
            }
            // One composed label for the row's facts — including the status of a
            // scan this location is running — so the path and status read as one
            // phrase rather than disconnected fragments.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(recentRowLabel(name: name, path: url.path, slot: slot))
            Spacer()
            sourceRowAction(for: url, name: name, slot: slot)
        }
        .padding(.vertical, DS.Spacing.small)
        .accessibilityElement(children: .contain)
    }

    /// The recent row's spoken facts: the location, its path, and — when it is
    /// the location being scanned — that scan's state and honest counters.
    private func recentRowLabel(name: String, path: String, slot: ScanSlotPresentation?) -> String {
        guard let slot else { return "\(name), \(path)" }
        return "\(name), \(path), \(slot.accessibilityLabel)"
    }

    private var chooseFolderSection: some View {
        Button {
            chooseFolder()
        } label: {
            Label("Choose a Folder…", systemImage: "folder")
                .frame(minWidth: DS.Size.wideActionMinWidth)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .help("Pick any folder or volume to scan")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DS.Typography.caption)
            .textCase(.uppercase)
            .foregroundStyle(DS.Color.secondaryText)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
            .fill(DS.Color.accent.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Color.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
            )
            .overlay(
                VStack(spacing: DS.Spacing.small) {
                    Image(systemName: "folder.badge.plus")
                        .font(DS.Icon.dropTarget)
                        .foregroundStyle(DS.Color.accent)
                    Text("Drop a folder to select it")
                        .font(DS.Typography.headline)
                }
            )
            .padding(DS.Spacing.medium)
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder or volume to scan."
        if panel.runModal() == .OK, let url = panel.url {
            selectedURL = url
        }
    }

    private func startScan(_ url: URL) {
        RecentLocations.record(url)
        recentLocations = RecentLocations.load()
        viewModel.start(root: url)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let url = item as? URL { return url }
                if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                return nil
            }()
            guard let url else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            Task { @MainActor in
                self.selectedURL = url
            }
        }
        return true
    }
}
