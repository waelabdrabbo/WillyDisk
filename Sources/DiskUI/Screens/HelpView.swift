import SwiftUI
import DiskLocalization

/// The app's quick reference: what each control does, and what the numbers mean.
///
/// The content is deliberate about what the engine guarantees. A help screen is
/// easy to fill with claims the app does not keep — deduplicated totals, a
/// recycled Trash, a reconciled disk figure — so every statement here is one
/// `docs/ROADMAP.md` and the coverage sheet already make.
@MainActor
public struct HelpView: View {
    private let onClose: () -> Void

    public init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.section) {
                    ForEach(Self.topics) { topic in
                        section(topic)
                    }
                }
                .padding(DS.Spacing.xxLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .background(DS.Color.windowBackground)
        // The app's one ink, so the Done button matches the window that hosts
        // the sheet rather than falling back to the system accent.
        .tint(DS.Color.signal)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            WillyDiskMark(size: 30)
            VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                Text(L10n.string("WillyDisk Help"))
                    .font(DS.Typography.title2)
                Text(L10n.string("Scans, results, history, cleanup, coverage, and the Trash."))
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xxLarge)
    }

    private var footer: some View {
        HStack {
            Text(L10n.string("Scans run on this Mac; nothing is uploaded."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            Button(action: onClose) {
                Text(L10n.string("Done"))
                    .frame(minWidth: DS.Size.actionMinWidth)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DS.Spacing.xxLarge)
        .padding(.vertical, DS.Spacing.large)
    }

    private func section(_ topic: HelpTopic) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: topic.symbol)
                .font(DS.Typography.headline)
                .foregroundStyle(DS.Color.accent)
                .frame(width: DS.Spacing.xLarge + DS.Spacing.small, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(topic.title)
                    .font(DS.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                ForEach(topic.paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One titled block of the help text.
private struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let paragraphs: [String]
}

private extension HelpView {
    static var topics: [HelpTopic] { [
        HelpTopic(
            id: "scan",
            title: L10n.string("Start a scan"),
            symbol: "externaldrive",
            paragraphs: [
                L10n.string("Choose a volume, a recent scan, or a preset on the Home screen, or use Choose a Folder… (⌘O) to scan anywhere else. Every route starts the same scan with the same options."),
                L10n.string("Scan Options picks what the walk includes: hidden items, other volumes, symbolic links, and excluded paths. The caption beside Scan repeats the choice, and Rescan (⌘R) repeats it exactly."),
                L10n.string("Cancel Scan (⌘.) stops the walk and keeps the totals gathered so far, marked as stopped early."),
            ]
        ),
        HelpTopic(
            id: "results",
            title: L10n.string("Read the results"),
            symbol: "chart.pie",
            paragraphs: [
                L10n.string("The sunburst maps the folder you are in. Click a folder wedge to enter it; click a file wedge to select the file, and click the centre to go up one folder."),
                L10n.string("Choose This Folder, Top Files, Top Folders, or Categories. Search (⌘F) finds any name in the whole scan, not only the folder on screen; include a / to match a path instead. Each result says which folder holds it, right-click one for Show in Folder, and clearing the field returns to the list you were in. Categories shows the same scan split by file category, and choosing a category there lists its largest files without leaving the mode. Show More pages through a long list."),
                L10n.string("While these results are on screen, the scanned folder is watched: a change made in Finder updates the numbers without Rescan. A long scan is not repeated automatically — the results are marked stale and Rescan is offered."),
                L10n.string("The ⓘ button opens Coverage: what the scan counted, what it skipped, and the volume's own figures side by side."),
            ]
        ),
        HelpTopic(
            id: "select",
            title: L10n.string("Select and act"),
            symbol: "cursorarrow.click",
            paragraphs: [
                L10n.string("Click a row to select it, ⌘-click to add or remove one, and Shift-click to extend. The arrow keys move, Shift extends, Home and End jump."),
                L10n.string("Space previews the selection with Quick Look, Return opens a folder or a file, and Escape clears the selection."),
                L10n.string("Right-click a row, or use the detail pane, to reveal it in Finder or move it to the Trash. A move asks first and refuses the scan root, volume roots, your home folder, and protected system locations. The space returns when the Trash is emptied, not when the item is moved."),
            ]
        ),
        HelpTopic(
            id: "cleanup",
            title: L10n.string("Review cleanup candidates"),
            symbol: "sparkles",
            paragraphs: [
                L10n.string("Cleanup reads the finished scan for large and old files, cache folders, old downloads, and possible duplicates. Looking costs nothing; nothing moves until you confirm."),
                L10n.string("A possible duplicate is only a same-size candidate. Check Contents reads the files and compares SHA-256 digests; only matching contents are listed as identical, and cancelling the check confirms nothing."),
                L10n.string("Select copies, then Move to Trash…, and the usual confirmation checks every path. The space returns when the Trash is emptied, and moving one hard link frees nothing while another link remains."),
            ]
        ),
        HelpTopic(
            id: "coverage",
            title: L10n.string("What coverage leaves out"),
            symbol: "info.circle",
            paragraphs: [
                L10n.string("Hard links are not deduplicated: each link counts, and the extra is disclosed. Dataless files are counted at logical size, with local bytes reported separately."),
                L10n.string("Skipped symbolic links, other volumes, special files, and the items your exclusions removed are listed. Nothing that was not read is given an estimated size."),
                L10n.string("The startup disk is a volume group, so a scan of / is not reconciled against the disk's capacity."),
            ]
        ),
        HelpTopic(
            id: "exclusions",
            title: L10n.string("Leave paths out"),
            symbol: "eye.slash",
            paragraphs: [
                L10n.string("Add Path… in Scan Options leaves paths out of the next scan. A nested exclusion is skipped without being entered; an exclusion at or above the scan root is ignored."),
                L10n.string("Coverage reports how many items your exclusions skipped, so a narrower total is never a silent one."),
            ]
        ),
        HelpTopic(
            id: "history",
            title: L10n.string("Compare two scans"),
            symbol: "clock.arrow.circlepath",
            paragraphs: [
                L10n.string("History lists the runs recorded for the location you scanned. Choose two to see what grew, what shrank, and what appeared. Totals and categories are exact; folders and files are each run's largest 100, matched by path, and a New entry may simply have been below the earlier run's cut-off."),
                L10n.string("Only finished scans are recorded: a cancelled scan covers part of the folder, so it is not offered as a run to compare. Records stay on this Mac and hold paths and totals, never file contents. Clear History… removes them all."),
            ]
        ),
        HelpTopic(
            id: "export",
            title: L10n.string("Export and privacy"),
            symbol: "lock",
            paragraphs: [
                L10n.string("File ▸ Export writes a JSON report with the accounting disclosures, or a CSV of the ranked items."),
                L10n.string("Export Diagnostics writes scan settings, timing, issue counts, and the app version. It carries no file names, paths, or contents."),
                L10n.string("Scans run on this Mac and nothing is uploaded. Nothing is deleted automatically; Move to Trash is the only removal, and it asks first."),
            ]
        ),
    ] }
}