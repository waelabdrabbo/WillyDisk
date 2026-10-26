# Cleanup

The review list behind the **Cleanup** sheet. What it offers, what it refuses, how it
measures, and what it deliberately does not do.

## Why

A scan already measured every entry under a root. Cleanup is the second reading of that
measurement: it asks which of those entries a person might want to stop storing. It is a
*recommendation*, never an action — every move goes through the reclaim confirmation in
[`Reclaim.swift`](../Sources/DiskUI/Support/Reclaim.swift), and the app has no path that
removes an item without it.

Two rules follow from that, and they outrank coverage:

1. **Never recommend a move that frees nothing.** The number beside a finding is the
   space that comes back, in the same accounting the rest of the app uses for "on disk".
   A file that is not on this Mac — an iCloud placeholder, a sparse file with almost no
   extents — is not a finding.
2. **Never present a capped number as a total.** Every rule states what it kept and what
   it found; totals cover all matches even when the list shows a sample.

## Where it runs

`Sources/DiskCore/Cleanup/` holds the rules and the content check. The analysis reads a
`LiveTree`: the results screen already holds one, and the command line builds one from a
finished scan. It never touches the filesystem, so it cannot invent a size or a date, and
it runs off the main actor on a detached, cancellable task. Nothing is re-scanned.

The sheet follows the tree it reads. While it is open, a watcher batch bumps the results
revision and queues another walk. There is one walk at a time: a batch that arrives during
a walk waits for it to finish instead of cancelling it, because a busy folder — the home
folder is full of caches and logs — would otherwise cancel the first walk forever and
leave "Reading the scanned tree…" on screen. A queued walk waits for the burst to settle,
and the old list stays up until the new report is ready. A refresh drops a finished
content check only when the duplicate candidates it read are no longer the same set.

The app's sheet and `WillyDisk cleanup` are its two consumers. Only the sheet can send a
finding to the Trash — the command line only lists — and the sheet stays open while the
watched tree applies the move, so the moved row disappears from its list. A move made from
the sheet reports its outcome inside the sheet, not on the results view behind it, and its
action opens the sheet's Moved tab. If the results screen cannot follow the move, the
sheet closes and the banner explains on the results screen.

## The report

```
CleanupReport
  groups: [CleanupGroup]        // one per rule, in rule order; empty rules included
  duplicateGroups: [DuplicateSizeGroup]
  duplicateGroupCount: Int      // exact, before the group cap
  duplicateFileCount: Int       // exact, before any cap
  visitedCount: Int
  stoppedAtLimit: Bool
  policy: CleanupPolicy
```

A `CleanupGroup` keeps both sides of its cap: `candidates` (what is shown) and
`matchCount` / `totalLogicalSize` / `totalAllocatedSize` (what was found). `isTruncated`
is `matchCount > candidates.count` and the sheet says so rather than silently cutting.

### Accounting

- A finding's **size** is `allocatedSize` — the bytes the volume holds, which is what
  emptying the Trash returns. `logicalSize` stays the scan's measurement and remains the
  identity used to bucket same-size files, but it is not a cleanup total.
- A rule's **threshold** applies to the same local bytes. "At least 500 MB" means 500 MB
  that goes away, not 500 MB that is mostly somewhere else.
- Files with no local bytes (`allocatedSize == 0`, a dataless iCloud item) are not
  findings at all. This is the one place the scan's disclosure rule ("counted at logical
  size, local bytes reported separately") does not carry over, because a cleanup finding
  is a promise about reclaimable space rather than a measurement.

### The walk

The walk is a depth-first pass over the tree, visiting each folder's children largest
first, so a walk that reaches `maxVisitedNodes` has covered the big end of the volume
before the small one. It stops at 10,000,000 entries and sets `stoppedAtLimit`; the sheet
says the report is a sample, and it is a sample biased toward where the bytes are.

The cap exists because the sheet must finish: the walk is bounded work, off the main
actor, and cancellable, but a pathological tree (a whole volume of system files) must
still produce an answer. 10,000,000 entries cost roughly 2.4 s on the reference machine.

The walk reports the share of the tree it has accounted for — the entries it examined
plus the subtrees a whole-folder rule kept it out of — so the sheet can show a determinate
bar instead of a spinner. A walk stopped at the cap reports the share it reached;
only a walk that finished the tree reaches the end of the bar.

## Rules

Each rule is a section in the sheet with its own explanation, and its own cap.

| Rule | Matches | Shown | Tier |
|---|---|---|---|
| Caches | folders named `Caches` directly inside a `Library`, and Xcode `DerivedData` | 100 largest | rebuildable |
| Device support | `* DeviceSupport` folders directly inside Xcode | 100 largest | rebuildable |
| Simulators | `Devices` directly inside `CoreSimulator` | 100 largest | rebuildable |
| Logs | folders named `Logs` directly inside a `Library` | 100 largest | rebuildable |
| Old downloads | files in a folder named `Downloads`, unchanged for `downloadAge` | 100 largest | personal |
| Large and old | files whose local bytes are at least `largeFileMinimum` and whose modification date is at least `largeFileAge` old | 100 largest | personal |

A folder a rule offers is one finding: the walk does not descend into it, so a file
inside it is never listed a second time as large and old. The scan root is never offered:
the guard would refuse it, and a root that happens to be a cache is why the person is
looking.

### Tiers

- **Rebuildable** — the app or the system makes it again; removing one costs time.
- **Personal** — the person's own files. Nothing puts them back, so a section is never
  bulk-selected; each row is a choice.

The sheet groups its sections under these headings and offers "Select All" only in a
rebuildable section. A finding outside these tiers is not offered at all.

## Duplicates

Same size is a candidate, not a duplicate. Four steps:

1. Bucket files by `logicalSize`, at `duplicateMinimum` and above, largest sizes first.
   Only files stored locally take part; reading a dataless item would materialise it from
   iCloud, which is not something a review list may do uninvited.
2. The sheet shows the buckets with their exact group and file counts, capped at
   `maxDuplicateGroups` groups and `maxDuplicateFilesPerGroup` paths each.
3. **Check Contents** is explicit. It reads the first 128 KB of every candidate first:
   a size match and a matching prefix is what earns a full read, so a false pair usually
   costs a few kilobytes instead of a whole file. Files are read a few at a time, off the
   main actor, with byte progress and cancellation.
4. Only matching full digests become a group. Files that cannot be read are counted,
   never called duplicates; cancelling confirms nothing.

After Check Contents, the Duplicates tab and the section header read "N of M files": N
confirmed identical files out of the M same-size candidates. The "Compared" line and the
hard-link and clone notes account for the candidates that were not confirmed duplicates.

**Hard links are not duplicates.** When several paths resolve to one inode, none of them
is offered: moving one frees nothing while another remains. The sheet counts those paths
and says so. The scan's accounting still counts each path's bytes — the tree measures
paths, and the engine does not invent a canonical one — so a hard-linked file's size is
the same disclosure problem the explorer already has, not a new one.

**APFS clones are not copies either.** A file whose `ATTR_CMNEXT_CLONE_REFCNT` says its
blocks are shared is never read for a group and never offered as a copy: moving one frees
nothing until the other references go. The sheet counts those paths and says so, and a
group therefore needs at least two independent copies. This is deliberately conservative:
a genuine copy that happens to be identical to a clone is not offered on its own.

The confirmation's "Select All But One" leaves the first path in place, so acting on a
group never takes every copy.

## Selection and removal

A selection is a set of URLs. Before the footer totals or the move, the sheet reduces it
to the **outermost paths**: if both a folder and something inside it are selected, the
folder is what moves, and the inner path is neither counted nor offered twice. The same
reduction runs in `ScanViewModel` for every caller, so the confirmation lists what will
actually be moved.

The confirmation shows both numbers — on disk and logical size — and says when an item
is only partly stored locally. It opens **over** the cleanup sheet rather than replacing
it, so confirming or cancelling returns to the same list and the same place in it, and a
moved row disappears when the watched tree applies the change. When the tree cannot
follow — watching is off — the sheet closes instead and the results are marked stale,
because its list would keep offering items that are already gone. Moving does not free
space; emptying the Trash does, and the wording never claims otherwise.

### Moves and Put Back

Every successful move is written to a small log (`ReclaimLog`, bounded to the last 20
moves) holding each item's original path, where the system put it in the Trash, its
sizes, and when it was moved. The sheet's **Moved** tab shows the log newest first and
asks the Trash which pending items are still there: its count and size cover only those.
A copy that left the Trash without Put Back — restored in Finder, or the Trash emptied —
is labelled **Not in the Trash**, stays in the log, and is neither counted nor offered
for Put Back.

**Put Back** returns items from the Trash to their original paths. It is a move, not a
deletion, and it asks the filesystem again at the moment it runs: an item that is no
longer in the Trash is refused, and so is one whose old place has something in it now —
nothing is overwritten. Restored items are marked in the log, and the screen says what
could not be put back and why.

The app never empties the Trash. That is a permanent delete, and
[`ROADMAP.md`](ROADMAP.md) keeps it behind a deliberate decision; Put Back exists on the
other side of that line.

## Limits

| Limit | Value | Why |
|---|---|---|
| `maxCandidatesPerGroup` | 100 | the rows are eager, each publishes a frame for hover, and a review list is not an inventory |
| `maxDuplicateGroups` | 20 | bounded work for "Check Contents" (20 groups × 20 paths) |
| `maxDuplicateFilesPerGroup` | 20 | same |
| `maxVisitedNodes` | 10,000,000 | guarantees the sheet returns an answer on a pathological tree |

Every limit is disclosed where it bites: a truncated section says what it is showing, a
truncated size group says how many paths it keeps, and a stopped walk says the report is
a sample.

## Command line

`WillyDisk cleanup <folder> [--json] [--check-contents]` runs the same engine and the
same rules with no window and no UI loaded. The text report follows the interface
language; `--json` prints the versioned `CleanupRecord` (schema 1) whose keys and rule
identifiers stay English, so a script can read them in any language. `--check-contents`
is the command line's Check Contents, opt-in because it reads every candidate.

The command only lists. It has no move, no Trash, and no claim about freed space, and it
never changes the folder it read.

## Non-goals

- No permanent delete, secure erase, or Trash emptying — see the decision in
  [`ROADMAP.md`](ROADMAP.md).
- No rule for Xcode `Archives` (they hold the dSYMs of shipped builds), Photos libraries,
  Docker disks, other apps' containers, or anything inside an `.app` bundle.
- No estimate of space that cannot be measured, and no reconciliation of a folder scan
  against a volume's free space.
- No second filesystem pass: a rule reads only what the scan measured.

## Planned

- If the permanent-delete rule is ever changed: emptying only what the app moved, and a
  measured free-space delta after it. Neither exists today.

## Verification

`Tests/QATests/CleanupAnalysisQATests` pins the rules, the tiers, the caps, and the
disclosures; `DuplicateAnalysisQATests` pins the content check — the prefix and full
reads, hard links, clones, unreadable files, and cancellation; `ReclaimQATests` pins the
guard, the move log, and Put Back; `Tests/DiskCoreTests/ReclaimLogTests` pins the log's
file and bounds. `Tests/DiskCLITests/CleanupCommandTests` pins the command line and the
record's shape. A change to a rule is a change to a fixture there.
