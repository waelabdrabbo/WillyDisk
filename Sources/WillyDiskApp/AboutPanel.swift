import AppKit
import DiskUI

/// Presents the standard About panel, filled with the app's own credits.
///
/// The name, marketing version, build number, and copyright come from the
/// bundle's Info.plist, which `Scripts/bundle-app.sh` assembles from the
/// repository's `VERSION` file. The icon is `AppMarkImage`, the same circular
/// mark the hero and the rest of the UI show — the rounded-square body belongs
/// to the macOS app icon alone.
@MainActor
enum AboutPanel {
    static func present() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationIcon: AppMarkImage.shared,
        ])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6

        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let credits = NSMutableAttributedString(
            string: "A local disk-space analyzer for macOS.\nScans run on this Mac; nothing is uploaded.\n\n",
            attributes: style
        )
        credits.append(NSAttributedString(string: "MIT License", attributes: style))
        return credits
    }
}
