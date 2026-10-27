import SwiftUI
import AppKit
import DiskLocalization
import DiskUpdate

/// What the sheet can ask the controller to do. A value, so the renderer can draw
/// any state with no controller and the app can wire the same view to the real
/// one.
@MainActor
public struct UpdateSheetActions {
    public var retry: () -> Void
    public var download: () -> Void
    public var cancel: () -> Void
    public var skip: () -> Void
    public var openPage: (URL) -> Void
    public var reveal: (URL) -> Void
    public var close: () -> Void

    public init(
        retry: @escaping () -> Void,
        download: @escaping () -> Void,
        cancel: @escaping () -> Void,
        skip: @escaping () -> Void,
        openPage: @escaping (URL) -> Void,
        reveal: @escaping (URL) -> Void,
        close: @escaping () -> Void
    ) {
        self.retry = retry
        self.download = download
        self.cancel = cancel
        self.skip = skip
        self.openPage = openPage
        self.reveal = reveal
        self.close = close
    }

    public static let preview = UpdateSheetActions(
        retry: {},
        download: {},
        cancel: {},
        skip: {},
        openPage: { _ in },
        reveal: { _ in },
        close: {}
    )
}

/// The update flow's one window: check, offer, download, verify.
///
/// The verified download is where this phase stops. There is deliberately no
/// install button until the helper-based transaction exists; the sheet says the
/// update is downloaded and verified and offers the archive, and never claims it
/// has been installed.
@MainActor
public struct UpdateSheet: View {
    private let state: UpdateSheetState
    private let lastChecked: Date?
    private let actions: UpdateSheetActions

    public init(
        state: UpdateSheetState,
        lastChecked: Date?,
        actions: UpdateSheetActions
    ) {
        self.state = state
        self.lastChecked = lastChecked
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Spacing.xxLarge)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .background(DS.Color.windowBackground)
        .tint(DS.Color.signal)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: DS.Spacing.medium) {
            WillyDiskMark(size: 30)
            Text(L10n.string("Software Update"))
                .font(DS.Typography.title2)
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.xxLarge)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .checking:
            HStack(spacing: DS.Spacing.medium) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Checking for Updates…"))
                    .font(DS.Typography.callout)
            }

        case let .upToDate(current):
            status(
                symbol: "checkmark.circle",
                title: L10n.string("WillyDisk is up to date."),
                detail: L10n.format("You have WillyDisk %@.", current)
            )

        case let .newerThanLatest(current, latest):
            status(
                symbol: "arrow.up.circle",
                title: L10n.string("You're running a newer build than the latest release."),
                detail: L10n.format("You have WillyDisk %@.", current),
                extra: L10n.format("The latest release is WillyDisk %@.", latest)
            )

        case .unknownCurrentVersion:
            status(
                symbol: "questionmark.circle",
                title: L10n.string("This build has no release version to compare."),
                detail: nil
            )

        case let .available(offer):
            available(offer)

        case let .downloading(offer, progress):
            downloading(offer, progress)

        case .verifying:
            HStack(spacing: DS.Spacing.medium) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("Checking the download…"))
                    .font(DS.Typography.callout)
            }

        case let .ready(ready):
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                status(
                    symbol: "checkmark.circle",
                    title: L10n.string("Update Downloaded"),
                    detail: L10n.format("WillyDisk %@ was downloaded and its checksum matched.", ready.version)
                )
                Text(L10n.string("Installing the update is not part of this build yet. The checksum-matched download is in the update folder."))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .noBuildForThisMac(latest, _):
            status(
                symbol: "exclamationmark.triangle",
                title: L10n.string("This release has no build for this Mac."),
                detail: L10n.format("The latest release is WillyDisk %@.", latest)
            )

        case let .incompleteRelease(latest, _):
            status(
                symbol: "exclamationmark.triangle",
                title: L10n.string("This release is missing a file the updater needs."),
                detail: L10n.format("The latest release is WillyDisk %@.", latest)
            )

        case let .failed(failure, _):
            WarningNotice(
                L10n.string(failureMessage(failure)),
                title: L10n.string(failureTitle(failure))
            )
        }
    }

    private func status(
        symbol: String,
        title: String,
        detail: String?,
        extra: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.medium) {
            Image(systemName: symbol)
                .font(DS.Icon.medium)
                .foregroundStyle(DS.Color.signal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(title)
                    .font(DS.Typography.title2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let extra {
                    Text(extra)
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func available(_ offer: UpdateOffer) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            Text(L10n.format("WillyDisk %@ is available.", offer.version))
                .font(DS.Typography.title2)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.format("You have WillyDisk %@.", offer.currentVersion))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)

            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                Text(L10n.string("Release Notes"))
                    .font(DS.Typography.headline)
                    .accessibilityAddTraits(.isHeader)
                notes(offer.notes)
            }

            Text(L10n.format("Download size: %@", ByteFormat.string(Int64(offer.downloadBytes))))
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
            Text(L10n.string("WillyDisk is not signed or notarized by Apple. The checksum confirms the download arrived intact; it does not prove who built it."))
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func downloading(_ offer: UpdateOffer, _ progress: DownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            Text(L10n.format("Downloading WillyDisk %@…", offer.version))
                .font(DS.Typography.title2)
                .fixedSize(horizontal: false, vertical: true)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
            }
            if let expected = progress.expectedBytes {
                Text(
                    L10n.format(
                        "%@ of %@",
                        ByteFormat.string(progress.receivedBytes),
                        ByteFormat.string(expected)
                    )
                )
                .font(DS.Typography.callout)
                .foregroundStyle(DS.Color.secondaryText)
                .monospacedDigit()
            } else {
                Text(ByteFormat.string(progress.receivedBytes))
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    private func notes(_ notes: String) -> some View {
        let blocks = UpdateNoteBlock.parse(notes)
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.small) {
                if blocks.isEmpty {
                    Text(L10n.string("No release notes."))
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                } else {
                    ForEach(blocks) { block in
                        noteBlock(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Release notes are publisher text in English; keep their reading
        // direction independent of an Arabic interface, including the bullets.
        .environment(\.layoutDirection, .leftToRight)
        .frame(maxHeight: 220)
        .padding(DS.Spacing.medium)
        .background(
            DS.Color.enamel,
            in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(DS.Color.rule, lineWidth: DS.Stroke.hairline)
        }
    }

    @ViewBuilder
    private func noteBlock(_ block: UpdateNoteBlock) -> some View {
        switch block.kind {
        case .heading:
            Text(inlineMarkdown(block.text))
                .font(DS.Typography.headline)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.small) {
                Text(verbatim: "•")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Color.secondaryText)
                Text(inlineMarkdown(block.text))
                    .font(DS.Typography.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .paragraph:
            Text(inlineMarkdown(block.text))
                .font(DS.Typography.callout)
                .fixedSize(horizontal: false, vertical: true)

        case .code:
            Text(verbatim: block.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(DS.Spacing.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DS.Color.controlBackground,
                    in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                )
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DS.Spacing.small) {
            if showsLastChecked, let lastChecked {
                Text(L10n.format("Last checked %@.", DateFormat.relative(lastChecked)))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
            }
            Spacer(minLength: 0)
            footerActions
        }
        .padding(.horizontal, DS.Spacing.xxLarge)
        .padding(.vertical, DS.Spacing.large)
    }

    private var showsLastChecked: Bool {
        switch state {
        case .upToDate, .newerThanLatest, .available, .ready, .noBuildForThisMac, .incompleteRelease:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        switch state {
        case .checking:
            Button(L10n.string("Later"), action: actions.close)
                .keyboardShortcut(.cancelAction)

        case .available:
            Button(L10n.string("Later"), action: actions.close)
                .keyboardShortcut(.cancelAction)
            Button(L10n.string("Skip This Version"), action: actions.skip)
            Button(action: actions.download) {
                Text(L10n.string("Download"))
                    .frame(minWidth: DS.Size.actionMinWidth)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .downloading:
            Button(L10n.string("Cancel"), action: actions.cancel)
                .keyboardShortcut(.cancelAction)

        case .verifying:
            Button(L10n.string("Cancel"), action: actions.cancel)
                .keyboardShortcut(.cancelAction)

        case let .ready(ready):
            Button(L10n.string("Open Release Page")) {
                actions.openPage(ready.pageURL)
            }
            Button(L10n.string("Show in Finder")) {
                actions.reveal(ready.archiveURL)
            }
            Button(action: actions.close) {
                Text(L10n.string("Done"))
                    .frame(minWidth: DS.Size.secondaryActionMinWidth)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .upToDate, .newerThanLatest, .unknownCurrentVersion:
            Button(action: actions.close) {
                Text(L10n.string("Done"))
                    .frame(minWidth: DS.Size.secondaryActionMinWidth)
            }
            .keyboardShortcut(.defaultAction)

        case let .noBuildForThisMac(_, pageURL):
            pageButton(pageURL)
            doneButton()

        case let .incompleteRelease(_, pageURL):
            pageButton(pageURL)
            doneButton()

        case let .failed(_, pageURL):
            Button(L10n.string("Try Again"), action: actions.retry)
            if let pageURL {
                pageButton(pageURL)
            }
            doneButton()
        }
    }

    private func pageButton(_ url: URL) -> some View {
        Button(L10n.string("Open Release Page")) {
            actions.openPage(url)
        }
    }

    private func doneButton() -> some View {
        Button(action: actions.close) {
            Text(L10n.string("Done"))
                .frame(minWidth: DS.Size.secondaryActionMinWidth)
        }
        .keyboardShortcut(.defaultAction)
    }

    // MARK: - Failure wording

    private func failureTitle(_ failure: UpdateFailure) -> String {
        switch failure {
        case .offline, .timedOut, .noRelease, .rateLimited, .http, .malformedFeed, .unknown:
            return L10n.string("Couldn't Check for Updates")
        case .downloadFailed, .insufficientSpace, .cancelled:
            return L10n.string("Couldn't Download the Update")
        case .checksumMismatch, .invalidDownload:
            return L10n.string("Couldn't Check the Download")
        }
    }

    private func failureMessage(_ failure: UpdateFailure) -> String {
        switch failure {
        case .offline:
            return L10n.string("WillyDisk couldn't reach GitHub. Check your connection and try again.")
        case .timedOut:
            return L10n.string("GitHub took too long to respond. Try again.")
        case .noRelease:
            return L10n.string("No published release was found.")
        case .rateLimited:
            return L10n.string("GitHub is limiting requests right now. Try again later.")
        case .http:
            return L10n.string("GitHub returned an error. Try again later.")
        case .malformedFeed:
            return L10n.string("The update feed couldn't be read.")
        case .downloadFailed:
            return L10n.string("The update couldn't be downloaded. Try again.")
        case .checksumMismatch:
            return L10n.string("The download did not match the published checksum. Nothing was changed.")
        case .invalidDownload:
            return L10n.string("The download is not a valid WillyDisk build. Nothing was changed.")
        case .insufficientSpace:
            return L10n.string("There isn't enough free space for the download.")
        case .cancelled:
            return L10n.string("The download was cancelled.")
        case .unknown:
            return L10n.string("The update couldn't be completed. Try again.")
        }
    }
}

/// One block of a release body. GitHub returns Markdown; SwiftUI's block Markdown
/// rendering collapses headings and list items into a run-on paragraph, so the
/// sheet parses the small subset a release body uses and styles each block itself.
private struct UpdateNoteBlock: Identifiable {
    enum Kind {
        case heading
        case bullet
        case paragraph
        case code
    }

    let id: Int
    let kind: Kind
    let text: String

    static func parse(_ notes: String) -> [UpdateNoteBlock] {
        var blocks: [UpdateNoteBlock] = []
        var nextID = 0
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false

        func append(_ kind: Kind, _ text: String) {
            blocks.append(UpdateNoteBlock(id: nextID, kind: kind, text: text))
            nextID += 1
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(.paragraph, paragraph.joined(separator: " "))
            paragraph.removeAll()
        }

        for rawLine in notes.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    append(.code, code.joined(separator: "\n"))
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                code.append(rawLine)
                continue
            }
            if line.isEmpty || line == "---" || line == "***" {
                flushParagraph()
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                let heading = line.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    append(.heading, heading)
                }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                append(.bullet, String(line.dropFirst(2)))
                continue
            }
            if line.first?.isNumber == true,
               line.contains(". ") || line.contains(") ") {
                // An ordered item is kept as its own paragraph, so the number and
                // its text stay on one line instead of joining the prose around it.
                flushParagraph()
                append(.paragraph, line)
                continue
            }
            paragraph.append(line)
        }

        flushParagraph()
        if inCode, !code.isEmpty {
            append(.code, code.joined(separator: "\n"))
        }
        return blocks
    }
}

/// Wires the pure sheet to one controller. The sheet is presented for the life of
/// a check; closing it cancels a download in flight, which returns the controller
/// to the offer rather than leaving a task writing into a hidden directory.
@MainActor
public struct UpdateSheetHost: View {
    @State private var controller: UpdateController
    @State private var operationTask: Task<Void, Never>?
    private let onClose: () -> Void

    public init(controller: UpdateController, onClose: @escaping () -> Void) {
        _controller = State(initialValue: controller)
        self.onClose = onClose
    }

    public var body: some View {
        UpdateSheet(
            state: controller.state,
            lastChecked: controller.preferences.lastCheck,
            actions: UpdateSheetActions(
                retry: {
                    operationTask = Task { await controller.retry() }
                },
                download: {
                    operationTask = Task { await controller.download() }
                },
                cancel: {
                    operationTask?.cancel()
                    operationTask = nil
                },
                skip: {
                    controller.skip()
                    onClose()
                },
                openPage: { url in
                    NSWorkspace.shared.open(url)
                },
                reveal: { url in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                },
                close: onClose
            )
        )
        .onDisappear {
            operationTask?.cancel()
            operationTask = nil
        }
    }
}
