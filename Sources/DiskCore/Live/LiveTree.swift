import Foundation

/// The tree the results screen reads: one compact arena of measured entries that
/// filesystem changes are applied to in place.
///
/// A value snapshot taken at the end of a scan cannot be edited, so a settled
/// screen can only go stale: macOS writes continuously, and the honest answers
/// from a snapshot are a growing "changed" badge or a full re-scan. Here an edit
/// is applied where it happened and its difference is walked up the parent
/// chain, so one changed file costs the depth of the tree, not the size of the
/// disk.
///
/// Entries carry the numbers `ScanNode` reports; `scanNode(for:depth:)`
/// materializes that frozen type for the surfaces that still need it. Storage is
/// 56 bytes per entry plus its name, in one append-only UTF-8 blob.
///
/// Reads and writes share one lock. Writes are applied off the main actor, in
/// batches, and a batch that changes anything bumps `revision` once. A reader
/// always sees a subtree aggregate that agrees with its children.
///
/// See `docs/LIVE-TREE.md` for the model, its invariants, and the migration.
public final class LiveTree: @unchecked Sendable {
    /// The scanned root. It always exists and is never removed or moved.
    public static let rootID = LiveNodeID(index: 0, generation: 0)

    private static let none = UInt32.max
    private static let accessible: UInt8 = 1
    private static let symlink: UInt8 = 2
    private static let categories = FileCategory.allCases

    /// One entry: 56 bytes, laid out so the hot fields share a cache line.
    private struct Storage {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var modified: Double = 0
        var parent: UInt32 = LiveTree.none
        var firstChild: UInt32 = LiveTree.none
        var nextSibling: UInt32 = LiveTree.none
        var nameStart: UInt32 = 0
        var files: UInt32 = 0
        var dirs: UInt32 = 0
        var generation: UInt16 = 0
        var nameLength: UInt16 = 0
        var kind: UInt8 = LiveNodeKind.file.rawValue
        var flags: UInt8 = LiveTree.accessible
        var category: UInt8 = 0
    }

    private let lock = NSLock()
    private let rootURL: URL
    /// The root's path as `realpath(3)` spells it.
    ///
    /// FSEvents names the real path — `/private/var/…` — while a scan started at
    /// a path that reaches the same folder through a link keeps `/var/…`. A
    /// watcher's folder is rewritten through this so it finds the tree's own
    /// entries rather than nothing.
    private let resolvedRootPath: String
    /// Makes `ScanNode` ids deterministic per tree, so materializing an entry
    /// twice yields the same identity and a redraw never resets a row.
    private let uuidSalt: UUID

    private var storage: [Storage] = []
    private var names: [UInt8] = []
    private var freeSlots: [UInt32] = []
    private var liveCount = 0
    private var categoryTotals: [Int64] = Array(repeating: 0, count: FileCategory.allCases.count)
    private var errors: [LiveNodeID: String] = [:]
    /// How many folders in each folder's subtree could not be read, the folder
    /// itself included. Only folders with a non-zero count are stored, so a clean
    /// tree pays nothing for this and a scan with a few denied locations pays for
    /// their ancestor chains.
    private var unreadableCounts: [LiveNodeID: Int] = [:]
    private var revisionValue = 0

    // MARK: - Creation

    /// An empty tree rooted at `rootName`.
    public init(rootName: String, rootURL: URL, isSymlink: Bool = false) {
        let rootPath = Self.lexicalPath(rootURL.path)
        self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        self.resolvedRootPath = Self.canonicalPath(rootPath)
        self.uuidSalt = UUID()

        var blob: [UInt8] = []
        let span = Self.appendName(rootName, to: &blob)
        var root = Storage()
        root.kind = LiveNodeKind.directory.rawValue
        root.dirs = 1
        root.category = Self.categoryIndex(FileCategorizer.category(name: rootName, isDirectory: true))
        if isSymlink { root.flags |= Self.symlink }
        root.nameStart = span.start
        root.nameLength = span.length
        self.names = blob
        self.storage = [root]
        self.liveCount = 1
    }

    /// A tree built from a finished scan, whose root node carries every measured
    /// entry under it.
    ///
    /// Returns `nil` when the summary does not carry a complete root — a partial
    /// snapshot, or one built with different options — because a live tree that
    /// silently held half a scan would report numbers the scan never measured.
    init(rootNode: ScanNode, rootURL: URL) {
        let rootPath = Self.lexicalPath(rootURL.path)
        self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        self.resolvedRootPath = Self.canonicalPath(rootPath)
        self.uuidSalt = UUID()

        var blob: [UInt8] = []
        let span = Self.appendName(rootNode.name, to: &blob)
        var root = Storage()
        root.kind = LiveNodeKind.directory.rawValue
        root.dirs = 1
        root.modified = rootNode.modifiedAt?.timeIntervalSince1970 ?? 0
        root.flags = rootNode.isAccessible ? Self.accessible : 0
        if rootNode.isSymlink { root.flags |= Self.symlink }
        root.category = Self.categoryIndex(rootNode.category)
        root.nameStart = span.start
        root.nameLength = span.length
        // A finished scan knows how many entries it holds; reserving once keeps
        // the build from copying a multi-hundred-megabyte array as it grows.
        self.names = blob
        self.storage = [root]
        self.storage.reserveCapacity(rootNode.fileCount + rootNode.directoryCount + 1)
        self.liveCount = 1
        if let error = rootNode.errorMessage { errors[Self.rootID] = error }
        if !rootNode.isAccessible { unreadableCounts[Self.rootID] = 1 }

        for child in rootNode.children {
            let childSlot = appendSubtree(child, parent: 0)
            addLocked(
                from: 0,
                logical: child.logicalSize,
                allocated: child.allocatedSize,
                files: child.fileCount,
                dirs: child.directoryCount
            )
            addUnreadableCountLocked(from: 0, by: unreadableCountLocked(childSlot))
        }
    }

    // MARK: - Reading

    /// Bumped once per batch that changed anything, so a screen can key derived
    /// work on it without looking at the tree.
    public var revision: Int { lock.withLock { revisionValue } }

    /// Entries in the tree, root included.
    public var nodeCount: Int { lock.withLock { liveCount } }

    public var rootPath: String { rootURL.path }

    /// Bytes counted under the root; every entry's own numbers sum to this.
    public var totalLogicalSize: Int64 { lock.withLock { storage[0].logical } }
    public var totalAllocatedSize: Int64 { lock.withLock { storage[0].allocated } }
    public var fileCount: Int { lock.withLock { Int(storage[0].files) } }
    /// Directories in the tree, the root included — the scan's own rule.
    public var directoryCount: Int { lock.withLock { Int(storage[0].dirs) } }

    /// Bytes by category, over the files the tree holds. Directories carry no
    /// bytes into the breakdown, exactly as the scan reports it.
    public func categorySizes() -> [FileCategory: Int64] {
        lock.withLock {
            var result: [FileCategory: Int64] = [:]
            for (index, size) in categoryTotals.enumerated() where size != 0 {
                result[Self.categories[index]] = size
            }
            return result
        }
    }

    public func entry(for id: LiveNodeID) -> LiveEntry? {
        lock.withLock { entryLocked(id) }
    }

    /// How many folders in this entry's subtree could not be read, the entry
    /// itself included when it is a folder that could not be read. A file has no
    /// count.
    ///
    /// The count is maintained with the tree's edits, so a folder shows what is
    /// missing inside it even after the disk changes, without walking the
    /// subtree on a screen.
    public func unreadableFolderCount(for id: LiveNodeID) -> Int {
        lock.withLock {
            guard isLiveLocked(id) else { return 0 }
            return unreadableCountLocked(id.index)
        }
    }

    /// The same count for a path the tree holds, or `nil` when it holds none.
    public func unreadableFolderCount(atPath path: String) -> Int? {
        guard let id = id(atPath: path) else { return nil }
        return unreadableFolderCount(for: id)
    }

    /// The entries of a folder, in no particular order: every screen sorts what
    /// it draws.
    public func children(of id: LiveNodeID) -> [LiveEntry] {
        lock.withLock {
            guard isLiveLocked(id) else { return [] }
            var result: [LiveEntry] = []
            var slot = storage[Int(id.index)].firstChild
            while slot != Self.none {
                if let entry = entryLocked(Self.id(for: slot, in: storage)) {
                    result.append(entry)
                }
                slot = storage[Int(slot)].nextSibling
            }
            return result
        }
    }

    public func child(named name: String, of parent: LiveNodeID) -> LiveNodeID? {
        lock.withLock {
            guard isLiveLocked(parent), let slot = childSlotLocked(named: name, of: parent.index) else {
                return nil
            }
            return Self.id(for: slot, in: storage)
        }
    }

    /// The entry at an absolute path, or `nil` when the path is outside the root
    /// or names nothing the tree holds.
    public func id(atPath path: String) -> LiveNodeID? {
        var standardized = Self.lexicalPath(path)
        let root = rootURL.path
        if standardized != root, !standardized.hasPrefix(root == "/" ? "/" : root + "/"),
           resolvedRootPath != root {
            // The path reaches the root through a different spelling — FSEvents
            // reports the resolved one — so rewrite the root so the components
            // are the tree's own.
            if standardized == resolvedRootPath {
                standardized = root
            } else if standardized.hasPrefix(resolvedRootPath + "/") {
                let rest = standardized.dropFirst(resolvedRootPath.count)
                standardized = root == "/" ? String(rest) : root + rest
            }
        }
        guard standardized == root || standardized.hasPrefix(root == "/" ? "/" : root + "/") else {
            return nil
        }
        return lock.withLock { () -> LiveNodeID? in
            guard standardized != root else { return Self.rootID }
            let start = root == "/" ? 1 : root.count + 1
            var current = Self.rootID
            for component in standardized.dropFirst(start).split(separator: "/") {
                guard let slot = childSlotLocked(named: String(component), of: current.index) else {
                    return nil
                }
                current = Self.id(for: slot, in: storage)
            }
            return current
        }
    }

    public func path(of id: LiveNodeID) -> String? {
        lock.withLock {
            guard isLiveLocked(id) else { return nil }
            return pathLocked(id.index)
        }
    }

    public func url(of id: LiveNodeID) -> URL? {
        lock.withLock {
            guard isLiveLocked(id) else { return nil }
            let isDirectory = storage[Int(id.index)].kind == LiveNodeKind.directory.rawValue
            return URL(fileURLWithPath: pathLocked(id.index), isDirectory: isDirectory)
        }
    }

    /// The frozen `ScanNode` for one entry, with `depth` levels of children.
    ///
    /// Its id is derived from the entry's, so materializing the same entry twice
    /// yields the same identity.
    public func scanNode(for id: LiveNodeID, depth: Int = 0) -> ScanNode? {
        lock.withLock { scanNodeLocked(id, depth: depth) }
    }

    /// The frozen nodes for a folder's children, materialized under one lock.
    public func scanNodes(forChildrenOf id: LiveNodeID, depth: Int = 0) -> [ScanNode]? {
        lock.withLock {
            guard isLiveLocked(id) else { return nil }
            var result: [ScanNode] = []
            var slot = storage[Int(id.index)].firstChild
            while slot != Self.none {
                if let node = scanNodeLocked(Self.id(for: slot, in: storage), depth: depth) {
                    result.append(node)
                }
                slot = storage[Int(slot)].nextSibling
            }
            return result
        }
    }

    /// The frozen node at an absolute path.
    public func scanNode(atPath path: String, depth: Int = 0) -> ScanNode? {
        guard let id = id(atPath: path) else { return nil }
        return scanNode(for: id, depth: depth)
    }

    /// How a walk treats the entry it was just handed.
    public enum WalkStep: Sendable {
        /// Report the entry's children too.
        case descend
        /// Report the entry, then stay out of its subtree.
        case skipChildren
        /// End the walk.
        case stop
    }

    /// The measured facts of one entry, without its name.
    ///
    /// A walk that only ranks or totals entries does not need names, and decoding
    /// millions of them is most of a walk's cost. `LiveTree.walk` hands out a full
    /// entry when the walk needs to match names.
    public struct NodeFacts: Sendable, Hashable {
        public let id: LiveNodeID
        public let kind: LiveNodeKind
        public let isSymlink: Bool
        public let category: FileCategory
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public let fileCount: Int
        public let directoryCount: Int
        public let modifiedAt: Date?
    }

    /// Depth-first walk over the entries below `start`, one folder at a time,
    /// without decoding names.
    ///
    /// The same concurrency rules as `walk(from:_:)`: the lock is taken per
    /// folder, and the visitor runs outside it.
    @discardableResult
    public func walkNodes(
        from start: LiveNodeID = LiveTree.rootID,
        _ visit: (NodeFacts) -> WalkStep
    ) -> Int {
        var visited = 0
        var folders: [LiveNodeID] = [start]
        while let folder = folders.popLast() {
            let facts: [NodeFacts] = lock.withLock {
                guard isLiveLocked(folder) else { return [] }
                var result: [NodeFacts] = []
                var slot = storage[Int(folder.index)].firstChild
                while slot != Self.none {
                    result.append(factsLocked(slot))
                    slot = storage[Int(slot)].nextSibling
                }
                return result
            }
            for fact in facts {
                visited += 1
                switch visit(fact) {
                case .stop:
                    return visited
                case .skipChildren:
                    continue
                case .descend:
                    if fact.kind == .directory {
                        folders.append(fact.id)
                    }
                }
            }
        }
        return visited
    }

    private func factsLocked(_ slot: UInt32) -> NodeFacts {
        let node = storage[Int(slot)]
        return NodeFacts(
            id: Self.id(for: slot, in: storage),
            kind: LiveNodeKind(rawValue: node.kind) ?? .file,
            isSymlink: node.flags & Self.symlink != 0,
            category: Self.categories[Int(node.category)],
            logicalSize: node.logical,
            allocatedSize: node.allocated,
            fileCount: Int(node.files),
            directoryCount: Int(node.dirs),
            modifiedAt: node.modified == 0 ? nil : Date(timeIntervalSince1970: node.modified)
        )
    }

    /// Depth-first walk over the entries below `start`, one folder at a time.
    ///
    /// The tree takes its lock per folder, never across the walk, so a screen can
    /// keep reading and a watcher can keep editing while a long walk runs. That
    /// also means the walk is not a snapshot: a folder that changes while it runs
    /// is seen before or after that edit, and every entry it reports was measured
    /// either way. Returns how many entries it visited.
    @discardableResult
    public func walk(
        from start: LiveNodeID = LiveTree.rootID,
        _ visit: (LiveEntry) -> WalkStep
    ) -> Int {
        var visited = 0
        var folders: [LiveNodeID] = [start]
        while let folder = folders.popLast() {
            for entry in children(of: folder) {
                visited += 1
                switch visit(entry) {
                case .stop:
                    return visited
                case .skipChildren:
                    continue
                case .descend:
                    if entry.kind == .directory {
                        folders.append(entry.id)
                    }
                }
            }
        }
        return visited
    }

    // MARK: - Building during a walk

    /// Inserts one folder's whole listing and returns each node's id in the order
    /// given; a node the tree refused (an empty name) gets `nil`.
    ///
    /// The scan engine builds the tree while it walks, so a screen never converts
    /// a finished summary into one. A directory listing names each entry once, so
    /// this never looks for an existing entry of the same name — which would scan
    /// (and decode) every sibling already inserted, and make a wide folder
    /// quadratic. One lock and one ancestor walk carry the whole listing: a
    /// directory's entries share the same ancestors, so their difference is a sum,
    /// and the per-entry cost stays a storage append and a link.
    ///
    /// A listing is published as one group under one lock, so a screen reading
    /// the folder between the listing and the walk of its subfolders never sees
    /// half of it. The charts colour siblings by rank, and a group that arrives
    /// in pieces moves the colours already on screen.
    @discardableResult
    func insertDiscoveredGroup(_ nodes: [ScanNode], under parent: LiveNodeID) -> [LiveNodeID?] {
        guard !nodes.isEmpty else { return [] }
        return lock.withLock {
            guard isLiveLocked(parent), isDirectoryLocked(parent.index) else {
                return Array(repeating: nil, count: nodes.count)
            }
            var ids: [LiveNodeID?] = []
            ids.reserveCapacity(nodes.count)
            var logical: Int64 = 0
            var allocated: Int64 = 0
            var files = 0
            var dirs = 0
            var unreadable = 0
            for node in nodes {
                guard !node.name.isEmpty else {
                    ids.append(nil)
                    continue
                }
                let slot = appendSubtree(node, parent: parent.index)
                ids.append(Self.id(for: slot, in: storage))
                logical += node.logicalSize
                allocated += node.allocatedSize
                files += node.fileCount
                dirs += node.directoryCount
                unreadable += unreadableCountLocked(slot)
            }
            addLocked(from: parent.index, logical: logical, allocated: allocated, files: files, dirs: dirs)
            addUnreadableCountLocked(from: parent.index, by: unreadable)
            return ids
        }
    }

    /// Records what the walk learned about a folder's own metadata.
    func recordDirectoryMetadata(
        id: LiveNodeID,
        modifiedAt: Date?,
        isAccessible: Bool,
        errorMessage: String?
    ) {
        apply([
            .touch(id: id, modifiedAt: modifiedAt, isAccessible: isAccessible, errorMessage: errorMessage),
        ])
    }

    /// Whether the tree the walk built agrees with the summary it produced.
    ///
    /// The engine only hands a tree to a screen when this holds, so a screen never
    /// shows a tree that disagrees with the record the same scan wrote.
    func matches(_ summary: ScanSummary) -> Bool {
        let totals = lock.withLock { () -> (Int, Int, Int64, Int64) in
            let node = storage[0]
            return (Int(node.files), Int(node.dirs), node.logical, node.allocated)
        }
        guard totals.0 == summary.fileCount,
              totals.1 == summary.directoryCount,
              totals.2 == summary.totalLogicalSize,
              totals.3 == summary.totalAllocatedSize else {
            return false
        }
        let expected = summary.categoryBreakdown.filter { $0.value != 0 }
        return categorySizes() == expected
    }

    // MARK: - Editing

    /// One measured change to apply.
    public enum Edit: Sendable {
        /// A measured subtree arrived: a file, or a folder with everything under
        /// it. The node's own aggregates are the difference applied to its
        /// ancestors. A child of the same name is replaced.
        case insert(parent: LiveNodeID, node: ScanNode)
        /// The same insert when the caller knows the folder holds no entry of
        /// that name — a re-listing that just diffed the names. Without that
        /// promise the insert would scan every sibling, which makes a listing
        /// that adds many entries to one folder quadratic.
        case insertNew(parent: LiveNodeID, node: ScanNode)
        /// A file's bytes changed.
        case updateFile(
            id: LiveNodeID,
            logicalSize: Int64,
            allocatedSize: Int64,
            modifiedAt: Date?,
            category: FileCategory
        )
        /// What a re-listing reports about an entry that stayed the same size.
        case touch(id: LiveNodeID, modifiedAt: Date?, isAccessible: Bool, errorMessage: String?)
        /// A rename, or a move between folders: identity and measured subtree
        /// travel with the entry.
        case move(id: LiveNodeID, toParent: LiveNodeID, name: String)
        /// An entry and everything under it went away.
        case remove(id: LiveNodeID)
    }

    /// What a batch did. `ignored` counts edits that named an entry or parent the
    /// tree no longer held — a file reported inside a folder that was deleted
    /// earlier in the same batch, for instance.
    public struct ApplyReport: Sendable, Equatable {
        public let changed: Bool
        public let applied: Int
        public let ignored: Int
    }

    /// Applies a batch of edits under one lock and bumps `revision` once if
    /// anything changed.
    @discardableResult
    public func apply(_ edits: [Edit]) -> ApplyReport {
        lock.withLock {
            var state = MutationState()
            for edit in edits {
                switch edit {
                case let .insert(parent, node):
                    insertLocked(parent: parent, node: node, replacing: true, state: &state)
                case let .insertNew(parent, node):
                    insertLocked(parent: parent, node: node, replacing: false, state: &state)
                case let .updateFile(id, logical, allocated, modified, category):
                    updateFileLocked(
                        id: id, logicalSize: logical, allocatedSize: allocated,
                        modifiedAt: modified, category: category, state: &state
                    )
                case let .touch(id, modified, accessible, error):
                    touchLocked(id: id, modifiedAt: modified, isAccessible: accessible, errorMessage: error, state: &state)
                case let .move(id, parent, name):
                    moveLocked(id, toParent: parent, name: name, state: &state)
                case let .remove(id):
                    removeLocked(id, state: &state)
                }
            }
            if state.changed { revisionValue &+= 1 }
            return ApplyReport(changed: state.changed, applied: state.applied, ignored: state.ignored)
        }
    }

    // MARK: - Storage

    private struct MutationState {
        var changed = false
        var applied = 0
        var ignored = 0
    }

    private static func id(for slot: UInt32, in storage: [Storage]) -> LiveNodeID {
        LiveNodeID(index: slot, generation: storage[Int(slot)].generation)
    }

    /// A path with its links resolved, as `realpath(3)` spells it. A path that
    /// does not exist cannot be resolved; its lexical spelling is the answer.
    static func canonicalPath(_ path: String) -> String {
        var result = path
        if let resolved = path.withCString({ realpath($0, nil) }) {
            result = String(cString: resolved)
            free(resolved)
        }
        return result
    }

    /// A path normalized without asking the filesystem: `.` and `..` collapse,
    /// repeated and trailing slashes go, and symbolic links keep the spelling the
    /// scan gave them.
    ///
    /// `URL.standardizedFileURL` and `NSString.standardizingPath` both resolve
    /// links — `/private/var` comes back as `/var` — which would make every entry
    /// under a link spell itself differently from the tree and from Finder.
    static func lexicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if path.hasPrefix("/") { return "/" + joined }
        return joined
    }

    private static func appendName(_ name: String, to blob: inout [UInt8]) -> (start: UInt32, length: UInt16) {
        let bytes = Array(name.utf8)
        precondition(bytes.count <= Int(UInt16.max), "an entry name longer than this arena holds")
        let start = blob.count
        blob.append(contentsOf: bytes)
        return (UInt32(start), UInt16(bytes.count))
    }

    private static let categoryIndices: [FileCategory: UInt8] = {
        var indices: [FileCategory: UInt8] = [:]
        for (index, category) in categories.enumerated() {
            indices[category] = UInt8(index)
        }
        return indices
    }()

    private static func categoryIndex(_ category: FileCategory) -> UInt8 {
        categoryIndices[category] ?? 0
    }

    private static func kind(of node: ScanNode) -> LiveNodeKind {
        node.isDirectory ? .directory : .file
    }

    private func nameLocked(_ node: Storage) -> String {
        let start = Int(node.nameStart)
        let end = start + Int(node.nameLength)
        return String(decoding: names[start..<end], as: UTF8.self)
    }

    private func isLiveLocked(_ id: LiveNodeID) -> Bool {
        let slot = Int(id.index)
        guard slot < storage.count else { return false }
        guard storage[slot].generation == id.generation else { return false }
        return slot == 0 || storage[slot].parent != Self.none
    }

    private func isDirectoryLocked(_ slot: UInt32) -> Bool {
        storage[Int(slot)].kind == LiveNodeKind.directory.rawValue
    }

    private func isLeafLocked(_ slot: UInt32) -> Bool {
        storage[Int(slot)].kind != LiveNodeKind.directory.rawValue
    }

    private func entryLocked(_ id: LiveNodeID) -> LiveEntry? {
        guard isLiveLocked(id) else { return nil }
        let node = storage[Int(id.index)]
        return LiveEntry(
            id: id,
            parent: node.parent == Self.none ? nil : Self.id(for: node.parent, in: storage),
            name: nameLocked(node),
            kind: LiveNodeKind(rawValue: node.kind) ?? .file,
            isSymlink: node.flags & Self.symlink != 0,
            category: Self.categories[Int(node.category)],
            logicalSize: node.logical,
            allocatedSize: node.allocated,
            fileCount: Int(node.files),
            directoryCount: Int(node.dirs),
            modifiedAt: node.modified == 0 ? nil : Date(timeIntervalSince1970: node.modified),
            isAccessible: node.flags & Self.accessible != 0,
            errorMessage: errors[id]
        )
    }

    private func childSlotLocked(named name: String, of parent: UInt32) -> UInt32? {
        var slot = storage[Int(parent)].firstChild
        while slot != Self.none {
            if nameLocked(storage[Int(slot)]) == name { return slot }
            slot = storage[Int(slot)].nextSibling
        }
        return nil
    }

    private func pathLocked(_ slot: UInt32) -> String {
        var parts: [String] = []
        var current = slot
        while current != 0 {
            parts.append(nameLocked(storage[Int(current)]))
            current = storage[Int(current)].parent
        }
        guard !parts.isEmpty else { return rootURL.path }
        parts.reverse()
        let joined = parts.joined(separator: "/")
        return rootURL.path == "/" ? "/" + joined : rootURL.path + "/" + joined
    }

    private func scanNodeLocked(_ id: LiveNodeID, depth: Int) -> ScanNode? {
        guard isLiveLocked(id) else { return nil }
        let slot = id.index
        let node = storage[Int(slot)]
        var children: [ScanNode] = []
        if depth > 0, node.kind == LiveNodeKind.directory.rawValue {
            var child = node.firstChild
            while child != Self.none {
                let childID = Self.id(for: child, in: storage)
                if let materialized = scanNodeLocked(childID, depth: depth - 1) {
                    children.append(materialized)
                }
                child = storage[Int(child)].nextSibling
            }
            children.sort {
                $0.logicalSize == $1.logicalSize ? $0.name < $1.name : $0.logicalSize > $1.logicalSize
            }
        }
        return ScanNode(
            id: uuidLocked(id),
            url: URL(fileURLWithPath: pathLocked(slot), isDirectory: node.kind == LiveNodeKind.directory.rawValue),
            name: nameLocked(node),
            isDirectory: node.kind == LiveNodeKind.directory.rawValue,
            isSymlink: node.flags & Self.symlink != 0,
            category: Self.categories[Int(node.category)],
            logicalSize: node.logical,
            allocatedSize: node.allocated,
            fileCount: Int(node.files),
            directoryCount: Int(node.dirs),
            modifiedAt: node.modified == 0 ? nil : Date(timeIntervalSince1970: node.modified),
            isAccessible: node.flags & Self.accessible != 0,
            errorMessage: errors[id],
            children: children
        )
    }

    private func uuidLocked(_ id: LiveNodeID) -> UUID {
        var raw = uuidSalt.uuid
        withUnsafeMutableBytes(of: &raw) { bytes in
            let index = id.index
            for offset in 0..<4 {
                bytes[offset] = UInt8(truncatingIfNeeded: index >> (offset * 8))
            }
            let generation = id.generation
            bytes[4] = UInt8(truncatingIfNeeded: generation)
            bytes[5] = UInt8(truncatingIfNeeded: generation >> 8)
        }
        return UUID(uuid: raw)
    }

    private func allocateLocked(
        kind: LiveNodeKind,
        name: String,
        category: FileCategory,
        logical: Int64,
        allocated: Int64,
        files: Int,
        dirs: Int,
        modified: Date?,
        accessible: Bool,
        isSymlink: Bool,
        error: String?
    ) -> UInt32 {
        var node = Storage()
        node.kind = kind.rawValue
        node.flags = accessible ? Self.accessible : 0
        if isSymlink { node.flags |= Self.symlink }
        node.category = Self.categoryIndex(category)
        node.logical = logical
        node.allocated = allocated
        node.files = UInt32(clamping: files)
        node.dirs = UInt32(clamping: dirs)
        node.modified = modified?.timeIntervalSince1970 ?? 0
        let span = Self.appendName(name, to: &names)
        node.nameStart = span.start
        node.nameLength = span.length

        let slot: UInt32
        if let reused = freeSlots.popLast() {
            node.generation = storage[Int(reused)].generation
            storage[Int(reused)] = node
            slot = reused
        } else {
            storage.append(node)
            slot = UInt32(storage.count - 1)
        }
        liveCount += 1
        if let error { errors[Self.id(for: slot, in: storage)] = error }
        return slot
    }

    /// Inserts a measured node and everything under it, without touching the
    /// ancestors' sums: the caller adds the entry's aggregate once.
    @discardableResult
    func appendSubtree(_ node: ScanNode, parent: UInt32) -> UInt32 {
        let kind = Self.kind(of: node)
        let slot = allocateLocked(
            kind: kind,
            name: node.name,
            category: node.category,
            logical: node.logicalSize,
            allocated: node.allocatedSize,
            files: node.fileCount,
            dirs: node.directoryCount,
            modified: node.modifiedAt,
            accessible: node.isAccessible,
            isSymlink: node.isSymlink,
            error: node.errorMessage
        )
        linkLocked(slot, to: parent)
        if kind == .file {
            categoryTotals[Int(Self.categoryIndex(node.category))] += node.logicalSize
        }
        var unreadable = (kind == .directory && !node.isAccessible) ? 1 : 0
        for child in node.children {
            let childSlot = appendSubtree(child, parent: slot)
            unreadable += unreadableCountLocked(childSlot)
        }
        if kind == .directory {
            setUnreadableCountLocked(slot, unreadable)
        }
        return slot
    }

    private func linkLocked(_ slot: UInt32, to parent: UInt32) {
        storage[Int(slot)].parent = parent
        storage[Int(slot)].nextSibling = storage[Int(parent)].firstChild
        storage[Int(parent)].firstChild = slot
    }

    private func unlinkLocked(_ slot: UInt32) {
        let parent = storage[Int(slot)].parent
        guard parent != Self.none else { return }
        if storage[Int(parent)].firstChild == slot {
            storage[Int(parent)].firstChild = storage[Int(slot)].nextSibling
        } else {
            var previous = storage[Int(parent)].firstChild
            while previous != Self.none && storage[Int(previous)].nextSibling != slot {
                previous = storage[Int(previous)].nextSibling
            }
            if previous != Self.none {
                storage[Int(previous)].nextSibling = storage[Int(slot)].nextSibling
            }
        }
        storage[Int(slot)].parent = Self.none
        storage[Int(slot)].nextSibling = Self.none
    }

    /// Adds a difference to a slot and every ancestor, root included.
    private func addLocked(from start: UInt32, logical: Int64, allocated: Int64, files: Int, dirs: Int) {
        var current = start
        while current != Self.none {
            storage[Int(current)].logical += logical
            storage[Int(current)].allocated += allocated
            storage[Int(current)].files = UInt32(clamping: Int64(storage[Int(current)].files) + Int64(files))
            storage[Int(current)].dirs = UInt32(clamping: Int64(storage[Int(current)].dirs) + Int64(dirs))
            current = storage[Int(current)].parent
        }
    }

    /// How many folders in this slot's subtree could not be read. Zero for a
    /// file; the entry itself counts when it is a folder that could not be read.
    private func unreadableCountLocked(_ slot: UInt32) -> Int {
        unreadableCounts[Self.id(for: slot, in: storage)] ?? 0
    }

    private func setUnreadableCountLocked(_ slot: UInt32, _ count: Int) {
        let key = Self.id(for: slot, in: storage)
        if count == 0 {
            unreadableCounts.removeValue(forKey: key)
        } else {
            unreadableCounts[key] = count
        }
    }

    /// Applies a difference to a slot and every ancestor, root included. The
    /// counter is additive, so a touch, an insert, a move, and a removal all
    /// reconcile without walking the subtree again.
    private func addUnreadableCountLocked(from start: UInt32, by delta: Int) {
        guard delta != 0 else { return }
        var current = start
        while current != Self.none {
            let key = Self.id(for: current, in: storage)
            setUnreadableCountLocked(current, max(0, (unreadableCounts[key] ?? 0) + delta))
            current = storage[Int(current)].parent
        }
    }

    // MARK: - Applying one edit

    private func insertLocked(
        parent: LiveNodeID,
        node: ScanNode,
        replacing: Bool,
        state: inout MutationState
    ) {
        guard isLiveLocked(parent), isDirectoryLocked(parent.index), !node.name.isEmpty else {
            state.ignored += 1
            return
        }
        if replacing, let existing = childSlotLocked(named: node.name, of: parent.index) {
            removeSlotLocked(existing)
        }
        let slot = appendSubtree(node, parent: parent.index)
        addLocked(
            from: parent.index,
            logical: node.logicalSize,
            allocated: node.allocatedSize,
            files: node.fileCount,
            dirs: node.directoryCount
        )
        addUnreadableCountLocked(from: parent.index, by: unreadableCountLocked(slot))
        state.changed = true
        state.applied += 1
    }

    private func updateFileLocked(
        id: LiveNodeID,
        logicalSize: Int64,
        allocatedSize: Int64,
        modifiedAt: Date?,
        category: FileCategory,
        state: inout MutationState
    ) {
        guard isLiveLocked(id), isLeafLocked(id.index) else {
            state.ignored += 1
            return
        }
        let slot = Int(id.index)
        let node = storage[slot]
        let newCategory = Self.categoryIndex(category)
        let newModified = modifiedAt?.timeIntervalSince1970 ?? 0
        state.applied += 1
        guard node.logical != logicalSize || node.allocated != allocatedSize
            || node.category != newCategory || node.modified != newModified else {
            return
        }

        addLocked(
            from: node.parent,
            logical: logicalSize - node.logical,
            allocated: allocatedSize - node.allocated,
            files: 0,
            dirs: 0
        )
        if node.category == newCategory {
            categoryTotals[Int(newCategory)] += logicalSize - node.logical
        } else {
            categoryTotals[Int(node.category)] -= node.logical
            categoryTotals[Int(newCategory)] += logicalSize
        }
        storage[slot].logical = logicalSize
        storage[slot].allocated = allocatedSize
        storage[slot].modified = newModified
        storage[slot].category = newCategory
        state.changed = true
    }

    private func touchLocked(
        id: LiveNodeID,
        modifiedAt: Date?,
        isAccessible: Bool,
        errorMessage: String?,
        state: inout MutationState
    ) {
        guard isLiveLocked(id) else {
            state.ignored += 1
            return
        }
        let slot = Int(id.index)
        let node = storage[slot]
        let newModified = modifiedAt?.timeIntervalSince1970 ?? 0
        let newFlags = isAccessible ? Self.accessible : 0
        let wasAccessible = node.flags & Self.accessible != 0
        state.applied += 1
        if node.modified != newModified {
            storage[slot].modified = newModified
            state.changed = true
        }
        if node.flags != newFlags {
            if node.kind == LiveNodeKind.directory.rawValue, wasAccessible != isAccessible {
                addUnreadableCountLocked(from: id.index, by: isAccessible ? -1 : 1)
            }
            storage[slot].flags = newFlags
            state.changed = true
        }
        if errors[id] != errorMessage {
            errors[id] = errorMessage
            state.changed = true
        }
    }

    private func moveLocked(_ id: LiveNodeID, toParent parent: LiveNodeID, name: String, state: inout MutationState) {
        guard id != Self.rootID, isLiveLocked(id), isLiveLocked(parent),
              isDirectoryLocked(parent.index), !name.isEmpty else {
            state.ignored += 1
            return
        }
        let slot = id.index
        // A folder cannot move inside itself: that would detach the subtree it
        // was going to travel with.
        guard !isAncestorLocked(slot, of: parent.index) else {
            state.ignored += 1
            return
        }
        let node = storage[Int(slot)]
        guard node.parent != parent.index || nameLocked(node) != name else {
            state.applied += 1
            return
        }
        // The name is taken by another entry in the destination folder.
        if let occupant = childSlotLocked(named: name, of: parent.index), occupant != slot {
            state.ignored += 1
            return
        }

        addLocked(
            from: node.parent,
            logical: -node.logical,
            allocated: -node.allocated,
            files: -Int(node.files),
            dirs: -Int(node.dirs)
        )
        if node.kind == LiveNodeKind.directory.rawValue {
            addUnreadableCountLocked(from: node.parent, by: -unreadableCountLocked(slot))
        }
        unlinkLocked(slot)
        let span = Self.appendName(name, to: &names)
        storage[Int(slot)].nameStart = span.start
        storage[Int(slot)].nameLength = span.length
        linkLocked(slot, to: parent.index)
        addLocked(
            from: parent.index,
            logical: node.logical,
            allocated: node.allocated,
            files: Int(node.files),
            dirs: Int(node.dirs)
        )
        if node.kind == LiveNodeKind.directory.rawValue {
            addUnreadableCountLocked(from: parent.index, by: unreadableCountLocked(slot))
        }
        state.changed = true
        state.applied += 1
    }

    private func removeLocked(_ id: LiveNodeID, state: inout MutationState) {
        guard id != Self.rootID, isLiveLocked(id) else {
            state.ignored += 1
            return
        }
        removeSlotLocked(id.index)
        state.changed = true
        state.applied += 1
    }

    private func removeSlotLocked(_ slot: UInt32) {
        let node = storage[Int(slot)]
        if node.parent != Self.none {
            if node.kind == LiveNodeKind.directory.rawValue {
                addUnreadableCountLocked(from: node.parent, by: -unreadableCountLocked(slot))
            }
            addLocked(
                from: node.parent,
                logical: -node.logical,
                allocated: -node.allocated,
                files: -Int(node.files),
                dirs: -Int(node.dirs)
            )
            unlinkLocked(slot)
        }
        freeSubtreeLocked(slot)
    }

    /// Frees a slot and everything under it, taking its files out of the category
    /// totals and retiring each id so a stale one can never name a new entry.
    private func freeSubtreeLocked(_ slot: UInt32) {
        var stack: [UInt32] = [slot]
        while let current = stack.popLast() {
            let node = storage[Int(current)]
            if node.kind == LiveNodeKind.file.rawValue {
                categoryTotals[Int(node.category)] -= node.logical
            }
            errors[LiveNodeID(index: current, generation: node.generation)] = nil
            unreadableCounts[LiveNodeID(index: current, generation: node.generation)] = nil
            var child = node.firstChild
            while child != Self.none {
                stack.append(child)
                child = storage[Int(child)].nextSibling
            }
            storage[Int(current)] = Storage(generation: node.generation &+ 1)
            freeSlots.append(current)
            liveCount -= 1
        }
    }

    private func isAncestorLocked(_ slot: UInt32, of other: UInt32) -> Bool {
        var current = other
        while current != Self.none {
            if current == slot { return true }
            current = storage[Int(current)].parent
        }
        return false
    }
}
