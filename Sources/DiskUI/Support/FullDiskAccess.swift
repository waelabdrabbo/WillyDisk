import AppKit

/// Opens the Full Disk Access pane of System Settings.
///
/// macOS exposes no public API to *request* Full Disk Access, and TCC cannot be
/// prompted for it — Apple's sanctioned route is the System Settings privacy
/// deep link. The `Privacy_AllFiles` anchor is the Full Disk Access pane; the
/// bare `com.apple.preference.security` link is the parent Privacy & Security
/// pane and is used as a fallback so the button always performs a real action
/// even if the anchor is ever renamed.
public enum FullDiskAccessSettings {

    /// `System Settings → Privacy & Security → Full Disk Access`.
    public static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// `System Settings → Privacy & Security` (fallback destination).
    public static let privacyPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security"
    )!

    /// Opens the Full Disk Access pane, falling back to Privacy & Security.
    /// - Returns: `true` when one of the panes was opened.
    @discardableResult
    public static func open() -> Bool {
        if NSWorkspace.shared.open(paneURL) { return true }
        return NSWorkspace.shared.open(privacyPaneURL)
    }
}
