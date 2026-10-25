import Foundation
import AppKit
import UniformTypeIdentifiers
import DiskLocalization

/// The one save-panel path the app's exported documents share.
///
/// Report export and the diagnostics report both ask for a destination, write
/// one UTF-8 text file there, and explain a refused write. Sharing the panel
/// keeps the two exports asking and failing the same way.
@MainActor
enum ExportPanel {
    static func present(
        content: String,
        defaultName: String,
        contentType: UTType,
        title: String,
        message: String? = nil,
        failureDescription: (URL, Error) -> String
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.title = title
        if let message {
            panel.message = message
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Export failed")
            alert.informativeText = failureDescription(url, error)
            alert.runModal()
        }
    }
}
