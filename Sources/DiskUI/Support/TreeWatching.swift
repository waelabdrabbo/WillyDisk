import Foundation
import DiskCore

/// The seam between the results state machine and the filesystem watcher.
///
/// The live watcher is `ScanTreeWatcher`; tests substitute one that reports the
/// batches they choose. The view model owns the lifecycle either way.
@MainActor
public protocol TreeWatching: AnyObject {
    func start(
        root: URL,
        excludedPaths: [URL],
        stayOnVolume: Bool,
        onChange: @escaping @Sendable (ScanTreeChange) -> Void
    ) throws
    func stop()
}

extension ScanTreeWatcher: TreeWatching {}
