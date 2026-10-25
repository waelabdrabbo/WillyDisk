import Foundation

/// Applies filesystem changes to a `LiveTree`: the half of the live model that
/// turns a batch of changed folders into measured edits.
///
/// One changed folder is reconciled by reading its entries in bulk and diffing
/// them against the folders the tree already holds: a file is written from its
/// own `stat`, a vanished entry is removed, and a folder that is new (or changed
/// its kind) is measured with the same engine that produced the scan. Nothing is
/// ever written from an assumption, and the scan's own rules are re-applied to
/// every entry — hidden items, exclusions, the volume rule, and the symlink
/// policy of `LiveTreePolicy`.
///
/// The actor serializes every edit, so the tree's lock is taken only when a
/// batch is applied; a screen reading the tree never waits on a directory read
/// or a subtree scan.
public actor LiveTreeUpdater {
    /// What one call did, and what it left for the next one.
    public struct Batch: Sendable, Equatable {
        public let changed: Bool
        public let applied: Int
        public let ignored: Int
        /// How many folders this call reconciled.
        public let folders: Int
        /// Folders this call did not reconcile because it hit a bound. The
        /// caller queues them for the next pass; nothing was written for them.
        public let deferred: [String]
    }

    private struct FileKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private enum Reconcile {
        case edits([LiveTree.Edit])
        case deferred
    }

    private let tree: LiveTree
    private let policy: LiveTreePolicy
    private let engine: any ScanEngine
    private let reader: DirectoryReader
    private let access: FileSystemAccess
    private let rootDevice: dev_t?
    private let excludedKeys: Set<FileKey>
    private let excludedPaths: [String]
    private let maxFoldersPerBatch: Int
    private let maxSubtreeScansPerBatch: Int
    private var subtreeScans = 0
    /// Whether a pass is in flight. The actor is reentrant across the awaits in a
    /// pass, so this is what keeps two passes from measuring the tree at once.
    private var isApplying = false

    /// - Parameters:
    ///   - engine: measures a folder that arrived; its own instance by default,
    ///     so a subtree walk never collides with the scan on the app's slot.
    ///   - maxFoldersPerBatch: how many folders one call reconciles.
    ///   - maxSubtreeScansPerBatch: how many new folders one call measures. The
    ///     rest are returned in `Batch.deferred` rather than blocking the caller.
    public init(
        tree: LiveTree,
        policy: LiveTreePolicy,
        engine: (any ScanEngine)? = nil,
        maxFoldersPerBatch: Int = 512,
        maxSubtreeScansPerBatch: Int = 16
    ) {
        let access = FileSystemAccess.live
        let resolvedRoot = access.resolvedPath(tree.rootPath)
        let rootStat = access.lstat(tree.rootPath)
        // A scan root that is a link was followed by the scan, so the volume rule
        // compares against the target's device, not the link's.
        let rootDeviceStat = rootStat.isSymlink ? access.statFollowing(tree.rootPath) : rootStat

        var keys: Set<FileKey> = []
        var paths: [String] = []
        for url in policy.excludedPaths {
            let resolved = access.resolvedPath(url.path)
            // The scanned location wins over its own exclusion and over an
            // exclusion that contains it, exactly as the traversal applies it.
            guard !Self.isAtOrAbove(resolved, root: resolvedRoot) else { continue }
            let stat = access.lstat(resolved)
            guard stat.error == 0 else { continue }
            keys.insert(FileKey(dev: stat.dev, ino: stat.ino))
            if stat.isSymlink {
                let target = access.statFollowing(resolved)
                if target.error == 0 {
                    keys.insert(FileKey(dev: target.dev, ino: target.ino))
                }
            }
            paths.append(resolved)
        }

        self.tree = tree
        self.policy = policy
        self.engine = engine ?? FileScanEngine()
        self.reader = DirectoryReader()
        self.access = access
        self.rootDevice = rootDeviceStat.error == 0 ? rootDeviceStat.dev : nil
        self.excludedKeys = keys
        self.excludedPaths = paths
        self.maxFoldersPerBatch = max(1, maxFoldersPerBatch)
        self.maxSubtreeScansPerBatch = max(0, maxSubtreeScansPerBatch)
    }

    /// Reconciles the folders a watcher reported, in one batch.
    ///
    /// One pass runs at a time. A pass can suspend while it measures a folder
    /// that arrived, and the actor is reentrant across that await; a second
    /// caller's folders are therefore returned as deferred work rather than
    /// letting two passes measure and edit the tree at once (the engine that
    /// measures a subtree has one slot).
    @discardableResult
    public func apply(changedFolders folders: [String]) async -> Batch {
        guard !isApplying else {
            return Batch(
                changed: false,
                applied: 0,
                ignored: 0,
                folders: 0,
                deferred: folders
            )
        }
        isApplying = true
        defer { isApplying = false }

        subtreeScans = 0
        var edits: [LiveTree.Edit] = []
        var deferred: [String] = []
        var reconciled = 0

        for path in Self.outermost(folders.map(LiveTree.lexicalPath)) {
            guard reconciled < maxFoldersPerBatch else {
                deferred.append(path)
                continue
            }
            reconciled += 1
            switch await reconcile(folder: path) {
            case .edits(let folderEdits):
                edits.append(contentsOf: folderEdits)
            case .deferred:
                deferred.append(path)
            }
        }

        let report = tree.apply(edits)
        return Batch(
            changed: report.changed,
            applied: report.applied,
            ignored: report.ignored,
            folders: reconciled,
            deferred: deferred
        )
    }

    /// A batch that names a folder and something inside it only needs the folder:
    /// listing it answers both.
    static func outermost(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for path in paths where seen.insert(path).inserted {
            unique.append(path)
        }
        let set = Set(unique)
        return unique.filter { path in
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if set.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return !(set.contains("/") && path != "/")
        }
    }

    // MARK: - One folder

    private func reconcile(folder path: String) async -> Reconcile {
        guard let folderID = tree.id(atPath: path),
              let folder = tree.entry(for: folderID),
              folder.kind == .directory else {
            return .edits([])
        }

        let folderStat = access.lstat(path)
        if folderStat.error != 0 {
            // The folder this batch names is gone. Its parent's listing removes
            // it; the root cannot be removed, so it is reported as missing.
            if folderID == LiveTree.rootID {
                return .edits([
                    .touch(
                        id: folderID,
                        modifiedAt: folder.modifiedAt,
                        isAccessible: false,
                        errorMessage: ScanErrorClassifier.message(for: folderStat.error)
                    ),
                ])
            }
            return .edits([.remove(id: folderID)])
        }

        let entries: [DirectoryEntry]
        do {
            entries = try reader.read(path: path)
        } catch {
            let code = (error as? POSIXError)?.code.rawValue ?? EIO
            return .edits([
                .touch(
                    id: folderID,
                    modifiedAt: folderStat.modifiedAt,
                    isAccessible: false,
                    errorMessage: ScanErrorClassifier.message(for: code)
                ),
            ])
        }

        let current = Dictionary(
            tree.children(of: folderID).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var edits: [LiveTree.Edit] = []
        var seen = Set<String>()
        var deniedChild = false

        for entry in entries {
            if !policy.includeHidden && entry.name.hasPrefix(".") { continue }
            if entry.stat.error != 0 {
                deniedChild = true
                continue
            }

            let childPath = Self.joined(path, entry.name)
            if isExcluded(path: childPath, stat: entry.stat) { continue }
            if entry.stat.isSymlink, policy.followSymlinks, isExcludedSymlink(path: childPath) { continue }
            if isOnAnotherVolume(path: childPath, stat: entry.stat) { continue }

            seen.insert(entry.name)
            let existing = current[entry.name]

            if entry.stat.isDirectory {
                if let existing, existing.kind == .directory, existing.isSymlink == entry.stat.isSymlink {
                    edits.append(.touch(
                        id: existing.id,
                        modifiedAt: entry.stat.modifiedAt,
                        isAccessible: true,
                        errorMessage: nil
                    ))
                } else {
                    guard subtreeScans < maxSubtreeScansPerBatch else { return .deferred }
                    subtreeScans += 1
                    // Measure before touching the tree: a folder whose subtree
                    // cannot be measured leaves whatever the tree already holds,
                    // rather than deleting an entry it cannot replace.
                    guard let measured = await measure(childPath) else { continue }
                    if let existing { edits.append(.remove(id: existing.id)) }
                    edits.append(.insertNew(parent: folderID, node: measured))
                }
            } else if entry.stat.isRegularFile {
                let category = FileCategorizer.category(name: entry.name, isDirectory: false)
                if let existing, existing.kind == .file, !existing.isSymlink {
                    if existing.logicalSize != entry.stat.size
                        || existing.allocatedSize != entry.stat.allocatedSize
                        || existing.modifiedAt != entry.stat.modifiedAt
                        || existing.category != category {
                        edits.append(.updateFile(
                            id: existing.id,
                            logicalSize: entry.stat.size,
                            allocatedSize: entry.stat.allocatedSize,
                            modifiedAt: entry.stat.modifiedAt,
                            category: category
                        ))
                    }
                } else {
                    if let existing { edits.append(.remove(id: existing.id)) }
                    edits.append(.insertNew(
                        parent: folderID,
                        node: Self.fileNode(name: entry.name, path: childPath, stat: entry.stat)
                    ))
                }
            } else if entry.stat.isSymlink {
                if policy.followSymlinks {
                    guard subtreeScans < maxSubtreeScansPerBatch else { return .deferred }
                    subtreeScans += 1
                    guard let measured = await measure(childPath) else { continue }
                    edits.append(contentsOf: Self.edits(replacing: existing, with: measured, parent: folderID))
                } else if let existing, existing.kind == .file, existing.isSymlink, existing.fileCount == 0 {
                    // A link the scan did not follow: a zero-sized leaf whose
                    // only measured fact that can change is its own timestamp.
                    if existing.modifiedAt != entry.stat.modifiedAt {
                        edits.append(.touch(
                            id: existing.id,
                            modifiedAt: entry.stat.modifiedAt,
                            isAccessible: true,
                            errorMessage: nil
                        ))
                    }
                } else {
                    if let existing { edits.append(.remove(id: existing.id)) }
                    edits.append(.insertNew(
                        parent: folderID,
                        node: Self.symlinkLeaf(name: entry.name, path: childPath, stat: entry.stat)
                    ))
                }
            }
            // A special entry (device, FIFO, socket) is skipped, as the scan skips it.
        }

        for (name, child) in current where !seen.contains(name) {
            edits.append(.remove(id: child.id))
        }

        // The folder's own timestamp and access, from the one `lstat` this
        // reconciliation paid: a child that could not be read marks it denied,
        // exactly as the scan would.
        edits.append(.touch(
            id: folderID,
            modifiedAt: folderStat.modifiedAt,
            isAccessible: !deniedChild,
            errorMessage: deniedChild ? ScanErrorClassifier.message(for: EACCES) : nil
        ))
        return .edits(edits)
    }

    // MARK: - Measuring what arrived

    /// Measures one entry with the engine, under the tree's own rules.
    private func measure(_ path: String) async -> ScanNode? {
        let request = ScanRequest(
            root: URL(fileURLWithPath: path),
            followSymlinks: policy.followSymlinks,
            stayOnVolume: policy.stayOnVolume,
            includeHidden: policy.includeHidden,
            excludedPaths: policy.excludedPaths
        )
        var summary: ScanSummary?
        for await event in engine.scan(request) {
            switch event {
            case .finished(let finished):
                summary = finished
            case .cancelled:
                return nil
            case .started, .progress, .issue, .partial:
                break
            }
        }
        guard let summary else { return nil }
        return Self.rootNode(of: summary)
    }

    /// The node a summary carries for its own root, whether the root turned out
    /// to be a folder or a single measured entry.
    static func rootNode(of summary: ScanSummary) -> ScanNode? {
        let rootPath = LiveTree.lexicalPath(summary.root.path)
        return (summary.largestDirectories + summary.largestFiles)
            .first { LiveTree.lexicalPath($0.url.path) == rootPath }
    }

    // MARK: - Scope rules

    private func isExcluded(path: String, stat: FileStat) -> Bool {
        guard !excludedKeys.isEmpty else { return false }
        guard excludedKeys.contains(FileKey(dev: stat.dev, ino: stat.ino)) else { return false }
        return matchesExcludedPath(path)
    }

    private func isExcludedSymlink(path: String) -> Bool {
        guard !excludedKeys.isEmpty else { return false }
        let target = access.statFollowing(path)
        guard target.error == 0,
              excludedKeys.contains(FileKey(dev: target.dev, ino: target.ino)) else {
            return false
        }
        return matchesExcludedPath(path)
    }

    private func matchesExcludedPath(_ path: String) -> Bool {
        let resolved = access.resolvedPath(path)
        return excludedPaths.contains(resolved)
            || excludedPaths.contains { resolved.hasPrefix($0 + "/") }
    }

    private func isOnAnotherVolume(path: String, stat: FileStat) -> Bool {
        guard policy.stayOnVolume, let rootDevice else { return false }
        // A bulk read reports the *underlying* volume's device for a mount
        // point, so a mount point's own device has to be read directly.
        let mounted = stat.isMountPoint ? access.lstat(path) : stat
        return mounted.dev != rootDevice
    }

    private static func isAtOrAbove(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return root.hasPrefix(prefix)
    }

    private static func joined(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    // MARK: - Nodes the scan would have produced

    private static func fileNode(name: String, path: String, stat: FileStat) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path, isDirectory: false),
            name: name,
            isDirectory: false,
            isSymlink: false,
            category: FileCategorizer.category(name: name, isDirectory: false),
            logicalSize: stat.size,
            allocatedSize: stat.allocatedSize,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: stat.modifiedAt,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }

    private static func symlinkLeaf(name: String, path: String, stat: FileStat) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path, isDirectory: false),
            name: name,
            isDirectory: false,
            isSymlink: true,
            category: .other,
            logicalSize: 0,
            allocatedSize: 0,
            fileCount: 0,
            directoryCount: 0,
            modifiedAt: stat.modifiedAt,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }

    /// The edits that make an existing entry match a measured one, keeping its
    /// identity when only a file's numbers changed.
    private static func edits(
        replacing existing: LiveEntry?,
        with node: ScanNode,
        parent: LiveNodeID
    ) -> [LiveTree.Edit] {
        guard let existing else {
            return [.insertNew(parent: parent, node: node)]
        }
        if node.isDirectory {
            if existing.kind == .directory {
                return [
                    .touch(
                        id: existing.id,
                        modifiedAt: node.modifiedAt,
                        isAccessible: node.isAccessible,
                        errorMessage: node.errorMessage
                    ),
                ]
            }
            return [.remove(id: existing.id), .insertNew(parent: parent, node: node)]
        }

        let sameShape = existing.isSymlink == node.isSymlink
            && existing.logicalSize == node.logicalSize
            && existing.allocatedSize == node.allocatedSize
            && existing.fileCount == node.fileCount
            && existing.category == node.category
            && existing.modifiedAt == node.modifiedAt
        if sameShape { return [] }

        if !node.isSymlink, !existing.isSymlink, existing.kind == .file {
            return [
                .updateFile(
                    id: existing.id,
                    logicalSize: node.logicalSize,
                    allocatedSize: node.allocatedSize,
                    modifiedAt: node.modifiedAt,
                    category: node.category
                ),
            ]
        }
        return [.remove(id: existing.id), .insertNew(parent: parent, node: node)]
    }
}
