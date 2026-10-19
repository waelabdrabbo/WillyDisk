import Foundation
import Darwin
import DiskCore

/// The volume a path lives on, read from the mount table rather than guessed
/// from the path's shape. `statfs` is the same source Finder and `df` use, and it
/// answers both questions the reclaim guard needs: where the volume starts, and
/// whether it is mounted read-only.
struct MountedVolume {
    let root: URL
    let isReadOnly: Bool

    static func of(_ url: URL) -> MountedVolume? {
        var info = statfs()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &info)
        }
        guard status == 0 else { return nil }

        let root = withUnsafePointer(to: &info.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return MountedVolume(
            root: URL(fileURLWithPath: root),
            isReadOnly: (info.f_flags & UInt32(MNT_RDONLY)) != 0
        )
    }
}

/// What the app knows about one item at the moment a reclaim starts.
///
/// Passed in rather than discovered by the policy so the decision is pure and
/// table-testable: the view fills this from the scan's root and the mount table,
/// tests fill it directly.
struct ReclaimContext: Equatable, Sendable {
    var scanRoot: URL
    var isScanning: Bool
    var volumeRoot: URL?
    var isVolumeReadOnly: Bool
    var exists: Bool

    /// Paths the filesystem resolved off the main actor.
    ///
    /// `nil` means the caller did not resolve them, and the policy falls back to
    /// resolving on the spot. The app always fills them from `ReclaimContextProbe`;
    /// the fallback keeps the policy usable on its own in tests.
    var targetPath: String?
    var scanRootPath: String?
    var volumeRootPath: String?

    init(
        scanRoot: URL,
        isScanning: Bool,
        volumeRoot: URL?,
        isVolumeReadOnly: Bool,
        exists: Bool,
        targetPath: String? = nil,
        scanRootPath: String? = nil,
        volumeRootPath: String? = nil
    ) {
        self.scanRoot = scanRoot
        self.isScanning = isScanning
        self.volumeRoot = volumeRoot
        self.isVolumeReadOnly = isVolumeReadOnly
        self.exists = exists
        self.targetPath = targetPath
        self.scanRootPath = scanRootPath
        self.volumeRootPath = volumeRootPath
    }
}

/// Why an item cannot be moved to the Trash.
///
/// Every case carries the reason in words, because a disabled button that does
/// not say why is exactly the kind of dead end the app avoids.
public enum ReclaimRefusal: Equatable, Sendable {
    case scanning
    case scanRoot
    case scanRootAncestor
    case volumeRoot
    case homeFolder
    case protectedPath
    case readOnlyVolume
    case missing

    var title: String {
        switch self {
        case .scanning: "A scan is running"
        case .scanRoot: "This is the folder being scanned"
        case .scanRootAncestor: "This folder holds the folder being scanned"
        case .volumeRoot: "This is the top of a volume"
        case .homeFolder: "This is your home folder"
        case .protectedPath: "This is a protected system location"
        case .readOnlyVolume: "This volume is read-only"
        case .missing: "This item is no longer there"
        }
    }

    var explanation: String {
        switch self {
        case .scanning:
            "Stop the scan, or wait for it to finish, before moving items to the Trash."
        case .scanRoot:
            "The scan is measuring this folder. Choose a file or a folder inside it instead."
        case .scanRootAncestor:
            "Moving it would take the scan with it. Choose an item inside the scanned folder instead."
        case .volumeRoot:
            "Moving a whole volume to the Trash would take everything on it. WillyDisk only moves items inside a volume."
        case .homeFolder:
            "WillyDisk does not move your home folder as a whole. Choose a file or a folder inside it instead."
        case .protectedPath:
            "WillyDisk does not move system locations. Choose an item inside the scanned folder instead."
        case .readOnlyVolume:
            "The system does not allow changes on this volume."
        case .missing:
            "It may have been moved or deleted since the scan."
        }
    }
}

/// The guard in front of every trash action.
///
/// The rules are about what a person would lose, not about what the filesystem
/// would allow: the scan's own root (and anything above it), a volume's top, the
/// system's own locations, read-only volumes, an item that is already gone, and
/// anything at all while a scan is running.
enum ReclaimPolicy {
    /// Trees that are never moved from, at any depth.
    ///
    /// `/private` is deliberately not one of them as a whole: caches and temporary
    /// files below it are normal reclaim targets. The system's own corners of it
    /// are named instead, and the roots of `/private` itself are protected
    /// locations below.
    private static let protectedTrees = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/Library/Apple",
        "/private/etc",
        "/private/var/db",
        "/private/var/vm",
        "/private/var/root"
    ]

    /// Locations that are never moved themselves, while their contents stay
    /// eligible. Trashing `/Applications` would take every app with it; trashing
    /// one app inside it is a normal thing to do.
    private static let protectedLocations = [
        "/",
        "/Applications",
        "/Library",
        "/Users",
        "/Volumes",
        "/private",
        "/private/etc",
        "/private/tmp",
        "/private/var",
        "/private/var/folders"
    ]

    static func refusal(for url: URL, in context: ReclaimContext) -> ReclaimRefusal? {
        if context.isScanning { return .scanning }
        if !context.exists { return .missing }

        let target = context.targetPath ?? guardedPath(url)
        let scanRoot = context.scanRootPath ?? guardedPath(context.scanRoot)

        // The scan's own root and everything above it are refused before the
        // location rules, so the explanation names the scan rather than a
        // system folder that happens to contain it.
        if isSameOrAncestor(target, of: scanRoot) {
            return target == scanRoot ? .scanRoot : .scanRootAncestor
        }
        let volumeRoot = context.volumeRootPath ?? context.volumeRoot.map { guardedPath($0) }
        if let volumeRoot, volumeRoot == target {
            return .volumeRoot
        }
        if let protection = protection(for: target) { return protection }
        if context.isVolumeReadOnly { return .readOnlyVolume }
        return nil
    }

    /// The path the filesystem would act on, resolved off the main actor by the
    /// probe so `refusal` itself never touches the filesystem.
    static func resolvedPath(for url: URL) -> String {
        guardedPath(url)
    }

    private static func protection(for path: String) -> ReclaimRefusal? {
        if path == homePath { return .homeFolder }
        if protectedLocations.contains(path) { return .protectedPath }
        if protectedTrees.contains(where: { isSameOrAncestor($0, of: path) }) { return .protectedPath }
        return nil
    }

    /// The home folder's canonical spelling, without resolving links.
    ///
    /// `NSHomeDirectory()` is already the real path, and reading it here keeps the
    /// policy free of filesystem calls when the probe supplied the other paths.
    private static let homePath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

    /// The path as a person names it on the startup disk.
    ///
    /// macOS mounts the Data volume at `/System/Volumes/Data` and presents its
    /// contents at the root through firmlinks. A scan of that volume therefore
    /// produces `/System/Volumes/Data/Users/…`, which is the same folder as
    /// `/Users/…`. Folding the prefix back makes both spellings face the same
    /// rules, instead of the Data volume looking like part of `/System`.
    private static func guardedPath(_ url: URL) -> String {
        let path = canonical(url)
        let dataVolume = "/System/Volumes/Data"
        if path == dataVolume { return "/" }
        if path.hasPrefix(dataVolume + "/") {
            return String(path.dropFirst(dataVolume.count))
        }
        return path
    }

    /// The path the filesystem would act on, with `..` folded and symbolic links
    /// resolved, so `/tmp` is judged as `/private/tmp` and a link cannot point a
    /// safe-looking row at a system folder.
    private static func canonical(_ url: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        // Foundation can answer with either spelling of the system aliases —
        // `/etc` or `/private/etc` — depending on which prefixes exist. Folding
        // both onto the real path keeps the guard's rules independent of that.
        for (alias, real) in [("/etc", "/private/etc"), ("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if resolved == alias { return real }
            if resolved.hasPrefix(alias + "/") {
                return real + resolved.dropFirst(alias.count)
            }
        }
        return resolved
    }

    private static func isSameOrAncestor(_ ancestor: String, of descendant: String) -> Bool {
        if ancestor == descendant { return true }
        guard !ancestor.isEmpty else { return false }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return descendant.hasPrefix(prefix)
    }
}

/// Reads the context `ReclaimPolicy` needs without blocking the main thread.
///
/// The item's existence and its volume's flags are filesystem questions, and on
/// a network volume they can take a moment; the caller gets the answer on the
/// main actor when they are done.
enum ReclaimContextProbe {
    static func context(for url: URL, scanRoot: URL) async -> ReclaimContext {
        await Task.detached(priority: .userInitiated) {
            let volume = MountedVolume.of(url)
            // `lstat`, not `fileExists`: a broken symbolic link is still an entry
            // the Trash can take, and following its target would call it missing.
            var entry = stat()
            let exists = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return lstat(path, &entry) == 0
            }
            return ReclaimContext(
                scanRoot: scanRoot,
                isScanning: false,
                volumeRoot: volume?.root,
                isVolumeReadOnly: volume?.isReadOnly ?? false,
                exists: exists,
                targetPath: ReclaimPolicy.resolvedPath(for: url),
                scanRootPath: ReclaimPolicy.resolvedPath(for: scanRoot),
                volumeRootPath: volume.map { ReclaimPolicy.resolvedPath(for: $0.root) }
            )
        }.value
    }
}

/// Moves one item to the Trash. The seam exists so tests can prove the exact URL
/// without touching a real Trash.
protocol FileTrashing: Sendable {
    /// Returns where the item now lives in the Trash, when the system reports it.
    func trash(_ url: URL) async throws -> URL?
}

/// The live trashing seam: the system's own Trash operation, off the main thread.
struct SystemFileTrasher: FileTrashing {
    func trash(_ url: URL) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }.value
    }
}

/// What happened to one trash request, in the view's terms.
enum ReclaimOutcome: Equatable {
    case trashed(URL?)
    case failed(String)
}

/// Runs the trash operation and turns any error into the system's own words.
struct ReclaimController {
    private let trasher: any FileTrashing

    init(trasher: any FileTrashing = SystemFileTrasher()) {
        self.trasher = trasher
    }

    func trash(_ url: URL) async -> ReclaimOutcome {
        do {
            return .trashed(try await trasher.trash(url))
        } catch {
            let error = error as NSError
            let reason = error.localizedFailureReason ?? error.localizedDescription
            return .failed(reason)
        }
    }
}
