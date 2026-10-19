import AppKit
@preconcurrency import QuickLookUI

/// Shows the system's Quick Look panel for the explorer's current selection.
///
/// Quick Look is a window, not a sheet and not a SwiftUI view: the panel owns
/// its own lifecycle, its own key handling and its own arrow-key paging between
/// previews, so it is driven through the Quick Look panel instead of a
/// reimplementation of a preview window.
///
/// Every presentation re-checks that the items still exist, off the main thread,
/// before the panel is shown. A scan's rows are a report about the filesystem,
/// not the filesystem itself, and a preview must never open on a path that has
/// gone since the scan.
@MainActor
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var items: [URL] = []
    /// Identifies the newest request: a slow existence check lands only if no
    /// later request has replaced it.
    private var requestID = UUID()

    /// Opens the panel for `urls`, or closes it when the same set is already on
    /// screen. Space is a toggle, exactly as it is in Finder.
    func toggle(_ urls: [URL]) {
        let unique = unique(urls)
        guard !unique.isEmpty else {
            close()
            return
        }
        if isVisible, Set(items) == Set(unique) {
            close()
            return
        }
        present(unique)
    }

    /// Keeps an open panel in step with the selection. A closed panel stays
    /// closed: this is not a request to show anything.
    func updateIfVisible(_ urls: [URL]) {
        guard isVisible else { return }
        let unique = unique(urls)
        if unique.isEmpty {
            close()
        } else if items != unique {
            present(unique)
        }
    }

    func close() {
        // A presentation that is still checking existence must not open the
        // panel after the selection that asked for it has gone.
        requestID = UUID()
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    private func present(_ urls: [URL]) {
        let request = UUID()
        requestID = request
        Task {
            let existing = await Task.detached(priority: .userInitiated) {
                urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            }.value
            guard request == requestID else { return }
            guard !existing.isEmpty else {
                // The selection's paths have all gone since the rows were drawn;
                // leaving the old preview up would show files that are no longer
                // selected. Close it and say there is nothing to preview.
                close()
                NSSound.beep()
                return
            }
            guard let panel = QLPreviewPanel.shared() else { return }
            items = existing
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        return urls.filter { seen.insert($0).inserted }
    }

    // Quick Look asks these questions on the main thread, while the panel is
    // being driven; hopping back to the main actor states that rather than
    // assuming it.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard index >= 0, index < items.count else { return nil }
            return items[index] as NSURL
        }
    }
}
