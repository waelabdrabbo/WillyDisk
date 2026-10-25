import Foundation
import Darwin

/// One batch of filesystem changes reduced to what a scan of a particular root
/// cares about.
///
/// `folders` is bounded by `ScanWatchScope.maxBatchPaths` so a pathological
/// burst cannot grow a consumer without bound. It is a work list, not a label:
/// a consumer that reconciles folders must act on all of them (and defer the
/// tail if it has its own bound), because a folder left out is a change the
/// screen never sees.
public struct ScanTreeChange: Sendable, Equatable {
    /// The changed folders, in the order they were first reported.
    public let folders: [URL]
    /// Whether the batch could not name its paths reliably: FSEvents dropped or
    /// wrapped events, or asked for a whole subtree to be rescanned.
    public let isCoarse: Bool
    /// The watched root itself is gone. Nothing can be refreshed.
    public let rootMissing: Bool

    public init(
        folders: [URL] = [],
        isCoarse: Bool = false,
        rootMissing: Bool = false
    ) {
        self.folders = folders
        self.isCoarse = isCoarse
        self.rootMissing = rootMissing
    }

    public var isEmpty: Bool {
        folders.isEmpty && !isCoarse && !rootMissing
    }
}

/// The device of the nearest existing ancestor of a path.
///
/// `stayOnVolume` is the scan's own rule, so the watcher has to apply the same
/// one: a change on another volume is not a change to what this scan measured.
public protocol ScanVolumeProbing: Sendable {
    func device(ofNearestExisting path: String) -> dev_t?
}

/// Reads device identifiers from the filesystem.
public struct LiveScanVolumeProbe: ScanVolumeProbing {
    public init() {}

    public func device(ofNearestExisting path: String) -> dev_t? {
        var candidate = path
        while candidate.count > 1 {
            let stat = FileStat.lstat(candidate)
            if stat.error == 0 { return stat.dev }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { break }
            candidate = parent
        }
        let stat = FileStat.lstat("/")
        return stat.error == 0 ? stat.dev : nil
    }
}

/// The part of a `ScanRequest` that decides whether a filesystem event belongs
/// to what the scan measured.
///
/// This is deliberately path-based rather than identity-based. FSEvents reports
/// the real path that changed, so an event under an excluded directory is out of
/// scope, while a hard link elsewhere that happens to name an excluded file is
/// not — the opposite of the traversal's identity test, and for a different
/// question.
public struct ScanWatchScope: Sendable {
    /// A batch larger than this is truncated; the walk on the other side of it
    /// measures the whole root again when a batch cannot be trusted.
    public static let maxBatchPaths = 4_096

    /// The root as the request named it, used when a change has to name it.
    public let root: URL
    /// The root's canonical path; the stream watches this and events match it.
    public let rootPath: String

    private let excludedPrefixes: [String]
    private let stayOnVolume: Bool
    private let rootDevice: dev_t?
    private let probe: any ScanVolumeProbing

    /// The startup disk's data volume, which FSEvents names when the watched
    /// root is `/` even though the scan records the firmlinked path.
    private static let dataVolume = "/System/Volumes/Data"

    public init(
        root: URL,
        excludedPaths: [URL] = [],
        stayOnVolume: Bool = true,
        rootDevice: dev_t? = nil,
        probe: any ScanVolumeProbing = LiveScanVolumeProbe()
    ) {
        let canonicalRoot = Self.canonicalPath(root)
        self.root = root
        self.rootPath = canonicalRoot
        self.stayOnVolume = stayOnVolume
        self.rootDevice = rootDevice
        self.probe = probe
        self.excludedPrefixes = excludedPaths
            .map(Self.canonicalPath)
            // The scanned location always wins over its own exclusion and over
            // an exclusion that contains it, exactly as the traversal applies it.
            .filter { !Self.isAtOrAbove($0, root: canonicalRoot) }
    }

    /// Whether a path is something this scan measured.
    public func includes(path: String) -> Bool {
        includes(normalized: normalizedPath(path))
    }

    /// Reduces a batch of event paths to the folders it changed.
    ///
    /// A coarse batch (dropped events, an ids wrap, or a subtree that must be
    /// rescanned) cannot name its parts, so the root is the honest answer. A
    /// root that is gone is reported as such and never silently dropped.
    public func change(
        inBatch paths: [String],
        isCoarse: Bool = false,
        rootMissing: Bool = false
    ) -> ScanTreeChange? {
        if rootMissing {
            return ScanTreeChange(folders: [root], isCoarse: true, rootMissing: true)
        }
        if isCoarse {
            return ScanTreeChange(folders: [root], isCoarse: true)
        }

        var seen = Set<String>()
        var folders: [URL] = []
        for raw in paths.prefix(Self.maxBatchPaths) {
            let path = normalizedPath(raw)
            guard includes(normalized: path), seen.insert(path).inserted else { continue }
            folders.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        guard !folders.isEmpty else { return nil }
        return ScanTreeChange(folders: folders)
    }

    // MARK: - Paths

    /// The path a `URL` stands for, with links resolved, so the root the stream
    /// watches and the paths FSEvents reports share one spelling.
    ///
    /// `realpath(3)` is what FSEvents matches against: it turns `/var/…` into
    /// `/private/var/…`, which `URL.resolvingSymlinksInPath()` leaves alone for
    /// the system's own symlinked roots. A path that does not exist cannot be
    /// resolved; its standardized spelling is the best answer there is.
    public static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        var path = standardized
        if let resolved = standardized.withCString({ realpath($0, nil) }) {
            path = String(cString: resolved)
            free(resolved)
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path
    }

    /// FSEvents asks in the namespace of the volume it watched. A `/` scan
    /// records `/Users/…`, while the events arrive as
    /// `/System/Volumes/Data/Users/…`, so the Data-volume prefix is mapped back.
    private func normalizedPath(_ raw: String) -> String {
        var path = raw
        if rootPath == "/" {
            if path == Self.dataVolume { path = "/" }
            if path.hasPrefix(Self.dataVolume + "/") {
                path = "/" + path.dropFirst(Self.dataVolume.count + 1)
            }
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func includes(normalized path: String) -> Bool {
        guard Self.isAtOrUnder(path, root: rootPath) else { return false }
        if excludedPrefixes.contains(where: { Self.isAtOrUnder(path, root: $0) }) {
            return false
        }
        if stayOnVolume, let rootDevice, let device = probe.device(ofNearestExisting: path),
           device != rootDevice {
            return false
        }
        return true
    }

    /// Whether `path` is `root` or lives below it. Compares whole path
    /// components, so `/scan/tree` cannot claim `/scan/treehouse`.
    static func isAtOrUnder(_ path: String, root: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        if path == root { return true }
        return path.hasPrefix(root + "/")
    }

    /// Whether `path` is `root` or one of its ancestors.
    static func isAtOrAbove(_ path: String, root: String) -> Bool {
        isAtOrUnder(root, root: path)
    }
}
