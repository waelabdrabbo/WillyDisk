import SwiftUI
import DiskUI
import DiskLocalization

/// Hosts the phase-driven scan flow (source selection → results).
///
/// The shared `ScanViewModel` — backed by the real `FileScanEngine` — is owned
/// by `AppState` and injected here. The flow itself is `DiskUI`'s
/// `ScanFlowView`, which switches between `SourceSelectionView` and
/// `ResultsView` on the view model's phase.
///
/// The stored appearance preference is applied from here, at the root, because
/// holding it on one screen would drop the choice as soon as the flow moved to
/// the other. The app object is the carrier: every window, the app's own chrome,
/// the panels it presents itself, and the menu bar inherit one value from it, and
/// SwiftUI re-reads the color scheme when that value changes. A
/// `.preferredColorScheme` override on the window does not refresh the SwiftUI
/// color scheme on the way back to `system`, which leaves the window in the
/// system's appearance and its content in the previous one.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .system
    @AppStorage(AppLanguage.defaultsKey) private var language: AppLanguage = .system

    var body: some View {
        ScanFlowView(viewModel: appState.scanViewModel)
            // One ink for every control state: the app's signal, set once here so
            // no screen has to remember it.
            .tint(DS.Color.signal)
            // The interface language decides the reading direction of every
            // screen and sheet. A change is a new identity for the flow, so
            // every label that was built in the old language is rebuilt.
            .environment(\.layoutDirection, L10n.isRightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.locale, L10n.locale)
            .id(language)
            .onChange(of: appearance) { _, choice in appState.applyAppearance(choice) }
            .onChange(of: language) { _, choice in choice.apply() }
            .sheet(isPresented: $appState.isShowingHelp) {
                HelpView { appState.isShowingHelp = false }
                    .id(language)
            }
    }
}
