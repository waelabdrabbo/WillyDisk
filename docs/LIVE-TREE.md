# Live results tree

Status: **done.** The engine fills the tree while it walks and hands it over before
the terminal event, so nothing converts a finished summary; every results view reads
the tree. History, the CLI, export, diagnostics and the coverage sheet remain the
scan's record, deliberately.

## Why

A settled scan is a measurement of a moment. macOS never stops writing: in 90 seconds of
sitting still on this Mac, a whole-disk FSEvents stream delivered 1,719 item events
touching 177 distinct folders, 41% of them metadata that cannot change a measured number
at all. A snapshot screen therefore goes out of date within seconds, and the app can only
answer by saying so — a badge that grows for as long as the results stay open, blaming the
person for churn they did not cause, and a full-disk scan that can never be refreshed
inside its own budget.

The structural answer is to make the tree the data, and apply a filesystem change to it
entry by entry. Nothing is invalidated, nothing is re-scanned, and nothing is claimed —
the screen reads the tree. This document is the plan to give WillyDisk that truth.

## The model

`LiveTree` is a compact arena of entries, one per scanned item:

- **Node storage** — `parent`, `firstChild`, `nextSibling`, name span, subtree
  `logical`/`allocated` bytes, subtree file and directory counts, `modified`, kind,
  category, and an access flag: 56 bytes per node. Names are UTF-8 in one append-only
  blob, not a `String` per node. For this machine's disk (4,637,637 entries) the arena
  costs roughly **290 MB**, where the value tree that carries the same walk peaks at
  **2.70 GB**.
- **Aggregates are stored per node**, exactly as `ScanNode` reports them: a file is
  `fileCount: 1`; a directory's counts include itself; sizes are subtree sums. A change
  is applied to the node and walked up the parent chain, so the cost of one change is the
  depth of the tree, not the size of the disk.
- **Category totals** are maintained per edit by the file nodes that carry bytes.
- **Identity** is the node's arena index, and it is stable until the node is removed, so
  a selection survives edits around it. `ScanNode` materialization derives its `UUID`
  from that id plus a per-tree salt, so a redraw never changes a row's identity.
- **The root is id 0.** `directoryCount` includes the root, matching the scanner.
- **Paths keep the spelling the scan gave them.** Normalization is lexical — `.`,
  `..`, repeated and trailing slashes — and never resolves symbolic links:
  `URL.standardizedFileURL` turns `/private/var` into `/var`, which would make every
  entry under a link spell itself differently from the tree and from Finder. The one
  exception is the watcher's: FSEvents names the root's `realpath`, so a path that
  reaches the root through the resolved spelling is rewritten to the tree's before the
  lookup. A scan started at `/var/…` and a stream reporting `/private/var/…` therefore
  find the same entries.

`LiveTree.Edit` is the whole vocabulary of change:

| Edit | Meaning |
|---|---|
| `insert(parent:node:)` | A measured subtree arrived: a file, or a directory with everything under it; a child of the same name is replaced |
| `insertNew(parent:node:)` | The same insert when the caller has just diffed the names and knows the folder holds no entry of that name |
| `updateFile(id:logicalSize:allocatedSize:modifiedAt:category:)` | A file's bytes changed |
| `touch(id:modifiedAt:isAccessible:errorMessage:)` | Metadata a re-listing reports for any entry |
| `move(id:toParent:name:)` | A rename or a move between folders, keeping identity and subtree |
| `remove(id:)` | An entry and everything under it went away |

`apply(_:)` takes a batch, applies it under one lock, and bumps `revision` once. Invalid
or stale edits (a parent removed earlier in the same batch, a vanished id) are counted in
its report rather than silently dropped or allowed to crash. An insert that promises a new
name skips the sibling scan that replace-by-name would do, so a re-listing that adds many
entries to one folder stays linear.

## The updater

`LiveTreeUpdater` is an actor that takes the folders a watcher reports and
reconciles each one:

1. read the folder's entries in bulk with `DirectoryReader` — one
   `getattrlistbulk` pass, 0.05 ms for the busiest folder on this Mac;
2. compare them with the entries the tree holds, by name and kind;
3. write a file from its own `stat`, a vanished entry as a removal, and a folder
   that arrived (or changed its kind) by running the engine on it once and
   inserting the measured result;
4. apply the whole batch through one `LiveTree.apply`, so a screen sees one
   revision.

`LiveTreePolicy` carries the rules the tree was measured with — hidden items,
exclusions, `stayOnVolume`, symlink policy — and the updater re-applies them to
every entry, so an edit can never put into the tree something that scan would
have skipped. A batch is a work list, not a label: every folder it names is
reconciled, and a folder over the pass's bound comes back in `Batch.deferred` and
is queued for the next pass rather than dropped. A folder is reconciled whole or not at all: when a batch would
exceed `maxSubtreeScansPerBatch` (16 by default) the folder is returned in
`Batch.deferred` and nothing is written for it, rather than leaving half of it
patched. Folders named under another changed folder are dropped, because listing
the outer one answers both.

A change costs what the change is: a file write is a directory listing plus one
edit — 1.19 µs measured on a 4.6M-entry tree — and only a folder that is genuinely
new costs a subtree walk. A folder with an enormous number of entries pays its
entry count at every re-listing; that is the cost of reconciling a folder by name, and
the reason a per-directory name index is on the list below.

## The walks

Two questions need the whole tree: a search, which needs names, and a ranking, which
needs numbers. `LiveTree.walk` hands out entries with their names; `LiveTree.walkNodes`
hands out facts without them, which is roughly twice as cheap. Both take the tree's lock
per folder and run the visitor outside it, so a walk on a big disk never stops the
watcher from applying an edit. They are not snapshots: a folder that changes mid-walk is
seen before or after that edit, and every entry reported was measured.

On this Mac's full disk (4,637,637 entries) a walk with names costs **3.70 s** and a
facts walk **1.79 s**, so a screen must not run one per applied batch. The results screen
re-runs an open search at most every 4 s and re-ranks the largest lists at most every
3 s, always off the main actor and cancelled when the screen goes away. The previous
answer stays on screen while the next walk runs.

## The engine's pass

`FileScanEngine` conforms to `LiveTreeScanning`: `scan(_:buildingLiveTree:)` streams the
same events as the frozen `scan(_:)`, and `takeLiveTree()` returns the tree the walk
filled, once. `FileScanner` inserts as it discovers:

- a folder is inserted when it is claimed (before its children are walked), so its
  parent chain exists when they arrive;
- a folder's files and link leaves are inserted **in one batch** when its listing is
  done — one lock, one ancestor walk for the whole group, because siblings share their
  ancestors and their difference is a sum. The batch never looks for an existing entry
  of the same name: a listing names each entry once, and looking would scan every
  sibling already inserted and make a wide folder quadratic;
- the folder's own metadata (timestamp, accessibility, error) is recorded when its
  subtree finishes.

The tree is handed over just **before** `.finished`, and only when `matches(_:)` holds
against the summary the same walk produced — a consumer that reacts to the terminal
event always finds it, and a tree that disagrees is never shown. An engine that only
implements the frozen `ScanEngine` (a scripted test engine) leaves the screen to build
the tree from the summary, which is the path `LiveTree(scanning:)` still serves.

## Invariants

1. **Everything in the tree was measured.** No edit ever writes an estimate. A new
   directory is only inserted after its subtree has been walked; a size is only replaced
   with a `stat` or a bulk listing.
2. **The measurement rules are the scan's.** Hidden items, exclusions, `stayOnVolume`,
   symlink policy, and the hard-link accounting of `ScanAccounting` follow
   `ScanRequest`; the tree must not become a different measurement from the one the
   record keeps.
3. **A record stays a scan.** `ScanSummary`/`ScanRecord` remain the frozen description of
   a finished run and the history entry; the live tree is what the screen shows. The
   screen following the disk is never written to History.
4. **One writer.** Edits are applied off the main actor on one serial path; screens read
   copies through the lock. No screen mutates the tree, and no reader ever sees a subtree
   aggregate that disagrees with its children.
5. **Children are unordered.** The arena links siblings for iteration only; every screen
   sorts what it draws (`ExplorerQuery`, `ChartPalette`), so no display depends on
   insertion order.

## Measured

On this Mac — 4,637,637 entries — with the engine filling the tree as it walks:

- The full-disk scan takes **37.2 s** and the handover to the screen is **0.00 s**
  (`takeLiveTree`), where the same disk used to take 35.7 s to scan and then 6.7 s to
  convert: the screen reaches live results about five seconds sooner and never waits
  after the terminal event.
- Peak resident memory for that run is **2.14 GB**, against 2.24 GB for the
  scan-plus-conversion path, because the arena grows with the walk instead of being
  built beside a finished summary.
- `/Applications` (457,675 entries): 3.02 s with the walk-built tree, against 2.53 s
  for the plain scan and 0.62 s for the old conversion.
- The updater's bounded cost is unchanged: re-listing 0.05 ms, one edit 1.19 µs; a
  whole-tree walk 3.70 s with names and 1.79 s without.
- The arena's own storage is 56 B/entry plus its name — about 290 MB for this tree.

## Migration

| Stage | What lands | State |
|---|---|---|
| 1 | `LiveTree`, `LiveNodeID`/`LiveEntry`, the edit vocabulary, build from a finished `ScanSummary`, materialization back to `ScanNode` | **done** |
| 2 | `LiveTreeUpdater`: re-list a folder, diff its entries, scan a newly created directory, apply the edits, delete subtrees | **done** |
| 3 | `ScanViewModel` and the results screen read the tree: explorer rows, header totals, chart, category ring | **done** |
| 4a | `ScanSearch` and the largest lists walk the tree on a throttled interval | **done** |
| 4b | The sheets that walk everything (`CleanupAnalysis`, duplicate candidates, `CategoryFiles`) read the tree | **done** |
| 5 | The engine inserts into the arena during the walk and hands it over before the terminal event | **done** |

## What changed in the architecture

`docs/ARCHITECTURE.md` §8 lists the live tree's rule as a non-negotiable — a tree
edited only with measured changes, and a `ScanSummary` that is never edited — and the
watching section describes the tree, the updater, and the policy. The record is still a scan: History, the CLI, and export read `ScanSummary` and
`ScanRecord`, never the tree.
