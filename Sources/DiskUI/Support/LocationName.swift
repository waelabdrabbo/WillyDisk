import Foundation

/// The name the app shows for a location on disk.
///
/// A location is usually named by its last path component. A mount point has
/// none — `lastPathComponent` of the startup disk is the separator itself, not a
/// name — so it is named for the volume mounted there, the same name the volume
/// rows on source selection carry. The path is the last resort, for a location
/// that has neither a component nor a named volume.
public enum LocationName {

    /// The name to show for `url`.
    public static func of(_ url: URL) -> String {
        guard let component = nameComponent(of: url) else {
            return volumeName(of: url) ?? url.path
        }
        return component
    }

    /// The location's own component, or `nil` when it has none: an empty
    /// component and the separator both name a location rather than a place
    /// inside one.
    private static func nameComponent(of url: URL) -> String? {
        let component = url.lastPathComponent
        guard !component.isEmpty, component != "/" else { return nil }
        return component
    }

    /// The localized name of the volume `url` is mounted from, when it has one.
    private static func volumeName(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
        let name = values?.volumeLocalizedName ?? values?.volumeName
        guard let name, !name.isEmpty else { return nil }
        return name
    }
}
