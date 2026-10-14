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
