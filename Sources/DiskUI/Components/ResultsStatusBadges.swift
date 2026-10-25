import SwiftUI
import DiskLocalization

/// The results could not be kept current — the watch is off, the scan could not
/// become a live tree, or an item was moved to the Trash. The message states the
/// fact; the action is always the same one the toolbar offers.
struct StaleResultsBadge: View {
    let message: String
    let onRescan: () -> Void

    var body: some View {
        InlineActionButton(
            message,
            systemImage: "clock.arrow.circlepath",
            tone: .warning,
            action: onRescan
        )
        .help(L10n.string("The folder changed after this scan. Rescan to see the current numbers."))
    }
}
