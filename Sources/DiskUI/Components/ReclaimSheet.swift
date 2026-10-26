import SwiftUI
import DiskCore
import DiskLocalization

/// One item the confirmation sheet is about, captured from the scan node so the
/// sheet does not have to reach back into a tree that may have changed.
public struct ReclaimCandidate: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let logicalSize: Int64
    let allocatedSize: Int64
    let fileCount: Int
    let directoryCount: Int
    let isSymlink: Bool

    public var id: URL { url }

    public init(node: ScanNode) {
        url = node.url
        name = node.name
        isDirectory = node.isDirectory
        logicalSize = node.logicalSize
        allocatedSize = node.allocatedSize
        fileCount = node.fileCount
        directoryCount = node.directoryCount
        isSymlink = node.isSymlink
    }
}

extension Array where Element == ReclaimCandidate {
    var totalLogicalSize: Int64 { reduce(0) { $0 + $1.logicalSize } }
    var totalAllocatedSize: Int64 { reduce(0) { $0 + $1.allocatedSize } }
}

/// The confirmation in front of every trash action.
///
/// It names exactly what will move, shows both sizes the scan knows, and states
/// the one thing people expect a disk tool to say and usually does not: the space
/// comes back when the Trash is emptied, not when the item is moved.
struct ReclaimSheet: View {
    let candidates: [ReclaimCandidate]
    let refusal: ReclaimRefusal?
    let isChecking: Bool
    let isWorking: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var title: String {
        if candidates.count == 1 {
            return L10n.format("Move “%@” to the Trash?", candidates[0].name)
        }
        return L10n.format("Move %@ to the Trash?", CountFormat.items(candidates.count))
    }

    private var hasSymlink: Bool { candidates.contains { $0.isSymlink } }

    private var statusText: String {
        if candidates.count == 1 {
            return L10n.string(isChecking ? "Checking this item…" : "Moving to the Trash…")
        }
        return L10n.string(isChecking ? "Checking these items…" : "Moving these items to the Trash…")
    }

    /// True when the tree measures more bytes than the items currently occupy.
    /// A dataless iCloud file, a sparse file, and a compressed file all look like
    /// this, so the sheet promises less available space rather than guessing which
    /// one it is.
    private var hasThinStorage: Bool {
        candidates.contains { $0.logicalSize > 0 && $0.allocatedSize < $0.logicalSize / 2 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.large) {
            HStack(alignment: .top, spacing: DS.Spacing.medium) {
                Image(systemName: "trash")
                    .font(DS.Icon.medium)
                    .foregroundStyle(DS.Color.secondaryText)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                    Text(title)
                        .font(DS.Typography.title2)
                    Text(L10n.string(candidates.count == 1
                         ? "You can put it back from the Trash until you empty it."
                         : "You can put them back from the Trash until you empty it."))
                        .font(DS.Typography.callout)
                        .foregroundStyle(DS.Color.secondaryText)
                }
            }

            candidateList

            VStack(alignment: .leading, spacing: DS.Spacing.xSmall) {
                detailLine(L10n.string("On disk"), ByteFormat.exact(candidates.totalAllocatedSize))
                detailLine(L10n.string("Size"), ByteFormat.exact(candidates.totalLogicalSize))
                Text(L10n.string("Moving to the Trash does not free space until the Trash is emptied."))
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if hasSymlink {
                    Text(L10n.string("Symbolic links are moved themselves; the items they point to stay where they are."))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if hasThinStorage {
                    Text(L10n.string("Part of this item is not stored on disk right now; moving it may free less space than its reported size."))
                        .font(DS.Typography.caption)
                        .foregroundStyle(DS.Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let refusal {
                refusalNotice(refusal)
            }

            Divider()

            HStack(spacing: DS.Spacing.small) {
                if isChecking || isWorking {
                    // The status lives beside the buttons rather than above them:
                    // it appears without changing the sheet's height, and its
                    // normal text colour stays readable while the action is
                    // disabled.
                    HStack(spacing: DS.Spacing.xSmall) {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusText)
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Spacing.small)
                Button(role: .cancel, action: onCancel) {
                    Text(L10n.string("Cancel"))
                        .frame(minWidth: DS.Size.secondaryActionMinWidth)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
                Button(role: .destructive, action: onConfirm) {
                    Text(L10n.string("Move to Trash"))
                        .frame(minWidth: DS.Size.actionMinWidth)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)
                .disabled(refusal != nil || isWorking || isChecking)
            }
        }
        .padding(DS.Spacing.xLarge)
        .frame(width: 460)
        .tint(DS.Color.signal)
    }

    private var candidateList: some View {
        Group {
            if candidates.count <= 4 {
                candidateRows
            } else {
                ScrollView { candidateRows }
                    .frame(height: 220)
            }
        }
        .background(DS.Color.controlBackground, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(DS.Color.separator, lineWidth: DS.Spacing.hairline)
        )
    }

    private var candidateRows: some View {
        VStack(spacing: 0) {
            ForEach(candidates) { candidate in
                HStack(spacing: DS.Spacing.small) {
                    Image(systemName: candidate.isDirectory ? "folder.fill" : "doc.fill")
                        .font(DS.Icon.inline)
                        .foregroundStyle(DS.Color.secondaryText)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: DS.Spacing.xxSmall) {
                        Text(candidate.name)
                            .font(DS.Typography.body)
                            .lineLimit(1)
                        Text(PathFormat.abbreviated(candidate.url.path))
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Color.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if candidate.isDirectory {
                            Text(L10n.format("%@ in %@", CountFormat.files(candidate.fileCount), CountFormat.folders(candidate.directoryCount)))
                                .font(DS.Typography.caption)
                                .foregroundStyle(DS.Color.secondaryText)
                        }
                    }
                    Spacer(minLength: DS.Spacing.small)
                    Text(ByteFormat.string(candidate.logicalSize))
                        .font(DS.Typography.metadataFigures)
                        .foregroundStyle(DS.Color.secondaryText)
                }
                .padding(.vertical, DS.Spacing.small)
                if candidate.id != candidates.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, DS.Spacing.medium)
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: DS.Spacing.small) {
            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Color.secondaryText)
            Text(value)
                .font(DS.Typography.metadataFigures)
        }
    }

    private func refusalNotice(_ refusal: ReclaimRefusal) -> some View {
        WarningNotice(refusal.explanation, title: refusal.title)
    }
}

/// What the results screen says after a trash request, until the banner
/// dismisses it.
public struct ReclaimNotice: Equatable, Sendable {
    let tone: ReclaimBanner.Tone
    let message: String
    let showsShowTrash: Bool
}

/// The line after a trash action that keeps the results honest.
///
/// It never says the space was reclaimed: it says what moved and when the space
/// comes back, offers the Trash, and dismisses itself after a short read. A move
/// reaches the watched tree as a filesystem change, so there is nothing to
/// re-measure by hand here. The notice is an opaque panel lifted off the results,
/// so the list underneath never reads through it; it holds open while the pointer
/// is over it, so its actions stay reachable while they are in use.
struct ReclaimBanner: View {
    enum Tone: Equatable, Sendable { case success, failure }

    let tone: Tone
    let message: String
    let showsShowTrash: Bool
    let onShowTrash: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    private var icon: String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch tone {
        case .success: DS.Color.success
        case .failure: DS.Color.danger
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
    }

    /// A new notice, or the pointer moving on or off the banner, starts a fresh
    /// hold for the auto-dismiss.
    private struct DismissalKey: Equatable {
        let message: String
        let isHovered: Bool
    }

    var body: some View {
        HStack(spacing: DS.Spacing.medium) {
            Image(systemName: icon)
                .font(DS.Icon.small)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(DS.Typography.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.small)
            if showsShowTrash {
                Button(L10n.string("Show Trash"), action: onShowTrash)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(L10n.string("Opens the Trash in Finder"))
            }
            IconActionButton(symbol: "xmark", help: L10n.string("Dismiss"), surface: .inline, action: onDismiss)
        }
        .padding(.horizontal, DS.Spacing.large)
        .padding(.vertical, DS.Spacing.small)
        .background {
            // The tone is a wash over an opaque platter, never a substitute for
            // it: the results underneath stay out of the notice.
            shape.fill(DS.Color.enamel)
            shape.fill(tint.opacity(DS.Opacity.noticeWash))
        }
        .overlay {
            // The notice is told apart by its surface and lift. Increased
            // contrast is the one case that adds an outline.
            if contrast == .increased {
                shape.strokeBorder(DS.Color.separator, lineWidth: DS.Stroke.emphasis)
            }
        }
        .shadow(
            color: DS.Color.shadow.opacity(DS.Shadow.floatingOpacity),
            radius: DS.Shadow.floatingRadius,
            y: DS.Shadow.floatingOffset
        )
        .onHover { isHovered = $0 }
        .task(id: DismissalKey(message: message, isHovered: isHovered)) {
            guard !isHovered else { return }
            try? await Task.sleep(for: DS.Timing.notice)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
