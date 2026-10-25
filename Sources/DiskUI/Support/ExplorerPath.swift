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

    /// The same chain, read from the live tree by path.
    ///
    /// A snapshot chain descends the nodes' own children, but a node materialized
    /// from the live tree carries none — it would stop at the root's first level.
    /// The tree answers by path instead, so any depth resolves.
    public static func chain(to folder: URL, rootPath: String, in tree: LiveTree) -> [ScanNode]? {
        guard let target = tree.scanNode(atPath: folder.path), target.isDirectory else { return nil }
        if target.url.path == rootPath { return [] }

        var chain: [ScanNode] = [target]
        var path = target.url.path
        while path != rootPath {
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, parent != "/" else { return nil }
            if parent == rootPath { break }
            guard let node = tree.scanNode(atPath: parent) else { return nil }
            chain.insert(node, at: 0)
            path = parent
        }
        return chain
    }
}

/// The folded-in chain the explorer is showing, kept to the folders that still
/// exist.
public enum ExplorerBreadcrumb {
    /// The crumbs that still name folders, deepest chain from the root.
    ///
    /// With a live tree the folders are checked by path: the tree is what the
    /// explorer lists, and a materialized node carries no children to descend. A
    /// summary-only screen falls back to walking the snapshot's own children.
    public static func pruned(
        _ chain: [ScanNode],
        rootNodes: @autoclosure () -> [ScanNode],
        tree: LiveTree? = nil
    ) -> [ScanNode] {
        guard !chain.isEmpty else { return [] }

        if let tree {
            var kept: [ScanNode] = []
            for crumb in chain {
                guard let node = tree.scanNode(atPath: crumb.url.path), node.isDirectory else { break }
                kept.append(node)
            }
            return kept
        }

        var level = rootNodes()
        var kept: [ScanNode] = []
        for crumb in chain {
            guard let match = level.first(where: { $0.url == crumb.url }) else { break }
            kept.append(match)
            level = match.children
        }
        return kept
    }
}
