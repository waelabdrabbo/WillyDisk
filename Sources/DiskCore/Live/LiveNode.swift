import Foundation

/// Identifies one entry in a `LiveTree`.
///
/// The id is stable for as long as the entry exists, so a screen can hold a
/// selection, a row identity, or an expansion across edits to the rest of the
/// tree. A removed entry's id is never handed to a different entry: the arena
/// carries a generation alongside the slot index.
public struct LiveNodeID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let index: UInt32
    let generation: UInt16

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index ? lhs.generation < rhs.generation : lhs.index < rhs.index
    }

    public var description: String { "live:\(index).\(generation)" }
}

/// What an entry is, in the terms the explorer and the chart care about.
///
/// Whether it is a symbolic link is a separate fact: a link the scan followed is
/// still a file or a directory, and one it did not follow is a zero-sized leaf.
public enum LiveNodeKind: UInt8, Sendable {
    case file
    case directory
}

/// One entry as a screen reads it: where it sits and the numbers measured for
/// it, without exposing the tree's storage.
public struct LiveEntry: Sendable, Hashable {
    public let id: LiveNodeID
    /// The folder that holds this entry; `nil` only for the scanned root.
    public let parent: LiveNodeID?
    public let name: String
    public let kind: LiveNodeKind
    /// Whether the entry is a symbolic link — followed or not.
    public let isSymlink: Bool
    public let category: FileCategory
    /// Bytes counted under this entry, its descendants included.
    public let logicalSize: Int64
    public let allocatedSize: Int64
    /// Files counted under this entry: `1` for a file, a followed link to one
    /// included; `0` for a folder and for a link left as a zero-sized leaf.
    public let fileCount: Int
    /// Directories counted under this entry, itself included when it is one.
    public let directoryCount: Int
    public let modifiedAt: Date?
    public let isAccessible: Bool
    public let errorMessage: String?

    public var isDirectory: Bool { kind == .directory }
}
