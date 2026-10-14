import Foundation

/// A node in the scanned tree. Value type, compact.
///
/// Frozen by the Architecture & Shared Contracts document (`docs/ARCHITECTURE.md`).
public struct ScanNode: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let category: FileCategory
    public let logicalSize: Int64      // sum of file logical sizes in subtree
    public let allocatedSize: Int64    // on-disk allocated bytes (st_blocks*512) where available
    public let fileCount: Int          // files in subtree (1 for a file)
    public let directoryCount: Int     // dirs in subtree
    public let modifiedAt: Date?
    public let isAccessible: Bool
    public let errorMessage: String?
    public let children: [ScanNode]    // sorted desc by logicalSize; empty for files

    public var isLeaf: Bool { !isDirectory }
}
