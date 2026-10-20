import SwiftUI
import DiskUI

@main
struct WillyDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("WillyDisk", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 620)
        }
        // Sized for the source screen's 720 pt column: one window width that
        // still gives the results chart and its inspector room side by side.
        .defaultSize(width: 1000, height: 720)
        .windowResizability(.contentMinSize)
        // Put screen actions on the same titlebar row as the traffic lights.
        .windowToolbarStyle(.unified)
        .commands {
            WillyDiskCommands(appState: appState)
        }

        Settings {
            AppearanceSettingsView()
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
    @FocusedValue(\.scanCommands) private var scanCommands
    @FocusedValue(\.resultsCommands) private var resultsCommands

    var body: some Commands {
        // Single-window utility: no "New Window" command.
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Button("Choose Folder…") {
                appState.chooseSource()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("Scan") {
            Button("Rescan") {
                resultsCommands?.rescan()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!(resultsCommands?.canRescan ?? false))

            Button("Cancel Scan") {
                scanCommands?.cancel()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!(scanCommands?.canCancel ?? false))

            Divider()

            Button("Coverage…") {
                resultsCommands?.showCoverage()
            }
            .disabled(!(resultsCommands?.canShowCoverage ?? false))
        }

        CommandGroup(after: .pasteboard) {
            Button("Find") {
                resultsCommands?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(resultsCommands == nil)
        }

        CommandGroup(after: .saveItem) {
            Menu("Export") {
                Button("Export as JSON…") {
                    resultsCommands?.exportJSON()
                }
                Button("Export as CSV…") {
                    resultsCommands?.exportCSV()
                }
            }
            .disabled(!(resultsCommands?.canExport ?? false))
        }
    }
}
