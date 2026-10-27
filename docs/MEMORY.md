# Memory, one tree, and the ceiling

Status: **the one-tree pass and its guardrails are implemented; the ceiling decision is
C: no cap in this release.** The engine exposes its tree while it walks, and the summary
is the record rather than a second tree. Memory is therefore linear at the arena's own
cost, with no grouped entries and no product change; the decision, its cost, and the
measured trigger for revisiting it are in "The structural ceiling". The polish half of
item 1 — coverage, CSV, empty states, window sizing, accessibility — is outside this
note.

## Why

Before the one-tree rule, a scan could keep that tree in more than one form at once:
the compact `LiveTree` arena the results screen reads, the value records the engine
builds while it walks, and the ranked `ScanNode` entries the summary carries after the
walk. Each was a different representation of the same measurement. The arena costs 56
bytes per entry plus its name; the value tree costs several hundred bytes per entry,
because every entry is a `ScanNode` with a `URL`, a `String` name, a `UUID`, and an
array of children.

The value tree was what made a multi-million-file scan peak in gigabytes. It was also
redundant: since the live tree migration, the screen reads the arena for results. The
summary is the record — totals, counts, category sizes, ranked lists, accounting — and
does not need to carry the tree as well.

The first change was therefore not a node cap. It was to make one scan produce one tree.

## Measured

Conditions: Apple M1 Pro, 16 GB, macOS 27.0.1 (26A434), Swift 6.4, `HEAD` `1427234`,
27 October 2026, warm file cache. Each measurement ran in its own `swift test` process,
so no peak is carried over from a previous run. The `/` run was not privileged: it
reported 911 permission-denied folders, and its totals exclude protected locations. No
process memory graph was taken; resident figures are the process's own RSS.

```bash
WILLYDISK_BENCH_ROOT=<root> WILLYDISK_BENCH_LABEL=<label> \
  swift test --disable-sandbox --filter ScanBenchmarkTests/testBenchmarkScan
WILLYDISK_BENCH_ROOT=<root> WILLYDISK_BENCH_LABEL=<label> \
  swift test --disable-sandbox --filter LiveTreeBenchmarkTests/testTheEngineBuildsTheTreeDuringTheScan
```

| Root | Entries counted (files + folders + root) | Plain scan | Plain sampled RSS | Walk-built tree | Walk-built peak RSS | Arena cost (walk − plain) |
|---|---:|---:|---:|---:|---:|---:|
| `/Applications` | 445,225 | 2.87 s | 365 MB | 3.30 s | 413 MB | ~48 MB |
| `$HOME` | 3,087,229 | 27.98 s | 2,089 MB | 27.99 s | 2,435 MB | ~346 MB |
| `/` (911 denied folders) | 4,518,597 | 37.23 s | 2,345 MB | 39.85 s | 2,755 MB | ~410 MB |

The tree's node count is higher than the summary's file-plus-folder count because the
tree holds each symbolic link as a leaf: 458,201 nodes at `/Applications`, 3,134,754 at
`$HOME`, and 4,633,319 at `/` — 12,976, 47,525, and 114,722 more than the counted
entries. Those leaves are entries the tree needs and the summary does not count as
files. The plain-scan figure is the benchmark's resident sample after each event; the
walk-built figure is `getrusage`'s maximum. Both are the test process's own memory;
treat them as comparable to within a few percent, not as a process memory graph.

What the numbers mean:

- The arena costs about **90–115 bytes per entry** in practice: 56 bytes of entry,
  plus the name blob and the storage growth that comes with it.
- The value tree costs roughly **500–800 bytes per entry** by the same subtraction. It
  is four to eight times the arena.
- A plain 4.5-million-entry scan peaks at **2.35 GB**, with no live tree involved. A
  one-tree scan should peak near the arena plus the runtime — of the order of
  **0.4–0.6 GB** — not near 2 GB.
- `docs/LIVE-TREE.md` recorded 2.14 GB for a 4.64-million-entry full-disk run. The
  shape is the same; the difference is the run, the count, and the access it had.

## What a scan retained before the one-tree rule

Three regimes overlapped while a scan ran:

1. **The arena.** `LiveTree` stores every entry at 56 bytes plus its name as the walk
   discovers it. It is compact, lock-protected, and already the screen's data source
   once the scan settles. It is not the problem.
2. **The live root records.** `FileScanner.WalkState.rootChildren` keeps a
   `LiveDirectory` for each of the scan root's own folders. A `LiveDirectory` carries
   `entries`, a `[String: ScanNode]` of the folder's direct entries, and `finished`, the
   folder's complete `ScanNode` subtree once it has been walked. Its `entries` are extra
   `ScanNode` values — URL, name, UUID, and an array — and its `finished` subtree shares
   the value tree the walk is building. On `/`, the root's folders are the whole disk,
   so this regime pins the disk's value tree for as long as the root keeps walking.
3. **The ranked summary tree.** `FileScanner.recordDirectory` builds every directory's
   `ScanNode` with its children sorted and offers it to the `largestDirectories` `TopN`.
   For any tree holding bytes, the root is the largest directory and is in the top 100;
   the root's children array pins every other entry. The same is true for the largest
   subtrees in the top 100. This survives the walk: the terminal `ScanSummary` carries
   it, and the results screen holds that summary for history, export, coverage, and the
   fallback path.

There was a fourth, transient cost: each `.partial` snapshot re-materialises the root's
live records — `rootChildren(from:)` builds and sorts a `ScanNode` array per still-walking
root folder — so snapshots allocate and sort while the walk is trying to make progress.
The `/` run emitted 1,322 partials in 37 seconds. The screen applied at most one a
second, but the engine built them all.

## The one-tree rule

**A scan produces one tree. When a producer fills a `LiveTree`, that tree is the tree;
the summary is the record.**

The rule is about retention, not about the measurement. The same `WalkState` still
measures every entry once, and the tree is still checked against the summary before it
is shown.

### The producer

`LiveTreeScanning` gains a way to read the tree while the walk fills it. The exact
spelling is an implementation detail; the shape is:

```swift
func liveTreeInProgress() async -> LiveTree?   // nil when this producer has no tree
```

The protocol already has `takeLiveTree()` for the terminal handover. That stays. A
default `nil` implementation keeps every existing scripted engine and test double
working unchanged.

`FileScanEngine` installs the tree in its slot as soon as the walk has confirmed that
the root is a directory, before the first `.partial`. The slot is cleared when a new
scan starts, as today, so a later scan can never hand an earlier tree.

### The scanner

While a tree is being filled, `FileScanner` stops maintaining the two value regimes:

- No `rootChildren` and no `rootFiles`; no `creditRootChild`, `openRootChildren`,
  `addRootChildEntry`, `finishRootChild`, or `closeRootChildren`. `ScanSummary.rootChildren`
  is empty in this mode.
- `recordDirectory` builds each directory's `ScanNode` with `children: []`, and skips
  the child sort. The parent still accumulates the returned node's totals, so every
  count and size is unchanged. `largestDirectories` keeps its 100 entries, now without
  subtrees.
- `largestFiles` is unchanged: a file node has no children, and the ranked list is what
  history and export record.
- Snapshot assembly no longer walks or sorts a folder's entries; the snapshot carries
  totals, categories, ranked lists, accounting, and an empty `rootChildren`.
- A folder's entries are published as one group. The summary's `rootChildren` rule
  exists because a chart colours siblings by their rank, and a group that arrives in
  pieces moves the colours already on screen. The walk therefore inserts the batch of
  entries a listing discovered — the empty folders it claimed and the files it read —
  through one `LiveTree` call before it walks the folders, so a redraw between the
  listing and the walk never sees half a folder. A test pins that.
- Directory metadata still reaches the tree through `recordDirectoryMetadata`, and the
  tree is handed over just before the terminal event as it is today.

The walk still constructs a `ScanNode` for every file and folder, because the tree
inserts from nodes and the ranked lists are summaries of them. Those nodes are
transient: with no retained children arrays, a finished directory's array is released
when its parent merges it. Peak retention becomes the arena plus the current traversal
frontier.

### The handover

The terminal summary takes its totals and category sizes from the tree itself, so the
record and the screen repeat one measurement. `LiveTree.matches(_:)` remains the
consistency check; when it holds, the engine installs the tree for the consumer to take.
If it ever fails, the engine installs no tree, and a screen that already adopted the
in-progress tree keeps it — it is the same measured tree — while a screen that did not
falls back to the record. A mismatch is an engine defect, not a normal state; the tests
keep it impossible.

The fallback for producers that do not implement `LiveTreeScanning` is unchanged:
`ScanViewModel` keeps the summary it was handed and builds a tree from it with
`LiveTree(scanning:)` after the terminal event. That is also why the compact summary
must stay a complete record; only the subtrees are gone.

### The screen

`ScanViewModel` installs the in-progress tree on `.started` (or on the first event after
it lands), before the first `.partial` is applied. It replaces it with the handed-over
tree at `.finished`. On `.cancelled`, the partial tree stays as the read-only results
surface, with the watcher stopped and the phase saying the scan was stopped; it is not
presented as settled.

The views already prefer `liveTree` when it exists for the explorer, chart, and search.
Two paths need auditing rather than assuming:

- `ResultsView.rootNodes`, `currentChildren`, and `searchForest` use the summary's root
  node or `rootChildren` when there is no tree. They are the fallback and should stay
  correct for full summaries.
- While a scan is live, the results rows and chart come from the tree. The scanning
  banner and the header total stay the engine's `ScanProgress` — "scanned so far" — which
  is a different question from "what is on screen"; the two can differ by the folder
  currently being listed, and should be labelled so. Once the run settles there is no
  progress, and the header reads the same tree and summary the rest of the screen does.
  The summary remains the record for History, the CLI, export, diagnostics, and coverage.

### Frozen contract

This is a semantic change to [the frozen model](../Sources/DiskCore/Models/ScanSummary.swift)
and [the scanning contract](../Sources/DiskCore/Scanning/Contracts.swift), not a
signature change:

- `ScanSummary.rootChildren` is empty when the producer supplies a live tree; the tree
  carries the root's entries.
- Entries in `ScanSummary.largestDirectories` may have empty `children` in that mode;
  the tree carries the subtrees.
- A plain `ScanEngine.scan(_:)` — the CLI and every fallback test — is unchanged and
  still emits complete directory nodes and `rootChildren`.

The change belongs in `docs/ARCHITECTURE.md` §3/§4 and in the comments on those fields
in the same change, with the reason: the live tree is the screen's tree, and the summary
is the record. If carrying a complete tree in the summary is a contract that must not
move, the alternative is a second summary type, which is a larger contract change and
not recommended.

### Observed outcome

The same three roots after the one-tree change, again in isolated `swift test`
processes. The tree is still the walk-built one; the summary no longer carries it.

| Root | Before (walk-built) | After (walk-built) | Change |
|---|---:|---:|---:|
| `/Applications` | 413 MB | 118 MB | −71% |
| `$HOME` | 2,435 MB | 537 MB | −78% |
| `/` | 2,755 MB | 636 MB | −77% |

Scan wall time moved from 3.30 s to 3.00 s at `/Applications`, from 27.99 s to 26.37 s
at `$HOME`, and from 39.85 s to 40.56 s at `/`; the last run saw 4,632,082 nodes rather
than 4,633,319, so treat it as unchanged within the run-to-run variance of a warm
cache. The target of 500 MB for `$HOME` was low by 7%: the arena's name blob and
allocator headroom account for the difference, and the result is still well under the
2.4 GB it replaced.

### Tests and guardrails

- A structural engine test on a temporary fixture: a walk-built summary has no
  directory subtrees and no `rootChildren`; a plain scan's does.
- A test that the in-progress tree is readable before the terminal event and that its
  root totals agree with the summary at handover, using the existing
  `FileSystemAccess` seam for a deterministic fixture.
- A test that a folder's children are published as one group: a reader between a
  listing and the walk never sees the folder's folders without its files, so a chart's
  sibling ranks do not move.
- A view-model test that the tree is installed before the terminal event and that
  cancellation keeps it as a partial surface, not as settled results.
- Update the tests that currently convert a walk-built summary back into a tree
  (`LiveTreeEngineTests` compares the converted tree with the handed one) and the QA
  tests that assume `rootChildren` from a writer that supplies a tree.
- The two benchmarks stay opt-in. The walk-built benchmark asserts that the summary is
  compact and, when `WILLYDISK_BENCH_MAX_RSS_MB` is set, that the peak is within it;
  neither wall-clock time nor RSS is asserted in CI.

## The structural ceiling

After the one-tree rule, memory is still linear: about 90–115 bytes per entry. That is
a good constant, not a bound. At 10 million entries the arena is close to a gigabyte;
at 50 million it is several. This release accepts that growth, and this section records
why, what it costs, and the measured point at which the decision is reopened.

### What has to keep working

- Totals, counts, and category sizes are exact and never estimated.
- `largestFiles` and `largestDirectories` keep their ranked entries; History, the CLI,
  export, diagnostics, and coverage read the summary and are unaffected.
- The explorer can list a folder, enter a folder, select, Quick Look, reveal, and move
  to Trash.
- Search, cleanup rules, duplicate candidates, and category files either see an entry
  or say that it is grouped and not individually held.
- The watcher reconciles a changed folder without double counting or losing bytes.
- A group row is a measurement, never a fabricated file.

### Options

| Option | Bounds the arena? | What it costs |
|---|---|---|
| Per-directory cap with a folded group only (the roadmap's original wording) | Only pathological wide folders; total entries still grow with folder count | Deterministic per folder; groups are local and explainable |
| Global stored-entry budget, with a per-directory cap as the allocation rule | Yes: stored entries stop growing at the budget | Which files are grouped depends on where the walk was when the budget was reached; features must disclose grouped files |
| No cap; document the linear cost | No | No product cost, but the roadmap's structural requirement is unmet |

### Decision: C — no cap in this release

The arena stays linear. There are no grouped entries, no expansion UI, no updater
change, and no file becomes unsearchable. The one-tree pass removed the cost that
mattered; what remains is compact and predictable, and the measured envelope is the one
in "Observed outcome": 118 MB for `/Applications`, 537 MB for `$HOME`, 636 MB for the
4.63M-entry `/`.

The cost is explicit: a disk well beyond the measured 4.63M entries still grows the
resident set, roughly 90–115 bytes per entry plus the runtime. Nothing in this release
bounds that. A cap would buy a hard bound only above the threshold, at the price of a
product change: grouped files leave search, cleanup, duplicate checking, and category
lists until expanded; the updater has to reconcile a capped folder as a unit; the UI
needs a new row and its disclosures. That is not worth adding while the supported disks
fit inside the measured envelope.

**Reopen the decision when any of these holds:**

- a scan of a root with **more than 6,000,000 entries** is run in the app (the proposed
  budget in the design below);
- the walk-built benchmark on the reference machine shows a **peak above 1 GB**, or a
  peak above 25% of the physical memory of the smallest Mac the release supports;
- a memory-pressure or swap report is traced to a scan rather than to another app;
- a release is planned to market multi-million-file or whole-disk scans beyond the
  measured envelope.

**How to measure it:** the two opt-in benchmarks are the instrument. For the tree path:

```bash
WILLYDISK_BENCH_ROOT=/ WILLYDISK_BENCH_LABEL=disk \
  WILLYDISK_BENCH_MAX_RSS_MB=1024 \
  swift test --disable-sandbox --filter LiveTreeBenchmarkTests/testTheEngineBuildsTheTreeDuringTheScan
```

`WILLYDISK_BENCH_MAX_RSS_MB` turns the benchmark into an assertion; without it the run
only prints the peak. Compare like with like — same root, same access, same cache state
— and record the result here.

### If the cap is revisited: the recommended shape

A global budget of stored entries, plus a per-directory cap:

- `maxStoredEntries` — default **6,000,000** entries. That is above the 4.63M-entry
  disk measured here, so today's machines do not change behavior, and it is about
  **0.6 GB** of arena. A reference Mac can run the benchmark with a lower value.
- `maxChildrenPerDirectory` — default **20,000 stored children**. It protects a folder
  built by a mail client or a cache before the global budget is reached, and makes the
  pathological-folder case deterministic.
- **Directories are always stored.** Files are stored largest first within the budget;
  the rest are folded into one group per folder. A file of 1 MB or more is kept while
  the budget allows; the budget wins under pressure, and then cleanup and duplicate
  checking disclose that some files are not individually held.
- The group is a measured aggregate: exact logical and allocated sums, file count,
  and per-category sums (a side table for the few groups, not nine more fields in every
  entry). It is a new `LiveNodeKind.group`, with no name of its own; the UI gives it
  the localized label. It is not a file and not a folder: no Quick Look, Reveal, or
  Trash action on it.
- **Expansion** re-lists that one folder with `DirectoryReader`, removes the group, and
  inserts the measured entries through the tree's edit path. The totals change only by
  what the fresh listing measured against the group it replaces, which is a measured
  change like any watcher edit; the screen says the folder was listed now. Collapsing
  folds it back. Expanding can temporarily exceed the budget because the user asked for
  that folder.
- **The watcher** treats a folder with a group as reconciled whole: re-list it, update
  the stored entries as today, and recompute the group's sums from the names not stored.
  A re-list that brings the folder under the cap may split the group; a re-list that
  pushes it over may fold the smallest stored entries. The group is a function of the
  listing, never a stale leftover.

### What the UI says

- The explorer row: a group draws as one row with its file count and size and an
  affordance to list the files now.
- Search: a group is not a name match. The results carry `groupedFileCount`, and the
  summary line says how many files were grouped and not searched. A path query does not
  match a group's non-existent path.
- Cleanup and duplicates: they walk the tree, so they see only stored files; when the
  tree holds groups, the sheet's summary says that some files were not individually
  examined. The 500 MB and 1 MB rules are unaffected unless the budget forced those
  files to fold.
- Category files: categories stay exact in the breakdown; a category's file list says
  how many of its files are grouped.
- The chart draws a group as one child of its folder, with the group's exact bytes and
  the same fill rules; it is not a folder and cannot be entered.
- History, the CLI, export, diagnostics, and coverage are unchanged: they read the
  summary, whose ranked lists and totals are still complete.

### Open questions if the cap is revisited

- Is a fixed 6M budget right, or should it be derived from physical memory? A fixed
  number is reproducible and testable; a derived one adapts but makes two Macs behave
  differently on the same tree.
- Is 20,000 the right per-directory width? Measure the widest folders on the reference
  machine before choosing; a cap far above every real folder is only a safety valve.
- Does expanding a group have to re-list at the moment of expansion, or may it use the
  scan's discarded measurement? Only the former is available without retaining it, and
  it is honest about being a fresh measurement.
- Should the group be hidden from the chart, or drawn? Drawing it keeps the folder's
  bytes whole; hiding it would leave a gap the chart cannot explain.

## Migration

| Stage | What lands | State |
|---|---|---|
| 0 | This note, the measured baseline, the decision on the one-tree rule | **done** |
| 1 | In-progress tree through `LiveTreeScanning`; compact summary from `FileScanner`; no root records and no ranked subtrees | **done** |
| 2 | The view model installs the in-progress tree and keeps it through cancellation; the rows and chart come from the tree | **done** |
| 3 | Contract and doc updates; tests for the compact summary and the in-progress tree | **done** |
| 4 | Re-measure and fill the observed table | **done** |
| 5 | The ceiling decision | **done: C, no cap in this release** |
| 6 | Group row, expansion, watcher reconciliation, disclosures | deferred with the cap |
| 7 | Guardrail tests and the optional RSS bound in the benchmark | **done** |

## Risks

- **A frozen contract moves.** The summary's documented completeness narrows when a
  tree is supplied. Without the documentation change in the same commit, the model
  becomes a lie; with it, the change is explicit.
- **A compact summary cannot draw a tree.** The in-progress tree is the fallback: a
  screen that has adopted it keeps it even if the handover check fails. A screen that
  never adopted one has only the record, and the mismatch path that produces that has
  no dedicated UI state — it is a defect path, kept impossible by the tests rather than
  a normal user state.
- **Concurrent reads.** The tree is read while the walk writes. `LiveTree` locks every
  read and write, and the screen never holds a lock across a view update or calls back
  into the engine.
- **Totals and rows can come from different moments.** The results rows come from the
  tree; the scanning banner and header keep the engine's "scanned so far" counters,
  which can be one folder ahead. That is a separate statement, not a mismatch. The
  summary's totals are for the record, coverage, and history.
- **A live chart can move if a group arrives in pieces.** Chart colours are sibling
  ranks; inserting a folder's subfolders one at a time and its files later would move
  them during a scan. The group-insert rule and its test are the guardrail.
- **Cancellation.** A partial tree is measured but not settled. It is shown without a
  watcher and must not be recorded, exported as a finished run, or compared.
- **Linear growth is accepted.** A tree well beyond the measured envelope can still
  grow the resident set; there is no grouped fallback. The revisit trigger and the
  benchmark assertion are the guardrail, not a code path.

## Decisions

1. **One-tree semantics.** Approved and implemented: the compact summary when a
   producer supplies a live tree, with a plain `scan(_:)` unchanged.
2. **Ceiling shape.** Chosen: **C — no cap in this release.** The global budget and
   per-directory cap below are preserved as a future design, not shipped; the trigger
   for reopening the decision is in "The structural ceiling".
3. **Budget and width.** If the cap is revisited, settle the default numbers (6M
   entries, 20k children) after measuring the widest folders on this Mac.
4. **Expansion.** If the cap is revisited, confirm that expanding a group is a fresh,
   measured listing that splits the group in place, rather than a read-only side list.
