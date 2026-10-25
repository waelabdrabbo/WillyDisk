import SwiftUI
import AppKit
import DiskCore
import DiskUI
import DiskLocalization

/// Offscreen renderer for WillyDisk's screens.
///
/// It drives the real views with a real scan of a generated fixture tree and
/// writes PNGs, so a UI change can be reviewed from files on disk. It needs no
/// window and no Screen Recording permission, which is what makes it usable in a
/// locked session and inside an agent sandbox.
///
/// The fixture and the output sizes are fixed, so two runs are comparable and a
/// render can be committed as evidence.

// MARK: - Arguments

/// The screens this renderer can drive. Each is the real view over the same
/// finished scan, so a render is the screen the app shows, not a mock of it.
/// The states a screen can be rendered in.
///
/// `finished` is the settled screen. `scanning` captures the one the app shows
/// while a scan is still running, which no settled fixture reaches: point it at
/// a directory large enough that the scan is still in flight when the frame is
/// taken.
enum RenderState: String {
    case finished
    case scanning
    case stopped
}

enum ScreenKind: String, CaseIterable {
    case results
    case home
    case search
    case help
    case settings
    case categories
    case coverage
    case cleanup
    case duplicates
    case history
}

struct Options {
    var out = URL(fileURLWithPath: ".build/renders")
    var locale = "en"
    var size = CGSize(width: 1000, height: 720)
    var appearances: [ColorScheme] = [.light, .dark]
    var screens: [ScreenKind] = [.results]
    var fixture: URL?
    var state: RenderState = .finished
    var rendersWindow = true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-screens: \(message)\n".utf8))
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    func next(_ flag: String) -> String {
        index += 1
        guard index < arguments.count else { fail("\(flag) needs a value") }
        return arguments[index]
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--out":
            options.out = URL(fileURLWithPath: next("--out"))
        case "--size":
            let parts = next("--size").split(separator: "x")
            guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else {
                fail("--size expects WxH in points, e.g. 1000x720")
            }
            options.size = CGSize(width: w, height: h)
        case "--appearance":
            switch next("--appearance") {
            case "light": options.appearances = [.light]
            case "dark": options.appearances = [.dark]
            case "both": options.appearances = [.light, .dark]
            case let other: fail("--appearance expects light, dark or both, not \(other)")
            }
        case "--screen":
            switch next("--screen") {
            case "results": options.screens = [.results]
            case "home": options.screens = [.home]
            case "search": options.screens = [.search]
            case "help": options.screens = [.help]
            case "settings": options.screens = [.settings]
            case "categories": options.screens = [.categories]
            case "coverage": options.screens = [.coverage]
            case "cleanup": options.screens = [.cleanup]
            case "duplicates": options.screens = [.duplicates]
            case "history": options.screens = [.history]
            case "both": options.screens = [.results, .home]
            case let other: fail("--screen expects home, results, search, help, settings, categories, coverage, cleanup, duplicates, history or both, not \(other)")
            }
        case "--locale":
            let language = next("--locale")
            guard L10n.availableLanguages.contains(language) else {
                fail("--locale expects one of \(L10n.availableLanguages.joined(separator: ", ")), not \(language)")
            }
            options.locale = language
        case "--fixture":
            options.fixture = URL(fileURLWithPath: next("--fixture"))
        case "--state":
            switch next("--state") {
            case "finished": options.state = .finished
            case "scanning": options.state = .scanning
            case "stopped": options.state = .stopped
            case let other: fail("--state expects finished, scanning or stopped, not \(other)")
            }
        case "--window":
            options.rendersWindow = true
        case "--content":
            options.rendersWindow = false
        case "--help", "-h":
            print("""
            usage: render-screens --out DIR [--size WxH] [--appearance light|dark|both] [--screen home|results|search|help|settings|categories|coverage|cleanup|duplicates|history|both] [--fixture DIR] [--state finished|scanning] [--locale en|ar|en-XA] [--window|--content]

              --out        directory the PNGs are written to
              --size       render size in points (default 1000x720)
              --appearance which appearances to render (default both)
              --screen     which screens to render (default results); both is
                           home and results, search is the results screen with a
                           whole-scan search open, categories is the results
                           screen in Categories mode, coverage is the coverage
                           sheet, help and settings are the sheet and preferences
                           contents, cleanup and duplicates are the cleanup
                           sheet's two tabs (they use their own fixture), history
                           is the scan-history comparison
              --fixture    scan this directory instead of the generated fixture
              --state      finished (default) or scanning, which captures the
                           screen while the scan is still running
              --locale     interface language (default en); ar is the finished
                           right-to-left translation, en-XA the doubled-length
                           pseudolanguage
              --window     capture the whole window, toolbar included (default)
              --content    capture the screen alone, with no window around it
            """)
            exit(0)
        case let other:
            fail("unknown argument \(other)")
        }
        index += 1
    }
    return options
}

// MARK: - Fixture

/// Writes a small tree with fixed names and sizes, so the chart, the list and the
/// footer carry the same data on every run. Existing files are left alone.
func makeFixture(at root: URL) {
    let files: [(String, Int)] = [
        ("Photos/2024/holiday.jpg", 520_000),
        ("Photos/2024/family.jpg", 310_000),
        ("Photos/screenshot.png", 90_000),
        ("Projects/WillyDisk/main.swift", 40_000),
        ("Projects/WillyDisk/Package.swift", 3_000),
        ("Projects/notes.md", 12_000),
        ("Archives/old-backup.zip", 640_000),
        ("Archives/installer.dmg", 820_000),
        ("Documents/report.pdf", 230_000),
        ("Documents/invoice.pdf", 45_000),
        ("readme.txt", 900),
    ]
    let manager = FileManager.default
    for (path, size) in files {
        let url = root.appendingPathComponent(path)
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: Data(count: size))
        }
    }
}

/// Writes a tree the cleanup analysis has something to say about.
///
/// The files are sparse — `truncate` sets a logical size without writing the
/// bytes — so the render costs nothing but st_size. Dates are set relative to the
/// moment of the render so the default policy sees a large old file, an old
/// download, and a cache folder.
func makeCleanupFixture(at root: URL) {
    let manager = FileManager.default
    let now = Date()

    func sparse(_ path: String, size: Int64, ageDays: Double, firstByte: UInt8? = nil) {
        let url = root.appendingPathComponent(path)
        try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        manager.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            if let firstByte {
                try? handle.write(contentsOf: Data([firstByte]))
            }
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        try? manager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-ageDays * 86_400)],
            ofItemAtPath: url.path
        )
    }

    sparse("Documents/old-archive.dmg", size: 800_000_000, ageDays: 800)
    sparse("Downloads/holiday.mov", size: 620_000_000, ageDays: 200)
    sparse("Downloads/recent.zip", size: 40_000_000, ageDays: 2)
    sparse("Library/Caches/com.example.app/blob.bin", size: 900_000_000, ageDays: 800)
    sparse("Documents/notes.txt", size: 2_000, ageDays: 2)
    // Two identical files and one same-size different file, so the duplicate
    // section has a confirmed pair and a size match the check rejects.
    sparse("Documents/copy-a.bin", size: 12_000_000, ageDays: 10)
    sparse("Documents/copy-b.bin", size: 12_000_000, ageDays: 10)
    sparse("Documents/copy-c.bin", size: 12_000_000, ageDays: 10, firstByte: 0xFF)
}

// MARK: - History fixture

/// The two older runs of a location, derived from the scan the renderer just
/// made so the comparison shows this fixture's own numbers. The newer run is the
/// one the view model records as the scan settles; these are scaled, one file is
/// left out of them, and one was larger, so the sheet shows a grown folder, a new
/// file, and a shrunk file.
func makeOlderHistoryRecords(summary: ScanSummary) -> [ScanRecord] {
    let options = RecordedOptions(
        followSymlinks: false,
        stayOnVolume: true,
        includeHidden: true,
        excludedPaths: []
    )
    let newest = ScanRecord(summary: summary, options: options)
    let installer = summary.root.appendingPathComponent("Archives/installer.dmg").standardizedFileURL.path

    func scaled(_ entries: [RecordedEntry], by factor: Double, dropping dropped: Set<String>) -> [RecordedEntry] {
        entries.filter { !dropped.contains($0.path) }.map { entry in
            RecordedEntry(
                path: entry.path,
                name: entry.name,
                isDirectory: entry.isDirectory,
                logicalSize: Int64((Double(entry.logicalSize) * factor).rounded()),
                allocatedSize: Int64((Double(entry.allocatedSize) * factor).rounded()),
                modifiedAt: entry.modifiedAt
            )
        }
    }

    /// One entry that was larger in the older run, so the comparison has a
    /// shrunk row as well as grown and new ones.
    func larger(_ entries: [RecordedEntry], path: String, by factor: Double) -> [RecordedEntry] {
        entries.map { entry in
            guard entry.path == path else { return entry }
            return RecordedEntry(
                path: entry.path,
                name: entry.name,
                isDirectory: entry.isDirectory,
                logicalSize: Int64((Double(entry.logicalSize) * factor).rounded()),
                allocatedSize: Int64((Double(entry.allocatedSize) * factor).rounded()),
                modifiedAt: entry.modifiedAt
            )
        }
    }

    func older(daysAgo: Double, factor: Double, droppingFiles: Set<String>, droppingFolders: Set<String>) -> ScanRecord {
        let finished = newest.finishedAt.addingTimeInterval(-daysAgo * 86_400)
        return ScanRecord(
            rootPath: newest.rootPath,
            startedAt: finished.addingTimeInterval(-newest.duration),
            finishedAt: finished,
            totalLogicalSize: Int64((Double(newest.totalLogicalSize) * factor).rounded()),
            totalAllocatedSize: Int64((Double(newest.totalAllocatedSize) * factor).rounded()),
            fileCount: newest.fileCount,
            directoryCount: newest.directoryCount,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            categorySizes: newest.categorySizes.mapValues { Int64((Double($0) * factor).rounded()) },
            largestFiles: scaled(newest.largestFiles, by: factor, dropping: droppingFiles),
            largestDirectories: scaled(newest.largestDirectories, by: factor, dropping: droppingFolders),
            entryCapacity: newest.entryCapacity,
            accounting: newest.accounting,
            options: options,
            volume: nil
        )
    }

    var sixDaysAgo = older(daysAgo: 6, factor: 0.78, droppingFiles: [installer], droppingFolders: [])
    let screenshot = summary.root.appendingPathComponent("Photos/screenshot.png").standardizedFileURL.path
    sixDaysAgo = ScanRecord(
        rootPath: sixDaysAgo.rootPath,
        startedAt: sixDaysAgo.startedAt,
        finishedAt: sixDaysAgo.finishedAt,
        totalLogicalSize: sixDaysAgo.totalLogicalSize,
        totalAllocatedSize: sixDaysAgo.totalAllocatedSize,
        fileCount: sixDaysAgo.fileCount,
        directoryCount: sixDaysAgo.directoryCount,
        inaccessibleCount: sixDaysAgo.inaccessibleCount,
        errorCount: sixDaysAgo.errorCount,
        permissionDeniedCount: sixDaysAgo.permissionDeniedCount,
        surfacedIssueCount: sixDaysAgo.surfacedIssueCount,
        categorySizes: sixDaysAgo.categorySizes,
        largestFiles: larger(sixDaysAgo.largestFiles, path: screenshot, by: 6.5),
        largestDirectories: sixDaysAgo.largestDirectories,
        entryCapacity: sixDaysAgo.entryCapacity,
        accounting: sixDaysAgo.accounting,
        options: sixDaysAgo.options,
        volume: sixDaysAgo.volume
    )

    return [
        sixDaysAgo,
        older(daysAgo: 20, factor: 0.64, droppingFiles: [], droppingFolders: [])
    ]
}

// MARK: - Rendering

/// The scanned root's own node, the way `ResultsView` finds it.
func rootNode(in summary: ScanSummary) -> ScanNode? {
    let path = summary.root.standardizedFileURL.path
    return summary.largestDirectories.first {
        $0.url.standardizedFileURL.path == path
    }
}

/// A store with non-default toggles and two exclusions, so the preferences
/// render shows the list and both switch states instead of only the empty state.
/// It uses the renderer's own defaults suite; the app's settings are untouched.
@MainActor
func makeSettingsStore(fixture: URL) -> ScanOptionsStore {
    let defaults = UserDefaults(suiteName: "WillyDiskRenderSettings") ?? .standard
    let store = ScanOptionsStore(defaults: defaults)
    store.options = ScanOptions(
        followSymlinks: true,
        stayOnVolume: true,
        includeHidden: false,
        excludedPaths: [
            fixture.appendingPathComponent("Archives"),
            fixture.appendingPathComponent("Documents/invoice.pdf")
        ]
    )
    return store
}

/// Pins the process to one interface language before a view or a formatter
/// reads it. `L10n` resolves the `.lproj` itself; the defaults make the system
/// formatters — dates, sizes, numbers — follow the same language.
func applyLocale(_ locale: String) {
    UserDefaults.standard.set([locale], forKey: "AppleLanguages")
    UserDefaults.standard.set(locale, forKey: "AppleLocale")
    L10n.overrideLanguage(locale)
    // The Settings render shows the language picker; seed its preference so the
    // rendered language is the one selected, in this throwaway defaults domain.
    if let choice = AppLanguage.allCases.first(where: { $0.catalogLanguage == locale }) {
        UserDefaults.standard.set(choice.rawValue, forKey: AppLanguage.defaultsKey)
    } else {
        UserDefaults.standard.set(AppLanguage.system.rawValue, forKey: AppLanguage.defaultsKey)
    }
}

@MainActor
func render(_ options: Options) {
    // Help and Settings are static content: they need no scan, so those renders
    // are quick and cannot fail on the fixture.
    let needsScan = options.screens.contains { $0 != .help && $0 != .settings }
    let needsFixture = options.screens.contains { $0 != .help }
    // The cleanup sheet needs candidates the standard fixture does not have, so
    // it renders from its own tree; the other screens keep the shared fixture.
    let isCleanupRender = options.screens.contains(.cleanup) || options.screens.contains(.duplicates)
    let fixtureName = isCleanupRender ? "Sample Disk" : "fixture"
    let fixture = options.fixture ?? options.out.appendingPathComponent(fixtureName)
    if needsFixture, options.fixture == nil {
        try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        if isCleanupRender {
            makeCleanupFixture(at: fixture)
        } else {
            makeFixture(at: fixture)
        }
    }

    let settingsStore = options.screens.contains(.settings) ? makeSettingsStore(fixture: fixture) : nil
    // History lives in the render directory, never in the user's own store. The
    // view model records the finished scan exactly as the app does; the history
    // screen adds two older runs so the comparison has a pair to show.
    let historyStore = ScanHistoryStore(directory: options.out.appendingPathComponent("history"))
    try? historyStore.clear()
    let history = ScanHistory(store: historyStore)
    let viewModel = ScanViewModel(engine: FileScanEngine(), history: history)
    if needsScan {
        viewModel.start(root: fixture)
    }

    // A scanning render is a picture of work in flight. The frame is taken as
    // soon as the engine has counted something, and it is taken with the scan
    // still running: waiting a fixed span and hoping the work outlasts it renders
    // an idle screen whenever the fixture is quick.
    //
    // A stopped render cancels that scan and waits for the engine to settle it,
    // which is the only way to reach the screen a stopped scan leaves behind: a
    // fixture that runs to completion never does.
    if needsScan {
        if options.state == .finished {
            var spins = 0
            while viewModel.isScanning && spins < 1_200 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                spins += 1
            }
            guard !viewModel.isScanning else { fail("the fixture scan did not finish") }
        } else {
            let deadline = Date().addingTimeInterval(30)
            while viewModel.isScanning, viewModel.filesScanned == 0, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard viewModel.isScanning, viewModel.filesScanned > 0 else {
                fail("the scan did not report progress while it was running")
            }
            if options.state == .stopped {
                viewModel.cancel()
                let settle = Date().addingTimeInterval(30)
                while viewModel.isScanning, Date() < settle {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                guard !viewModel.isScanning else { fail("the stopped scan did not settle") }
                // The point of this state is the screen a stopped scan leaves, so
                // the capture is only valid if the engine really recorded one:
                // stopped short of the whole root, with something gathered to show.
                guard viewModel.stoppedEarly, viewModel.displayedTotal > 0 else {
                    fail("the cancel did not leave a stopped-early scan with results")
                }
            }
        }
        print("\(options.state.rawValue) \(fixture.path): \(viewModel.filesScanned) files, \(viewModel.displayedTotal) bytes")
    }

    var historyModel: ScanHistory?
    if options.screens.contains(.history) {
        guard let summary = viewModel.summary else {
            fail("the scan produced no summary for the history screen")
        }
        for record in makeOlderHistoryRecords(summary: summary) {
            _ = try? historyStore.save(record)
        }
        // The finished run is recorded by the view model as it settles; the
        // render waits for that write so the sheet lists the scan it came from.
        let deadline = Date().addingTimeInterval(10)
        while historyStore.load().records.count < 3, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard historyStore.load().records.count >= 3 else {
            fail("the finished scan was not recorded in the history")
        }
        historyModel = history
    }

    if options.screens.contains(.categories), viewModel.summary == nil {
        fail("the scan produced no summary for the categories screen")
    }
    if options.screens.contains(.cleanup) {
        guard let summary = viewModel.summary, rootNode(in: summary) != nil else {
            fail("the scan produced no root node for the cleanup screen")
        }
    }

    try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)

    for appearance in options.appearances {
        let name = appearance == .dark ? "dark" : "light"
        for kind in options.screens {
            // The window's own background sits behind the screen, exactly as it
            // does in the app, so a render is not composited against whatever the
            // reader opens it with.
            let screen = ZStack {
                DS.Color.windowBackground
                switch kind {
                case .results: ResultsView(viewModel: viewModel)
                case .home: SourceSelectionView(viewModel: viewModel)
                case .help: HelpView()
                case .settings:
                    if let settingsStore {
                        SettingsView(optionsStore: settingsStore)
                    }
                case .categories:
                    ResultsView(viewModel: viewModel, initialMode: .categories)
                case .coverage:
                    if let summary = viewModel.summary {
                        CoverageSheet(
                            summary: summary,
                            isLive: false,
                            volume: VolumeFacts(
                                mountURL: fixture,
                                name: "Sample Disk",
                                totalCapacity: 4_000_000_000_000,
                                availableCapacity: 1_200_000_000_000,
                                availableForImportantUsage: 1_350_000_000_000,
                                isReadOnly: false
                            ),
                            snapshots: LocalSnapshots(
                                volumeName: "Sample Disk",
                                names: [
                                    "com.apple.TimeMachine.2026-10-12-101500.local",
                                    "com.apple.TimeMachine.2026-10-13-101500.local",
                                    "com.apple.TimeMachine.2026-10-14-101500.local",
                                    "com.apple.TimeMachine.2026-10-15-101500.local",
                                ]
                            )
                        )
                    }
                case .search:
                    // A query every folder of the fixture has something for, so
                    // the render shows the match list, their containing paths, and
                    // the chart pane's search state.
                    ResultsView(viewModel: viewModel, initialSearch: "p")
                case .history:
                    if let historyModel, let summary = viewModel.summary {
                        HistorySheet(
                            history: historyModel,
                            root: summary.root,
                            rootName: LocationName.of(summary.root)
                        )
                    }
                case .cleanup, .duplicates:
                    if let summary = viewModel.summary,
                       let root = rootNode(in: summary),
                       let preview = CleanupAnalysis.analyze(root: root, now: Date()) {
                        CleanupSheet(
                            root: root,
                            rootName: root.name,
                            scannedAt: summary.finishedAt,
                            previewReport: preview,
                            previewDuplicateReport: DuplicateHasher.check(groups: preview.duplicateGroups),
                            initialTab: kind == .duplicates ? .duplicates : .old,
                            onMove: { _ in },
                            onClose: {}
                        )
                    }
                }
            }
            .environment(\.colorScheme, appearance)
            .environment(\.layoutDirection, L10n.isRightToLeft ? .rightToLeft : .leftToRight)

            let url = options.out.appendingPathComponent(
                "\(kind.rawValue)-\(options.rendersWindow ? "window" : "content")-\(name)-\(options.locale)-\(Int(options.size.width))x\(Int(options.size.height)).png")
            let image = options.rendersWindow
                ? renderWindow(screen, size: options.size, appearance: appearance)
                : renderContent(screen, size: options.size)
            guard let png = image?.representation(using: .png, properties: [:]) else {
                fail("could not encode \(url.lastPathComponent)")
            }
            do {
                try png.write(to: url)
            } catch {
                fail("could not write \(url.path): \(error.localizedDescription)")
            }
            print("wrote \(url.path)")
        }
    }
}

/// Renders the screen inside a real window and captures the frame view, so the
/// toolbar and titlebar are in the picture.
///
/// The screen's top edge runs to the top of the window, behind the toolbar, and
/// the window chrome is drawn over it: an on-screen boundary that this catches
/// and a content-only render does not.
@MainActor
func renderWindow<V: View>(_ screen: V, size: CGSize, appearance: ColorScheme) -> NSBitmapImageRep? {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
    window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    let toolbar = NSToolbar(identifier: "render-screens")
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    window.contentView = NSHostingView(rootView: screen)

    for _ in 0..<12 {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard let frameView = window.contentView?.superview,
          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    return rep
}

/// Renders the screen on its own, with no window around it.
@MainActor
func renderContent<V: View>(_ screen: V, size: CGSize) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: screen)
    host.frame = NSRect(origin: .zero, size: size)
    // Preferences, and the state they feed, settle over a few passes.
    for _ in 0..<12 {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
applyLocale(options.locale)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
MainActor.assumeIsolated { render(options) }
