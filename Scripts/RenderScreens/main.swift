import SwiftUI
import AppKit
import DiskCore
import DiskUI

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
enum ScreenKind: String, CaseIterable {
    case results
    case home
}

struct Options {
    var out = URL(fileURLWithPath: ".build/renders")
    var size = CGSize(width: 1088, height: 816)
    var appearances: [ColorScheme] = [.light, .dark]
    var screens: [ScreenKind] = [.results]
    var fixture: URL?
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
                fail("--size expects WxH in points, e.g. 1088x816")
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
            case "both": options.screens = ScreenKind.allCases
            case let other: fail("--screen expects home, results or both, not \(other)")
            }
        case "--fixture":
            options.fixture = URL(fileURLWithPath: next("--fixture"))
        case "--window":
            options.rendersWindow = true
        case "--content":
            options.rendersWindow = false
        case "--help", "-h":
            print("""
            usage: render-screens --out DIR [--size WxH] [--appearance light|dark|both] [--screen home|results|both] [--fixture DIR] [--window|--content]

              --out        directory the PNGs are written to
              --size       render size in points (default 1088x816)
              --appearance which appearances to render (default both)
              --screen     which screens to render (default results)
              --fixture    scan this directory instead of the generated fixture
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

// MARK: - Rendering

@MainActor
func render(_ options: Options) {
    let fixture = options.fixture ?? options.out.appendingPathComponent("fixture")
    if options.fixture == nil {
        try? FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        makeFixture(at: fixture)
    }

    let viewModel = ScanViewModel(engine: FileScanEngine())
    viewModel.start(root: fixture)
    var spins = 0
    while viewModel.isScanning && spins < 2_400 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        spins += 1
    }
    guard !viewModel.isScanning else { fail("the fixture scan did not finish") }
    print("scanned \(fixture.path): \(viewModel.filesScanned) files, \(viewModel.displayedTotal) bytes")

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
                }
            }
            .environment(\.colorScheme, appearance)

            let url = options.out.appendingPathComponent(
                "\(kind.rawValue)-\(options.rendersWindow ? "window" : "content")-\(name)-\(Int(options.size.width))x\(Int(options.size.height)).png")
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

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
MainActor.assumeIsolated { render(parse(Array(CommandLine.arguments.dropFirst()))) }
