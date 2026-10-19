import SwiftUI
import DiskCore

/// Routes the app's two screens.
///
/// The screen shown is the view model's `route`, not its scan `phase`, so the
/// source-selection screen can be shown while a scan keeps running in the
/// background: starting a scan opens the results screen, its Back action returns
/// to source selection without touching the scan, and View opens the running (or
/// settled) results again. There is no separate scanning screen.
///
/// This is the recommended integration point for the app shell: create one
/// `ScanViewModel` (with the real `ScanEngine`) and host this view.
@MainActor
public struct ScanFlowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: ScanViewModel

    public init(viewModel: ScanViewModel = ScanViewModel()) {
        _viewModel = State(initialValue: viewModel)
    }

    public init(engine: any ScanEngine) {
        _viewModel = State(initialValue: ScanViewModel(engine: engine))
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.blockedStartNotice {
                blockedStartBanner(notice)
            }
            screen
        }
        .animation(reduceMotion ? nil : .snappy, value: viewModel.route)
        .animation(reduceMotion ? nil : .snappy, value: viewModel.blockedStartNotice)
        .focusedSceneValue(\.scanCommands, ScanCommands(
            canCancel: viewModel.isScanning,
            cancel: { viewModel.cancel() }
        ))
    }

    @ViewBuilder
    private var screen: some View {
        switch viewModel.route {
        case .home:
            SourceSelectionView(viewModel: viewModel)
        case .results:
            if case .failed(let message) = viewModel.phase {
                failedView(message)
            } else {
                ResultsView(viewModel: viewModel)
            }
        }
    }

    /// States why a start request was refused.
    ///
    /// The engine has one scan slot, so a second scan is never started while one
    /// runs. The source-selection screen disables its start actions for the same
    /// reason; this makes the refusal visible on the paths that go around them
    /// (the folder-chooser command), so it is never silent.
    private func blockedStartBanner(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DS.Color.secondaryText)
                .accessibilityHidden(true)
            Text(message)
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.primaryText)
            Spacer(minLength: DS.Spacing.medium)
            Button("Dismiss") {
                viewModel.dismissBlockedStartNotice()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityHint("Hides this message")
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.controlBackground)
        .accessibilityElement(children: .contain)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(DS.Icon.large)
                .foregroundStyle(DS.Color.warning)
            Text("Scanning Unavailable")
                .font(DS.Typography.title)
            Text(message)
                .font(DS.Typography.body)
                .foregroundStyle(DS.Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Start Over") {
                viewModel.reset()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.xxLarge)
    }
}
