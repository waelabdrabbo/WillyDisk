import SwiftUI
import DiskUI

@main
struct WillyDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 620)
                // The toolbar's own backing is what draws the line under it
                // against the panes, which run to the window's edges. Hiding it
                // leaves the screen's content to meet the titlebar directly.
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        // Put screen actions on the same titlebar row as the traffic lights.
        .windowToolbarStyle(.unified)
        .commands {
            // Single-window utility: no "New Window" command.
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .newItem) {
                Button("Choose Folder…") {
                    appState.chooseSource()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
