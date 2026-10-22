import SwiftUI

/// The results are older than the disk: the watcher saw a change, or an item
/// was moved to the Trash. The message names what changed when the screen knows;
/// the action is always the same one the toolbar offers.
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
        .help("The folder changed after this scan. Rescan to see the current numbers.")
    }
}

/// The one status slot beside the location: the results are being kept current,
/// or a change is being re-measured right now.
///
/// Both states occupy the same place in the title row, so a change never adds a
/// row or moves the header; the only difference is the word and the spinner.
struct WatchStatusChip: View {
    let isUpdating: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.xxSmall) {
            if isUpdating {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text("Updating…")
            } else {
                Text("●")
                    .foregroundStyle(DS.Color.success)
                Text("Watching")
            }
        }
        .font(DS.Typography.caption)
        .foregroundStyle(DS.Color.secondaryText)
        .lineLimit(1)
        .help(isUpdating
              ? "The folder changed; the numbers are being re-measured."
              : "Files changing in this folder update the results automatically.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUpdating ? "Updating results" : "Watching for changes")
    }
}
