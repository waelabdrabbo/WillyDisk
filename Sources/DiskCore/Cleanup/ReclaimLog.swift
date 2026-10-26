import Foundation

/// One batch of items this app moved to the Trash.
///
/// The log records where each item came from and where the system put it, so a
/// move can be undone while the Trash still holds the item. It is a convenience,
/// never the source of truth: the filesystem is, and every Put Back checks it
/// again before moving anything.
public struct ReclaimMove: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    /// The folder the move was made inside.
    public let rootPath: String
    public var items: [Item]

    public init(id: UUID = UUID(), date: Date, rootPath: String, items: [Item]) {
        self.id = id
        self.date = date
        self.rootPath = rootPath
        self.items = items
    }

    public var itemsInTrash: Int { items.filter(\.isPending).count }
    public var restoredItems: Int { items.filter(\.isRestored).count }

    /// Every item's on-disk size at the moment of the move.
    public var totalAllocatedSize: Int64 {
        items.reduce(0) { $0 + max(0, $1.allocatedSize) }
    }

    public struct Item: Codable, Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let originalPath: String
        /// Where the system put it, when it reported the result. A move that
        /// succeeded without a reported location cannot be put back.
        public let trashedPath: String?
        public let isDirectory: Bool
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public var restoredAt: Date?

        public init(
            id: UUID = UUID(),
            name: String,
            originalPath: String,
            trashedPath: String?,
            isDirectory: Bool,
            logicalSize: Int64,
            allocatedSize: Int64,
            restoredAt: Date? = nil
        ) {
            self.id = id
            self.name = name
            self.originalPath = originalPath
            self.trashedPath = trashedPath
            self.isDirectory = isDirectory
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.restoredAt = restoredAt
        }

        public var isRestored: Bool { restoredAt != nil }

        /// Still in the Trash, so Put Back can act on it.
        public var isPending: Bool { restoredAt == nil && trashedPath != nil }
    }
}

/// Persists the move log as one JSON file.
///
/// The store is dull on purpose: read the file, change one entry, write it back
/// atomically. It is bounded, because undo convenience must not grow without
/// end, and it holds paths and sizes only — never file contents.
///
/// Every method is synchronous and touches the filesystem, so callers run it off
/// the main actor. An unreadable file is not repaired: the next write sets it
/// aside beside the log rather than overwriting bytes this release cannot read.
public struct ReclaimLogStore: Sendable {

    public static let currentSchemaVersion = 1
    /// Moves kept. Enough to undo the last few sessions, small enough to read in
    /// one go.
    public static let maxMoves = 20

    /// `~/Library/Application Support/WillyDisk/ReclaimLog.json`.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WillyDisk", isDirectory: true)
            .appendingPathComponent("ReclaimLog.json")
    }

    public let url: URL

    public init(url: URL = ReclaimLogStore.defaultURL) {
        self.url = url
    }

    /// The log, newest move first. A missing or unreadable file is an empty log.
    public func load() -> [ReclaimMove] {
        read().moves
    }

    /// Adds a move and prunes the oldest beyond the bound.
    @discardableResult
    public func append(_ move: ReclaimMove, keeping limit: Int = ReclaimLogStore.maxMoves) throws -> [ReclaimMove] {
        let read = read()
        if read.wasDamaged { quarantine() }
        var moves = read.moves
        moves.insert(move, at: 0)
        if moves.count > max(1, limit) {
            moves.removeLast(moves.count - max(1, limit))
        }
        try write(moves)
        return moves
    }

    /// Marks the given items of one move as back where they came from.
    @discardableResult
    public func markRestored(moveID: UUID, itemIDs: Set<UUID>, at date: Date) throws -> [ReclaimMove] {
        let read = read()
        if read.wasDamaged { quarantine() }
        var moves = read.moves
        guard let index = moves.firstIndex(where: { $0.id == moveID }) else { return moves }
        for itemIndex in moves[index].items.indices
        where itemIDs.contains(moves[index].items[itemIndex].id) {
            moves[index].items[itemIndex].restoredAt = date
        }
        try write(moves)
        return moves
    }

    /// Forgets every move. The files it names are untouched.
    @discardableResult
    public func clear() throws -> [ReclaimMove] {
        try? FileManager.default.removeItem(at: url)
        return []
    }

    // MARK: - File

    private struct Stored: Codable {
        var schemaVersion: Int
        var moves: [ReclaimMove]
    }

    private func read() -> (moves: [ReclaimMove], wasDamaged: Bool) {
        guard let data = try? Data(contentsOf: url) else {
            return ([], false)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored.self, from: data),
              stored.schemaVersion == Self.currentSchemaVersion else {
            return ([], true)
        }
        return (stored.moves, false)
    }

    private func write(_ moves: [ReclaimMove]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Stored(schemaVersion: Self.currentSchemaVersion, moves: moves))
        try data.write(to: url, options: .atomic)
    }

    /// Keeps the bytes of a file this release could not read, so a later build or
    /// a person can still look at them.
    private func quarantine() {
        let aside = url.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }
}
