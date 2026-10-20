import AppKit

/// Presents the standard About panel, filled with the app's own credits.
///
/// The name, marketing version, build number, and copyright come from the
/// bundle's Info.plist, which `Scripts/bundle-app.sh` assembles from the
/// repository's `VERSION` file. The icon is the committed 1024 PNG rather than
/// the system's resolved application icon: it is the same cut the `.icns`
/// carries, and naming it explicitly means the panel shows the mark whatever the
/// launch context resolved the bundle icon to, including an unbundled run.
@MainActor
enum AboutPanel {
    static func present() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let icon = bundleIcon {
            options[.applicationIcon] = icon
        }
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    private static var bundleIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
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
