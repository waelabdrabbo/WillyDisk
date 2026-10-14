import SwiftUI
import DiskUI

/// Hosts the phase-driven scan flow (source selection → results).
///
/// The shared `ScanViewModel` — backed by the real `FileScanEngine` — is owned
/// by `AppState` and injected here. The flow itself is `DiskUI`'s
/// `ScanFlowView`, which switches between `SourceSelectionView` and
/// `ResultsView` on the view model's phase.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScanFlowView(viewModel: appState.scanViewModel)
    }
}
