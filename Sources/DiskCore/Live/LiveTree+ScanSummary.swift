import Foundation

extension LiveTree {
    /// Builds the live tree from a finished scan.
    ///
    /// A finished `ScanSummary` from a producer that reports summaries only
    /// carries the scanned root's own node in `largestDirectories` — the root is
    /// the largest directory by definition — and that node holds the measured
    /// entries under it. A summary without it (a partial snapshot, or a cancelled
    /// run) cannot become a tree.
    ///
    /// A summary from a walk that filled a `LiveTree` is compact: `rootChildren`
    /// is empty and the ranked directory entries carry no subtrees, so there is
    /// nothing here to rebuild from. That walk hands its tree over through
    /// `LiveTreeScanning`; this initializer is for the fallback path.
    ///
    /// The tree is then checked against the summary's own totals. A tree that
    /// disagreed with the measurement it came from would put numbers on screen
    /// the scan never reported, so it is refused rather than shown.
    public convenience init?(scanning summary: ScanSummary) {
        let rootPath = LiveTree.lexicalPath(summary.root.path)
        guard let root = summary.largestDirectories.first(where: {
            LiveTree.lexicalPath($0.url.path) == rootPath
        }) else {
            return nil
        }

        self.init(rootNode: root, rootURL: summary.root)

        guard fileCount == summary.fileCount,
              directoryCount == summary.directoryCount,
              totalLogicalSize == summary.totalLogicalSize,
              totalAllocatedSize == summary.totalAllocatedSize else {
            return nil
        }
    }
}
