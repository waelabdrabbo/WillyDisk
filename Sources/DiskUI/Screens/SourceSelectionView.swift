import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskCore
import DiskLocalization

/// Screen A — source selection, and the home for a scan running in the
/// background.
///
/// Distinctive identity, headline + supporting text, mounted volumes and recent
/// locations each with an inline Scan/View Results action, and "Choose a Folder…"
/// (native `NSOpenPanel`). A folder picked or dropped stages into a card with a
/// real "Scan" action. Every control performs a real action on real scan
/// data.
///
/// The location that occupies the engine's single scan slot is shown in its own
/// row as that scan's status with a View action instead of a start action, and
/// the other start actions are held back while a scan runs, so this screen can
/// be used mid-scan without ever starting a second scan or hiding the first.
///
/// The toolbar holds the window-level commands: scan options and the folder
/// picker. The app's appearance is a Settings preference, applied by the app
/// shell rather than by this screen.
@MainActor
public struct SourceSelectionView: View {
    @State private var viewModel: ScanViewModel
    @State private var isDragOver = false
    @State private var hoveredSource: URL?
    @State private var hoveredPreset: ScanPreset.ID?
    @State private var recentLocations: [URL] = RecentLocations.load()
    @State private var volumes: [VolumeInfo] = []
    @State private var presets: [ScanPreset] = []
    /// What the next scan includes. This is the one store Settings edits too, so
    /// the sheet and the preferences window always show the same values, and a
    /// scan started from the menu or a drop uses them as well.
    @State private var scanOptionsStore: ScanOptionsStore
    @State private var showingScanOptions = false
    @State private var isShowingAllRecents = false

    /// How many recent locations the section shows before offering Show All.
    private static let collapsedRecentCount = 3

    public init(viewModel: ScanViewModel = ScanViewModel()) {
        _viewModel = State(initialValue: viewModel)
        _scanOptionsStore = State(initialValue: viewModel.optionsStore)
    }

    private var scanOptions: ScanOptions {
        scanOptionsStore.options
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
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: DS.Spacing.section) {
                        hero
                        if case .failed(let message) = viewModel.phase {
                            failureBanner(message)
                        }
                        presetsSection
                        volumesSection
                        recentSection
                    }
                    .padding(DS.Spacing.xxLarge)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    // Short lists sit in the middle of the window instead of
                    // hanging from the top edge with the rest of the window empty.
                    .frame(minHeight: proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom,
                           alignment: .center)
                }
            }

            if isDragOver {
                dropOverlay
            }
        }
        .background(WindowFocusReset().frame(width: 0, height: 0))
        .task {
            volumes = VolumeInfo.enumerate()
            presets = await ScanPresetCatalog.resolved()
            // The recent rows read the last finished run for each location.
            // Load the shared history here when this screen is the first to
            // need it, rather than re-reading the store on every return.
            if let history = viewModel.history, history.snapshot.records.isEmpty {
                await history.reload()
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                scanOptionsToolbarButton
            }
            ToolbarItem(placement: .primaryAction) {
                chooseFolderToolbarButton
            }
        }
    }

    // MARK: - Sections

    /// The lockup that names the app: the mark on the left, and beside it the
    /// wordmark with the one line that says what the window is for.
    private var hero: some View {
        HStack(alignment: .center, spacing: DS.Spacing.large) {
            WillyDiskMark(size: 56)
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                Text(L10n.string("WillyDisk"))
                    .font(DS.Typography.largeTitle)
                    .tracking(DS.Typography.displayTracking)
                    .foregroundStyle(DS.Color.primaryText)
                Text(L10n.string("Choose a folder. See what it weighs."))
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Spacing.section)
    }

    private func failureBanner(_ message: String) -> some View {
        WarningNotice(message)
    }

    /// The usual large folders, so the common scans do not begin with a file
    /// panel. A preset starts the same scan as picking the folder by hand, and
    /// one that is missing stays visible but disabled instead of vanishing.
    ///
    /// The slots are one panel cut by hairlines rather than six cards, and each
    /// slot leads with its location's symbol: the group reads as a ruled index,
    /// not as a kit of tiles.
    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            sectionHeader(L10n.string("Quick scans"))
            if !presets.isEmpty {
                LazyVGrid(columns: presetColumns, spacing: 0) {
                    ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                        presetCell(preset, index: index)
                    }
                }
                .background(DS.Color.enamel.opacity(DS.Opacity.contentPanel))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .strokeBorder(DS.Color.rule, lineWidth: DS.Stroke.hairline)
                }
            }
        }
    }

    /// Three equal slots across the panel. The presets are a fixed short list, so
    /// a fixed lattice is what lets the hairlines meet at the corners.
    private var presetColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)
    }

    private func presetCell(_ preset: ScanPreset, index: Int) -> some View {
        let column = index % 3
        let row = index / 3
        return Button {
            startScan(preset.url)
        } label: {
            HStack(alignment: .presetNameMiddle, spacing: DS.Spacing.small) {
                // The location's own symbol, in the slot's gutter: one glyph
                // per slot, in the rule's grey, so the accent stays reserved for
                // the capacity gauge. The name beside it already says the word.
                Image(systemName: preset.symbolName)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(DS.Color.graphite)
                    .frame(width: DS.Size.presetGlyph, alignment: .leading)
                    .alignmentGuide(.presetNameMiddle) { $0[VerticalAlignment.center] }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Spacing.hairline) {
                    Text(preset.displayName)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Color.primaryText)
                    // A live preset is only its name: the slot already says
                    // what it scans. A missing one still has to say why it
                    // cannot act, so it keeps the caption line.
                    if !preset.isAvailable {
                        Text(L10n.string("Not on this Mac"))
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                // The slot's action cue: graphite at rest, accent under the
                // pointer. A missing preset has nothing to start, so it
                // carries none.
                if preset.isAvailable {
                    Image(systemName: "arrow.right")
                        .flipsForRightToLeftLayoutDirection(true)
                        .font(DS.Icon.inline)
                        .foregroundStyle(hoveredPreset == preset.id ? DS.Color.accent : DS.Color.mutedText)
                        .alignmentGuide(.presetNameMiddle) { $0[VerticalAlignment.center] }
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Spacing.medium)
            .padding(.vertical, DS.Spacing.medium)
            // Fill the whole grid slot, not just the text: a row is as tall as
            // its tallest slot, and the hover wash has to reach the hairlines.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsHoverableRow(isHovered: hoveredPreset == preset.id, radius: nil)
        .overlay(alignment: .top) {
            if row > 0 {
                Rectangle().fill(DS.Color.rule).frame(height: DS.Stroke.hairline)
            }
        }
        .overlay(alignment: .leading) {
            if column > 0 {
                Rectangle().fill(DS.Color.rule).frame(width: DS.Stroke.hairline)
            }
        }
        .disabled(viewModel.isScanning || !preset.isAvailable)
        .opacity(preset.isAvailable && !viewModel.isScanning ? 1 : DS.Opacity.disabled)
        .onHover { inside in
            guard !viewModel.isScanning, preset.isAvailable else {
                hoveredPreset = nil
                return
            }
            if inside {
                hoveredPreset = preset.id
            } else if hoveredPreset == preset.id {
                hoveredPreset = nil
            }
        }
        .help(preset.isAvailable
            ? L10n.format("Scan %@ at %@", preset.displayName, preset.url.path)
            : L10n.format("%@ is not on this Mac", preset.displayName))
        .accessibilityLabel(L10n.format("Scan %@", preset.displayName))
        .accessibilityHint(preset.isAvailable
            ? preset.url.path
            : L10n.string("This location is not on this Mac"))
    }

    /// The mounted drives as an open list: each row sits on the window and a
    /// hairline, not a card, says where one ends and the next begins.
    @ViewBuilder
    private var volumesSection: some View {
        if !volumes.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                sectionHeader(L10n.string("Volumes"))
                VStack(spacing: 0) {
                    ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                        volumeRow(volume)
                        if index < volumes.count - 1 {
                            rowSeparator
                        }
                    }
                }
            }
        }
    }

    /// The rule between two rows. It runs the list's full width so the stack
    /// reads as one ruled index rather than as separate cards, and it keeps
    /// clear of a row's highlight: a fill that reached the hairline would paint
    /// it out and the row would look unruled while the pointer is on it.
    private var rowSeparator: some View {
        Rectangle()
            .fill(DS.Color.rule)
            .frame(height: DS.Stroke.hairline)
            .padding(.vertical, DS.Spacing.xSmall)
    }

    /// A volume's share of its capacity as a three-quarter ring: the mark's
    /// geometry at row scale, with the percentage set in the well. The figures
    /// beside it carry the exact numbers; the ring says how full at a glance.
    @ViewBuilder
    private func capacityArc(_ volume: VolumeInfo) -> some View {
        if let fraction = volume.usedFraction {
            let used = min(max(fraction, 0), 1)
            ZStack {
                Circle()
                    .trim(from: 0, to: DS.Size.capacityArcSweep)
                    .stroke(DS.Color.rule,
                            style: StrokeStyle(lineWidth: DS.Size.capacityArcWidth, lineCap: .butt))
                    .rotationEffect(.degrees(DS.Size.capacityArcRotation))
                Circle()
                    .trim(from: 0, to: DS.Size.capacityArcSweep * used)
                    .stroke(volume.isLowOnSpace ? DS.Color.warning : DS.Color.signal,
                            style: StrokeStyle(lineWidth: DS.Size.capacityArcWidth, lineCap: .butt))
                    .rotationEffect(.degrees(DS.Size.capacityArcRotation))
                Text(L10n.format("%lld%%", Int((used * 100).rounded())))
                    .font(DS.Typography.gaugeFigures)
                    .foregroundStyle(DS.Color.primaryText)
            }
            .frame(width: DS.Size.capacityArcSize, height: DS.Size.capacityArcSize)
            .accessibilityHidden(true)
        }
    }

    /// The free space left on a nearly full volume, said in words beside its
    /// figures. The ring turns madder at the same threshold, so the reading
    /// never depends on colour alone.
    private func freeSpaceWarning(_ available: Int64) -> some View {
        HStack(spacing: DS.Spacing.xxSmall) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Icon.detail)
                .accessibilityHidden(true)
            Text(L10n.format("Only %@ free", ByteFormat.string(available)))
                .font(DS.Typography.metadataFigures)
                .lineLimit(1)
        }
        .foregroundStyle(DS.Color.warning)
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        let slot = viewModel.scanSlot(for: volume.url)
        let isPrimary = slot != nil && rowResultsArePrimary
        let isEnabled = slot != nil || !viewModel.isScanning
        let isHovered = isEnabled && hoveredSource == volume.url
        return Button {
            if slot != nil {
                viewModel.showResults()
            } else {
                startScan(volume.url)
            }
        } label: {
            HStack(spacing: DS.Spacing.medium) {
                capacityArc(volume)
                VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                    Text(volume.name)
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Color.primaryText)
                    HStack(spacing: DS.Spacing.medium) {
                        if let total = volume.totalCapacity {
                            let used = volume.usedCapacity ?? 0
                            Text(L10n.format("%@ used of %@", ByteFormat.string(used), ByteFormat.string(total)))
                                .font(DS.Typography.metadataFigures)
                                .foregroundStyle(DS.Color.secondaryText)
                                .lineLimit(1)
                        }
                        // A nearly full volume says how much room is left,
                        // beside the figures the ring is drawing. The warning
                        // tint is never the only carrier of that fact.
                        if volume.isLowOnSpace, let available = volume.availableCapacity {
                            freeSpaceWarning(available)
                        }
                        // The location on the engine's scan slot reports that
                        // scan's state on this line, so finishing a scan never
                        // adds a line the row did not already have.
                        if let slot {
                            scanStatus(slot)
                        }
                    }
                }
                Spacer()
                sourceRowAffordance(isView: slot != nil, isPrimary: isPrimary)
            }
            .padding(.vertical, DS.Spacing.small)
            .padding(.horizontal, DS.Spacing.small)
            .background(rowFill(isPrimary: isPrimary, isHovered: isHovered), in: rowShape)
            .dsHoverableRow(isHovered: isHovered && !isPrimary, radius: DS.Radius.medium)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : DS.Opacity.disabled)
        .onHover { inside in
            if inside && isEnabled {
                hoveredSource = volume.url
            } else if hoveredSource == volume.url {
                hoveredSource = nil
            }
        }
        .keyboardShortcut(isPrimary ? .defaultAction : nil)
        .help(slot != nil ? L10n.format("Open the scan results for %@", volume.name) : startHelp(volume.name))
        .accessibilityLabel(volumeRowLabel(volume, slot: slot))
        .accessibilityHint(slot != nil ? L10n.string("Opens the scan results") : startHint(volume.name))
    }

    /// The row's spoken facts: the location, its capacity, and — when it is the
    /// location being scanned — that scan's state and honest counters.
    private func volumeRowLabel(_ volume: VolumeInfo, slot: ScanSlotPresentation?) -> String {
        guard let slot else { return volumeSummary(volume) }
        return L10n.format("%@, %@", volumeSummary(volume), slot.accessibilityLabel)
    }

    /// The state of the scan on a location, set inline beside the row's own
    /// facts so the row keeps its two lines whether or not it has been scanned.
    ///
    /// Live counters come straight from the engine; nothing here is inferred, and
    /// a completion fraction appears only when the engine reports a reliable one.
    /// The status is the row's wording and its counts, never the directory the
    /// engine happens to be reading: that path is a long run that changes many
    /// times a second, and it pushed the row taller for a fact the counters
    /// already cover.
    private func scanStatus(_ slot: ScanSlotPresentation) -> some View {
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
            }
        }
        .lineLimit(1)
        .layoutPriority(1)
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

    /// The row's trailing affordance. The row itself is the control, so this is
    /// a label rather than a second button.
    private func sourceRowAffordance(isView: Bool, isPrimary: Bool) -> some View {
        Text(L10n.string(isView ? "View Results" : "Scan"))
            .font(DS.Typography.caption)
            .fontWeight(.medium)
            .foregroundStyle(DS.Color.accent)
            .accessibilityHidden(true)
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
    }

    /// The wash under a row: the app's accent at `rowPrimary` on the row whose
    /// results are open, lifted to `rowCurrentHover` under the pointer, and the
    /// shared hover wash on every other row. Both stay below a selection, so
    /// "where the pointer is" never reads as "what I clicked".
    private func rowFill(isPrimary: Bool, isHovered: Bool) -> Color {
        guard isPrimary else { return .clear }
        return DS.Color.accent.opacity(isHovered ? DS.Opacity.rowCurrentHover : DS.Opacity.rowPrimary)
    }

    /// Why a start action is unavailable, or what it starts. A recent row passes
    /// its path so the tooltip still names the folder whose visible detail is its
    /// last run.
    private func startHelp(_ name: String, path: String? = nil) -> String {
        if viewModel.isScanning {
            return L10n.string("A scan is already running — open its results, or stop it to start another")
        }
        guard let path else { return L10n.format("Scan %@", name) }
        return L10n.format("Scan %@ at %@", name, path)
    }

    /// What a start action does, or why it cannot act right now.
    private func startHint(_ name: String) -> String {
        viewModel.isScanning
            ? L10n.string("Unavailable while another scan is running")
            : L10n.format("Starts scanning %@", name)
    }

    /// The volume's name, usage, free space, and fullness, as one spoken phrase.
    private func volumeSummary(_ volume: VolumeInfo) -> String {
        var parts = [volume.name]
        if let total = volume.totalCapacity, let used = volume.usedCapacity {
            parts.append(L10n.format("%@ of %@ used", ByteFormat.string(used), ByteFormat.string(total)))
        }
        if let available = volume.availableCapacity {
            parts.append(L10n.format("%@ available", ByteFormat.string(available)))
        }
        if let fraction = volume.usedFraction {
            parts.append(L10n.format("%lld%% full", Int((fraction * 100).rounded())))
        }
        if volume.isReadOnly {
            parts.append(L10n.string("read only"))
        }
        return L10n.list(parts)
    }

    /// The recent locations as the same open list as the volumes: one hairline
    /// between rows, no card of their own.
    ///
    /// Three rows resume the usual work without pushing the rest of the screen
    /// down; a longer list keeps the rest behind Show All. Each row says what the
    /// last finished run measured instead of printing its path, so the section
    /// reads as results rather than as a log of directories.
    @ViewBuilder
    private var recentSection: some View {
        let locations = recentLocationsShown
        if !locations.isEmpty {
            let shown = isShowingAllRecents
                ? locations
                : Array(locations.prefix(Self.collapsedRecentCount))
            let repeatedNames = RecentLocations.repeatedNames(in: locations)
            VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                sectionHeader(L10n.string("Recent"))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, url in
                        recentRow(url, nameIsRepeated: repeatedNames.contains(LocationName.of(url)))
                        if index < shown.count - 1 {
                            rowSeparator
                        }
                    }
                }
                if locations.count > Self.collapsedRecentCount {
                    InlineActionButton(
                        L10n.string(isShowingAllRecents ? "Show Less" : "Show All"),
                        systemImage: isShowingAllRecents ? "chevron.up" : "chevron.down",
                        iconPlacement: .trailing,
                        fillsWidth: true
                    ) {
                        isShowingAllRecents.toggle()
                    }
                    .padding(.top, DS.Spacing.xSmall)
                }
            }
        }
    }

    private func recentRow(_ url: URL, nameIsRepeated: Bool) -> some View {
        let slot = viewModel.scanSlot(for: url)
        let name = LocationName.of(url)
        let detail = RecentLocationDetail.of(
            url: url,
            record: viewModel.history?.records(for: url).first,
            nameIsRepeated: nameIsRepeated
        )
        let isPrimary = slot != nil && rowResultsArePrimary
        let isEnabled = slot != nil || !viewModel.isScanning
        let isHovered = isEnabled && hoveredSource == url
        return Button {
            if slot != nil {
                viewModel.showResults()
            } else {
                startScan(url)
            }
        } label: {
            HStack(spacing: DS.Spacing.medium) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Color.primaryText)
                    HStack(spacing: DS.Spacing.medium) {
                        // A measured run is the usual detail; a path still
                        // appears where it is the only way to tell two rows
                        // apart, or where no finished run exists yet.
                        Text(detail.text)
                            .font(DS.Typography.caption)
                            .foregroundStyle(detail.isPath ? DS.Color.mutedText : DS.Color.secondaryText)
                            .lineLimit(1)
                            .truncationMode(detail.isPath ? .middle : .tail)
                        // The scan's state sits beside the detail, so a scanned
                        // location keeps the same two lines as an unscanned one.
                        if let slot {
                            scanStatus(slot)
                        }
                    }
                }
                Spacer()
                sourceRowAffordance(isView: slot != nil, isPrimary: isPrimary)
            }
            .padding(.vertical, DS.Spacing.small)
            .padding(.horizontal, DS.Spacing.small)
            .background(rowFill(isPrimary: isPrimary, isHovered: isHovered), in: rowShape)
            .dsHoverableRow(isHovered: isHovered && !isPrimary, radius: DS.Radius.medium)
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : DS.Opacity.disabled)
        .onHover { inside in
            if inside && isEnabled {
                hoveredSource = url
            } else if hoveredSource == url {
                hoveredSource = nil
            }
        }
        .keyboardShortcut(isPrimary ? .defaultAction : nil)
        .help(slot != nil
            ? L10n.format("Open the scan results for %@ at %@", name, url.path)
            : startHelp(name, path: url.path))
        .accessibilityLabel(recentRowLabel(name: name, path: url.path, detail: detail, slot: slot))
        .accessibilityHint(slot != nil ? L10n.string("Opens the scan results") : startHint(name))
    }

    /// The recent row's spoken facts: the location, its path, the last run when
    /// one is shown, and — when it is the location being scanned — that scan's
    /// state and honest counters.
    private func recentRowLabel(
        name: String,
        path: String,
        detail: RecentLocationDetail,
        slot: ScanSlotPresentation?
    ) -> String {
        var parts = [name, path]
        if !detail.isPath {
            parts.append(detail.text)
        }
        if let slot {
            parts.append(slot.accessibilityLabel)
        }
        return L10n.list(parts)
    }

    /// Whether the scan on the slot has a result a Home row can open. The row
    /// for that root is always among Volumes or Recent because every start
    /// records the root, so the primary can move to that row.
    private var scannedSourceHasResults: Bool {
        guard let root = viewModel.currentRoot else { return false }
        return viewModel.scanSlot(for: root) != nil
    }

    /// A result row owns the primary action whenever one exists.
    private var rowResultsArePrimary: Bool {
        scannedSourceHasResults
    }

    private var scanOptionsToolbarButton: some View {
        Button {
            showingScanOptions.toggle()
        } label: {
            Label(L10n.string("Scan Options"), systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .popover(isPresented: $showingScanOptions, arrowEdge: .bottom) {
            scanOptionsPopover
        }
        .help(L10n.string("Choose what the next scan includes"))
        .accessibilityLabel(L10n.string("Scan options"))
        .accessibilityValue(scanOptions.summary)
    }

    /// The folder picker is a stable toolbar command: always present, always the
    /// same weight, and never the default action. With no content primary, the
    /// menu shortcut is the keyboard route so the toolbar cannot steal Return
    /// from an open popover.
    private var chooseFolderToolbarButton: some View {
        Button {
            chooseFolder()
        } label: {
            Label(L10n.string("Choose a Folder…"), systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .disabled(viewModel.isScanning)
        .help(L10n.string("Pick any folder or volume to scan"))
        .accessibilityLabel(L10n.string("Choose a folder to scan"))
    }

    /// What a scan includes, as switches with the consequence of each spelled
    /// out. The summary at the bottom names the same choices, so the source
    /// screen and the popover cannot disagree.
    private var scanOptionsPopover: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.medium) {
            Text(L10n.string("Scan Options"))
                .font(DS.Typography.headline)

            ScanOptionToggle(
                title: L10n.string("Include hidden items"),
                detail: L10n.string("Names macOS hides, such as ~/Library, dotfiles, and caches."),
                isOn: optionBinding(\.includeHidden)
            )
            ScanOptionToggle(
                title: L10n.string("Stay on this volume"),
                detail: L10n.string("Do not follow folders that point to another disk or network share."),
                isOn: optionBinding(\.stayOnVolume)
            )
            ScanOptionToggle(
                title: L10n.string("Follow symbolic links"),
                detail: L10n.string("Count a link's target, skipping links that leave the scan."),
                isOn: optionBinding(\.followSymlinks)
            )

            Rectangle()
                .fill(DS.Color.rule)
                .frame(height: DS.Stroke.hairline)

            exclusionsEditor

            Rectangle()
                .fill(DS.Color.rule)
                .frame(height: DS.Stroke.hairline)

            HStack {
                Button(L10n.string("Reset to Defaults")) {
                    scanOptionsStore.reset()
                }
                .controlSize(.small)
                .disabled(scanOptions == .standard)
                Spacer()
                Text(L10n.string("Applies to every scan you start."))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
        }
        .padding(DS.Spacing.large)
        .frame(width: 380)
    }

    /// The paths the next scan leaves out. Listing them here is what makes the
    /// narrowed totals honest: the choice is visible before the scan starts, and
    /// Coverage repeats it afterward.
    private var exclusionsEditor: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.small) {
            HStack {
                Text(L10n.string("Excluded Paths"))
                    .font(DS.Typography.body)
                Spacer()
                Button(L10n.string("Add Path…")) {
                    addExclusions()
                }
                .controlSize(.small)
            }

            if scanOptions.excludedPaths.isEmpty {
                Text(L10n.string("Nothing excluded."))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(scanOptions.excludedPaths, id: \.self) { url in
                            HStack(spacing: DS.Spacing.small) {
                                Image(systemName: "nosign")
                                    .font(DS.Icon.detail)
                                    .foregroundStyle(DS.Color.secondaryText)
                                    .accessibilityHidden(true)
                                Text(PathFormat.abbreviated(url.path))
                                    .font(DS.Typography.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                IconActionButton(
                                    symbol: "xmark",
                                    help: L10n.format("Stop excluding %@", url.path),
                                    surface: .inline
                                ) {
                                    scanOptionsStore.removeExclusion(url)
                                }
                                .accessibilityLabel(L10n.format("Remove exclusion %@", url.path))
                            }
                            .padding(.vertical, DS.Spacing.xxSmall)
                        }
                    }
                }
                .frame(maxHeight: 104)
            }

            Text(L10n.string("Excluded items are left out of the totals and reported in Coverage. The scanned location always stays included."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Binds one field of the shared store, so this sheet edits the values the
    /// Settings window shows instead of a private copy of them.
    private func optionBinding(_ keyPath: WritableKeyPath<ScanOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { scanOptionsStore.options[keyPath: keyPath] },
            set: { scanOptionsStore.options[keyPath: keyPath] = $0 }
        )
    }

    /// A section's name set against a hairline that runs to the panel edge, so
    /// the home screen reads as a ruled index rather than as stacked groups.
    private func sectionHeader(_ title: String) -> some View {
        SectionLabel(title, rule: true)
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
                    Text(L10n.string("Drop a folder to scan it"))
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
        panel.prompt = L10n.string("Choose")
        panel.message = L10n.string("Choose a folder or volume to scan.")
        if panel.runModal() == .OK, let url = panel.url {
            startScan(url)
        }
    }

    private func addExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L10n.string("Exclude")
        panel.message = L10n.string("Choose files or folders every scan should leave out.")
        guard panel.runModal() == .OK else { return }
        scanOptionsStore.addExclusions(panel.urls)
    }

    private func startScan(_ url: URL) {
        RecentLocations.record(url)
        recentLocations = RecentLocations.load()
        viewModel.start(root: url, options: scanOptions)
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
                self.startScan(url)
            }
        }
        return true
    }
}

/// Aligns a preset slot's symbol with the optical middle of the name beside
/// it: between the x-height's middle and the cap height's, above the baseline.
private enum PresetNameMiddle: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat {
        context[VerticalAlignment.firstTextBaseline] - 4.5
    }
}

private extension VerticalAlignment {
    static let presetNameMiddle = VerticalAlignment(PresetNameMiddle.self)
}
