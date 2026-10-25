import SwiftUI
import DiskCLI
import DiskUI
import DiskLocalization

/// The process entry point, which is either a command-line scan or the app.
///
/// The choice is made before SwiftUI is touched: `WillyDisk scan …` runs the
/// same engine the app uses and never creates an `NSApplication`, a window, or a
/// Dock icon. Any other invocation — including a bare launch from the Finder —
/// starts the app exactly as before.
@main
enum WillyDiskEntry {
    static func main() {
        if ScanCLI.handles(CommandLine.arguments) {
            exit(ScanCLI.run(arguments: CommandLine.arguments))
        }
        // Applied before SwiftUI builds a menu or a window, so the stored
        // language is in place from the first frame. The command line above
        // keeps following the system language.
        AppLanguage.applyStored()
        WillyDiskApp.main()
    }
}

struct WillyDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window(L10n.string("WillyDisk"), id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 620)
        }
        // Sized for the source screen's 720 pt column: one window width that
        // still gives the results explorer column and its chart room side by side.
        .defaultSize(width: 1000, height: 720)
        .windowResizability(.contentMinSize)
        // Put screen actions on the same titlebar row as the traffic lights.
        .windowToolbarStyle(.unified)
        .commands {
            WillyDiskCommands(appState: appState)
        }

        Settings {
            SettingsView()
        }
    }
}


/// The menu-bar commands for the single window.
///
/// Results actions arrive as focused values so the menu calls exactly the
/// closures the toolbar uses. Choosing a folder and cancelling belong to the
/// app and the shared view model, so they work on either screen.
private struct WillyDiskCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system
    @FocusedValue(\.scanCommands) private var scanCommands
    @FocusedValue(\.resultsCommands) private var resultsCommands

    var body: some Commands {
        // Reading the preference makes the command titles follow a language
        // chosen while the app is running.
        let _ = language
        // Single-window utility: no "New Window" command. The About panel keeps
        // the system layout; everything it names comes from the bundle, whose
        // plist is stamped from the repository's VERSION file.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appInfo) {
            Button(L10n.string("About WillyDisk")) {
                AboutPanel.present()
            }
        }

        CommandGroup(after: .newItem) {
            Button(L10n.string("Choose a Folder…")) {
                appState.chooseSource()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu(L10n.string("Scan")) {
            Button(L10n.string("Rescan")) {
                resultsCommands?.rescan()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(resultsCommands?.canRescan ?? false))

            Button(L10n.string("Cancel Scan")) {
                scanCommands?.cancel()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!(scanCommands?.canCancel ?? false))

            Divider()

            Button(L10n.string("Coverage…")) {
                resultsCommands?.showCoverage()
            }
            .disabled(!(resultsCommands?.canShowCoverage ?? false))

            Button(L10n.string("Cleanup…")) {
                resultsCommands?.showCleanup()
            }
            .disabled(!(resultsCommands?.canShowCleanup ?? false))

            Button(L10n.string("History…")) {
                resultsCommands?.showHistory()
            }
            .disabled(!(resultsCommands?.canShowHistory ?? false))
        }

        CommandGroup(after: .pasteboard) {
            Button(L10n.string("Find")) {
                resultsCommands?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(resultsCommands == nil)
        }

        CommandGroup(after: .saveItem) {
            Menu(L10n.string("Export")) {
                Button(L10n.string("Export as JSON…")) {
                    resultsCommands?.exportJSON()
                }
                .disabled(!(resultsCommands?.canExport ?? false))
                Button(L10n.string("Export as CSV…")) {
                    resultsCommands?.exportCSV()
                }
                .disabled(!(resultsCommands?.canExport ?? false))
                Divider()
                Button(L10n.string("Export Diagnostics…")) {
                    resultsCommands?.exportDiagnostics()
                }
                .disabled(!(resultsCommands?.canExportDiagnostics ?? false))
            }
        }

        // Help lives in the main window as a sheet, so it works from either
        // screen and the app keeps one window.
        CommandGroup(replacing: .help) {
            Button(L10n.string("WillyDisk Help")) {
                appState.isShowingHelp = true
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
