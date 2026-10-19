import SwiftUI
import AppKit
import DiskCore
import DiskUI

/// App-level state, injected into the window via `environmentObject`.
///
/// Owns the single shared `ScanViewModel` — wired to the real `FileScanEngine`
/// from `DiskCore` — so every screen (A → B → C) reads the same scan state and
/// no screen ever fabricates progress. Also exposes the folder-chooser action
/// used by the "Choose Folder…" menu command.
@MainActor
final class AppState: ObservableObject {
    /// The one view model the whole app shares.
    let scanViewModel: ScanViewModel

    init() {
        scanViewModel = ScanViewModel(engine: FileScanEngine())

        // The stored appearance is in place before the first window exists, so a
        // choice held over from the last launch is never painted over by the
        // system's appearance first.
        applyAppearance(.stored)

        // QA / automation hook: when `WILLYDISK_AUTOSCAN` names a path, begin a
        // scan immediately on launch so screenshots and smoke tests can reach
        // the results screen without driving the UI. No effect in normal use.
        if let path = ProcessInfo.processInfo.environment["WILLYDISK_AUTOSCAN"], !path.isEmpty {
            scanViewModel.start(root: URL(fileURLWithPath: path), options: ScanOptionsStore.load())
        }
    }

    /// Presents a standard folder chooser and starts a scan on the selection.
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to scan."

        if panel.runModal() == .OK, let url = panel.url {
            scanViewModel.start(root: url, options: ScanOptionsStore.load())
        }
    }

    /// Pins the app to the appearance the user chose.
    ///
    /// The app object carries the choice, so every window — the app's own, the
    /// folder chooser and save panels it presents, and the menu bar — resolves
    /// against it.
    func applyAppearance(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = appearance.nsAppearance
    }
}
