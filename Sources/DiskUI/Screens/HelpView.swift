import SwiftUI

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
                Text("WillyDisk Help")
                    .font(DS.Typography.title2)
                Text("Scans, results, coverage, and the Trash.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xxLarge)
    }

    private var footer: some View {
        HStack {
            Text("Scans run on this Mac; nothing is uploaded.")
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
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
    static let topics: [HelpTopic] = [
        HelpTopic(
            id: "scan",
            title: "Start a scan",
            symbol: "externaldrive",
            paragraphs: [
                "Choose a volume, a recent scan, or a preset on the Home screen, or use Choose a Folder… (⌘O) to scan anywhere else. Every route starts the same scan with the same options.",
                "Scan Options picks what the walk includes: hidden items, other volumes, symbolic links, and excluded paths. The caption beside Scan repeats the choice, and Rescan (⌘R) repeats it exactly.",
                "Cancel Scan (⌘.) stops the walk and keeps the totals gathered so far, marked as stopped early.",
            ]
        ),
        HelpTopic(
            id: "results",
            title: "Read the results",
            symbol: "chart.pie",
            paragraphs: [
                "The sunburst maps the folder you are in. Click a folder wedge to enter it; click a file wedge to select the file, and click the centre to go up one folder.",
                "Choose This Folder, Top Files, Top Folders, or Categories. Search (⌘F) filters the list on screen; Categories shows the same scan split by file category, and choosing a category there lists its largest files without leaving the mode. Show More pages through a long list.",
                "The ⓘ button opens Coverage: what the scan counted, what it skipped, and the volume's own figures side by side.",
            ]
        ),
        HelpTopic(
            id: "select",
            title: "Select and act",
            symbol: "cursorarrow.click",
            paragraphs: [
                "Click a row to select it, ⌘-click to add or remove one, and Shift-click to extend. The arrow keys move, Shift extends, Home and End jump.",
                "Space previews the selection with Quick Look, Return opens a folder or a file, and Escape clears the selection.",
                "Right-click a row, or use the detail pane, to reveal it in Finder or move it to the Trash. A move asks first and refuses the scan root, volume roots, your home folder, and protected system locations. The space returns when the Trash is emptied, not when the item is moved.",
            ]
        ),
        HelpTopic(
            id: "coverage",
            title: "What coverage leaves out",
            symbol: "info.circle",
            paragraphs: [
                "Hard links are not deduplicated: each link counts, and the extra is disclosed. Dataless files are counted at logical size, with local bytes reported separately.",
                "Skipped symbolic links, other volumes, special files, and the items your exclusions removed are listed. Nothing that was not read is given an estimated size.",
                "The startup disk is a volume group, so a scan of / is not reconciled against the disk's capacity.",
            ]
        ),
        HelpTopic(
            id: "exclusions",
            title: "Leave paths out",
            symbol: "eye.slash",
            paragraphs: [
                "Add Path… in Scan Options leaves paths out of the next scan. A nested exclusion is skipped without being entered; an exclusion at or above the scan root is ignored.",
                "Coverage reports how many items your exclusions skipped, so a narrower total is never a silent one.",
            ]
        ),
        HelpTopic(
            id: "export",
            title: "Export and privacy",
            symbol: "lock",
            paragraphs: [
                "File ▸ Export writes a JSON report with the accounting disclosures, or a CSV of the ranked items.",
                "Scans run on this Mac and nothing is uploaded. Nothing is deleted automatically; Move to Trash is the only removal, and it asks first.",
            ]
        ),
    ]
}
