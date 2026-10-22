import Foundation
import DiskCore

/// The folder chain that leads from the scanned root to a folder in its tree.
///
/// A search result comes from anywhere in the scan, while the explorer is rooted
/// at one folder. Resolving the result's folder to the chain of nodes above it is
/// what lets the explorer re-root on that folder without searching the tree again.
public enum ExplorerPath {

    /// The nodes from the root's first-level entry down to `folder`.
    ///
    /// An empty chain is the root itself; `nil` means the tree does not hold the
    /// folder, so the caller must not re-root on a path it cannot show.
    public static func chain(to folder: URL, from root: ScanNode) -> [ScanNode]? {
        let rootPath = root.url.standardizedFileURL.path
        var path = folder.standardizedFileURL.path
        if path == rootPath { return [] }

        // A sibling whose name starts with the root's cannot pass for a folder
        // under it: the separator is what makes the prefix a containment test.
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }

        var expected: [String] = []
        while path != rootPath {
            expected.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        expected.reverse()

        var level = root.children
        var chain: [ScanNode] = []
        for path in expected {
            guard let match = level.first(where: {
                $0.url.standardizedFileURL.path == path
            }) else { return nil }
            chain.append(match)
            level = match.children
        }
        return chain
    }
}
