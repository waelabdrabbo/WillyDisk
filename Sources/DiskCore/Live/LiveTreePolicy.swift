import Foundation

/// The scan rules a live tree keeps applying while it is edited.
///
/// An edit to a tree is only correct under the rules the tree was measured with:
/// whether hidden items were skipped, which paths were excluded, whether a nested
/// volume was descended, and whether a symbolic link was followed. `ScanRequest`
/// is that record; this is the part of it the updater needs.
public struct LiveTreePolicy: Sendable, Equatable {
    public var includeHidden: Bool
    public var followSymlinks: Bool
    public var stayOnVolume: Bool
    public var excludedPaths: [URL]

    public init(
        includeHidden: Bool = true,
        followSymlinks: Bool = false,
        stayOnVolume: Bool = true,
        excludedPaths: [URL] = []
    ) {
        self.includeHidden = includeHidden
        self.followSymlinks = followSymlinks
        self.stayOnVolume = stayOnVolume
        self.excludedPaths = excludedPaths
    }

    /// The rules of the scan the tree describes.
    public init(_ request: ScanRequest) {
        self.includeHidden = request.includeHidden
        self.followSymlinks = request.followSymlinks
        self.stayOnVolume = request.stayOnVolume
        self.excludedPaths = request.excludedPaths
    }
}
