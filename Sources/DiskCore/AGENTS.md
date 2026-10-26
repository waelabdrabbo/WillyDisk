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
- A directory node exists only once its subtree has finished, so a partial snapshot
  would show an empty screen for most of a scan. `ScanSummary.rootChildren` therefore
  reports the scan root's own entries from the moment they are discovered, each folder
  with the bytes counted under it so far — work already done, never a projection, and
  never more than the finished node reports. Report each group whole, a folder's
  claimed subfolders included before they are walked: the colours a screen derives are
  rankings among siblings, and a group that arrives in pieces moves them. Keep it empty
  in a summary that carries the root node itself.
- Symlink loops and out-of-scope traversal are prevented by tracking visited device and
  inode. `ScanRequest.followSymlinks` defaults to false and `stayOnVolume` to true.
- Public types stay `Sendable` and Swift 6 concurrency-clean.

## History (`History/`)

`ScanRecord` is a versioned DTO, not the frozen model made codable: counts, ranked top
lists, accounting, the scan options, and volume facts — never the tree. One JSON file
per finished scan; only `.finished` summaries are recorded, never `.cancelled`. The
store is synchronous filesystem work and belongs off the main actor. A file with an
unknown `schemaVersion` or unreadable bytes is skipped and counted, never deleted by
pruning: a newer release may know what it says. `ScanComparison` matches entries by
path and reports `new`/`grown`/`shrunk`/`unchanged`; totals and categories are exact,
ranked entries are the top 100 of each run, and an entry absent from a truncated earlier
list is only `new` when it outranks that list's cut-off — at or below it the comparison
leaves the entry out. No difference is called a saving.

## Live tree (`Live/`)

`LiveTree` is the arena the results screen reads: 56 bytes per entry plus one
append-only UTF-8 name blob, subtree aggregates stored on every node, and a small edit
vocabulary (`insert`, `updateFile`, `touch`, `move`, `remove`) applied in batches under
one lock. A batch that changes anything bumps `revision` once; a batch that changes
nothing does not. Ids carry a generation, so a removed entry can never be mistaken for a
later entry that reused its slot. `scanNode(for:depth:)` materializes the frozen
`ScanNode` for surfaces that still need it, with an id derived from the entry's so a
redraw keeps row identity, and `LiveTree(scanning:)` refuses a summary whose totals
disagree with the tree it would build. A watcher's folders are applied to this tree as
measured edits; the tree never holds an invented one. `docs/LIVE-TREE.md` has the model,
the invariants, and the migration.

The engine fills the tree as it walks: `FileScanEngine` conforms to
`LiveTreeScanning`, and `FileScanner` inserts a folder when it is claimed, a folder's
files and link leaves in **one batch** when its listing is done (one lock, one ancestor
walk — the batch must never look up a sibling by name, or a wide folder becomes
quadratic), and the folder's own metadata when its subtree finishes. The updater's inserts
use `Edit.insertNew` for the same reason: it has just diffed the names, so the tree need
not scan every sibling to look for one. The tree is handed over just before `.finished`,
and only when it matches the summary the same walk built.

`LiveTreeUpdater` is the actor that turns the folders a watcher reports into edits: it
re-lists a folder with `DirectoryReader`, writes files from their own `stat`, removes
vanished entries, and measures a folder that arrived by running its own `ScanEngine` on
it once (a separate instance, so a subtree walk never takes the app's scan slot).
`LiveTreePolicy` carries the scan's rules and every entry is re-checked against them.
A folder is reconciled whole or not at all: over the subtree-scan budget it comes back
in `Batch.deferred` with nothing written, and nested folders under another changed folder
are dropped because listing the outer one answers both.

## Watching (`Watching/`)

One item-level FSEvents stream per root, owned by `ScanTreeWatcher`. `ScanItemEvent`
reduces each item event to the folder it changes (a file's event is its parent, a
directory's own entry change is the directory) and drops the metadata events that
cannot change what a scan measured. `ScanWatchScope` is the only place that decides
whether that folder belongs to the scan. Its rules mirror the request: canonical
`realpath` root and exclusions, an exclusion at or above the root ignored, the same
`stayOnVolume` device rule as the traversal, and `/System/Volumes/Data/…` mapped to
`/…` when the root is `/`. The callback runs on a private serial queue; `start` and
`stop` are safe from any thread. The watcher itself never edits anything: it reports
the folders, and `LiveTreeUpdater` applies the measured edits to the tree. A
`ScanSummary` is never edited.

## Cleanup (`Cleanup/`)

`CleanupRule` and its `CleanupTier` are the catalog: a rule's identity, its safety tier,
and its display order. `CleanupAnalysis` makes one pass over a `LiveTree`, largest
entries first, and keeps the largest matches per rule while counting every one; a folder a
rule offers is one finding and its subtree is not walked. `CleanupPolicy` holds the
thresholds, and both a threshold and a reported size are local bytes (`allocatedSize`),
because a cleanup finding is what emptying the Trash returns. The rules carry no strings
and touch no filesystem; `DiskUI` and `DiskCLI` supply the wording.

`DuplicateHasher` reads a 128 KB prefix of each size-matched candidate and only reads a
file whole when another file shares its size and prefix; files are read a few at a time.
It excludes every path of an inode that has more than one link (a hard link is not a
copy) and every path whose blocks are shared with another file (an APFS clone), counts
unreadable files instead of calling them duplicates, and returns nil on cancellation.
`isCancelled` must be safe to call from the reading threads — `Task.isCancelled` is not,
so callers pass a flag.

`ReclaimLog` records the moves this app made: one JSON file, the last 20 batches, each
item's original path and where the system put it in the Trash, and whether it was put
back. It is a convenience for undo, not the source of truth — the restore path asks the
filesystem again — and a file this release cannot read is set aside, never overwritten.
`docs/CLEANUP.md` has the rules, the tiers, the accounting, and Put Back.

## Testing

Engine tests live in `Tests/DiskCoreTests/`. Exercise permission denials and I/O faults
through the `FileSystemAccess` seam in `Scanning/FileScanner.swift` instead of the real
filesystem.
`ProgressiveSnapshotTests` and `ScanBenchmarkTests` cover snapshot emission and
traversal cost; keep them green when you touch traversal, cancellation, or batching.

History storage and comparison are covered by `ScanHistoryTests` in
`Tests/DiskCoreTests/`. The watcher's filter is covered deterministically by
`ScanWatchScopeTests`; `ScanTreeWatcherTests` drives one real FSEvents stream against a
temporary tree. Run one class: `swift test --filter FileScanEngineTests`.
