import SwiftUI
import DiskCore
import DiskUI
import DiskUpdate
import DiskLocalization

/// App-level state, injected into the window via `environmentObject`.
///
/// Owns the single shared `ScanViewModel` — wired to the real `FileScanEngine`
/// from `DiskCore` — so every screen (A → B → C) reads the same scan state and
/// no screen ever fabricates progress. Also exposes the folder-chooser action
/// used by the "Choose a Folder…" menu command.
@MainActor
final class AppState: ObservableObject {
    /// The one scan-options store the whole app shares, including the Settings
    /// window and the source screen's Scan Options sheet.
    let scanOptions = ScanOptionsStore.shared

    /// The one view model the whole app shares.
    let scanViewModel: ScanViewModel

    /// The app's moves, so one can be put back while the Trash still holds it.
    let reclaimLog = ReclaimLog()

    /// The check, download, and verification state behind the update sheet.
    let updates: UpdateController

    /// Whether the Help sheet is up. The main window hosts it, so Help is
    /// reachable from either screen and never opens a second window.
    @Published var isShowingHelp = false

    /// Whether the update sheet is up. Like Help, it is a sheet on the one window.
    @Published var isShowingUpdateSheet = false

    init() {
        let build = InstalledBuild.current()
        updates = UpdateController(
            feed: GitHubReleaseFeed(
                userAgent: "WillyDisk/\(build?.marketingVersion ?? "dev")"
            ),
            downloader: URLSessionUpdateDownloader(),
            verifier: build.map { AppUpdateVerifier(build: $0) },
            installer: UpdateInstaller(),
            preferences: .shared,
            build: build
        )

        scanViewModel = ScanViewModel(
            engine: FileScanEngine(),
            optionsStore: scanOptions,
            history: ScanHistory(),
            watchPreferences: .shared,
            watcher: ScanTreeWatcher(),
            reclaimLog: reclaimLog
        )

        // The log is a small file; reading it at launch means the Moved tab is
        // ready the first time it is opened rather than filling in later.
        Task { await reclaimLog.reload() }

        // The stored appearance is in place before the first window exists, so a
        // choice held over from the last launch is never painted over by the
        // system's appearance first.
        applyAppearance(.stored)

        // QA / automation hook: when `WILLYDISK_AUTOSCAN` names a path, begin a
        // scan immediately on launch so screenshots and smoke tests can reach
        // the results screen without driving the UI. No effect in normal use.
        if let path = ProcessInfo.processInfo.environment["WILLYDISK_AUTOSCAN"], !path.isEmpty {
            scanViewModel.start(root: URL(fileURLWithPath: path), options: scanOptions.options)
        }

        // A helper that ran while the app was closed leaves one result. A
        // failure is shown before anything else; a success has already cleaned
        // the staging archive, and the app is the new version. The read and any
        // cleanup are off the main actor.
        Task {
            let hadInstallFailure = await updates.consumeInstallResult()
            if hadInstallFailure {
                isShowingUpdateSheet = true
                return
            }
            // One check a day, after the window and any launch scan have settled.
            // `WILLYDISK_NO_UPDATE_CHECK` keeps QA and screen review offline.
            if ProcessInfo.processInfo.environment["WILLYDISK_NO_UPDATE_CHECK"] != "1" {
                await checkForUpdatesOnLaunch()
            }
        }
    }

    /// Opens the sheet immediately, then asks for the latest release. The sheet
    /// shows the check in progress and its answer, including a failure.
    func presentUpdateCheck() {
        isShowingUpdateSheet = true
        Task { await updates.check(manual: true) }
    }

    private func checkForUpdatesOnLaunch() async {
        try? await Task.sleep(for: .seconds(8))
        guard !Task.isCancelled else { return }
        await updates.checkIfDue()
        if case .available = updates.state {
            isShowingUpdateSheet = true
        }
    }

    /// Presents a standard folder chooser and starts a scan on the selection.
    func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("Scan")
        panel.message = L10n.string("Choose a folder or volume to scan.")

        if panel.runModal() == .OK, let url = panel.url {
            scanViewModel.start(root: url, options: scanOptions.options)
        }
    }

    /// Pins the app to the appearance the user chose.
    ///
    /// The app object carries the choice, so every window — the app's own, the
    /// folder chooser and save panels it presents, and the menu bar — resolves
    /// against it.
    func applyAppearance(_ appearance: AppAppearance) {
        AppAppearance.apply(appearance)
    }
}
