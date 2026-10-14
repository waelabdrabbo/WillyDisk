# DiskCore — agent notes

Pure logic, no UI: `DiskCore` never imports `DiskUI` or AppKit. It is what the UI links
against for scanning.

`Models/**` and `Scanning/Contracts.swift` are frozen: changing a signature there is a
design change, so explain it and update `docs/ARCHITECTURE.md` in the same change.

## Invariants (do not weaken these)

- All filesystem work happens off the main actor, in a dedicated task or actor.
- `scan(_:)` emits zero or more non-terminal `.partial` snapshots, then exactly one
  terminal `.finished` or `.cancelled`, then ends.
- Issues never terminate a scan. Every surfaced `.issue` carries a `ScanIssueKind`;
  `ScanSummary.errorCount` stays the truthful uncapped total while `surfacedIssueCount`
  reports how many were actually surfaced, and the per-path stream stays bounded.
- `ScanProgress.fractionCompleted` is `nil` unless a reliable total is known. Never
  fabricate progress or statistics.
- Symlink loops and out-of-scope traversal are prevented by tracking visited device and
  inode. `ScanRequest.followSymlinks` defaults to false and `stayOnVolume` to true.
- Public types stay `Sendable` and Swift 6 concurrency-clean.

## Testing

Engine tests live in `Tests/DiskCoreTests/`. Exercise permission denials and I/O faults
through the `FileSystemAccess` seam in `Scanning/FileScanner.swift` instead of the real
filesystem.
`ProgressiveSnapshotTests` and `ScanBenchmarkTests` cover snapshot emission and
traversal cost; keep them green when you touch traversal, cancellation, or batching.

Run one class: `swift test --filter FileScanEngineTests`.
