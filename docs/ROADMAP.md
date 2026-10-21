# WillyDisk roadmap

What is shipped, what remains, and how to continue without re-deriving the product
decisions. This is a handoff document, not a specification of frozen interfaces —
`docs/ARCHITECTURE.md` is the source of truth for those.

## Current state

- The current code is the Explorer trust pass (`f6c8ca5`), quick-scan presets and
  request exclusions (`c53d8b5`), the engraved-platter identity and macOS alignment
  (`17a7e29`, `794cd6a`), the results and Home polish through `fdbc450`, the
  install-trust work at `d7155dc`, the packaged circular mark at `55f5032`, the
  cleanup candidates at `9a69a3b`, the Categories mode at `71bae92`, the
  Settings work at `607ef77`, the duplicate content check at `3603321` with its own
  tab at `1ed5184`, and scan history with its comparison sheet; this docs handoff
  follows it. Working tree clean at that handoff.
- Build: `swift build --disable-sandbox`.
- Tests: 168 QATests + 68 DiskCoreTests, 0 failures, 1 skipped
  (`ScanBenchmarkTests` needs `WILLYDISK_BENCH_ROOT`).
- CI: `.github/workflows/ci.yml` builds, tests, checks that the bundle reports
  `VERSION`, and uploads the offscreen renders on every push.
- The app is a working single-window analyzer: choose a volume, folder, or quick
  preset, watch a progressive scan, read the sunburst and explorer, inspect
  coverage, see where the bytes sit by file category, review large/old/cache candidates,
  check possible duplicates by their contents before trashing them, compare the recorded
  runs of a location, select rows with the mouse or keyboard, preview them with Quick
  Look, move items to the Trash behind a guard and confirmation, change the scan defaults
  and excluded paths in Settings, and read About or Help.

## Shipped — do not rebuild

| Area | Commit |
|---|---|
| Provenance line, This Folder / Top Files / Top Folders, scan options | `c0ca677` |
| Guarded Move to Trash, confirmation sheet, stale results + Rescan | `0915068`, `8beef48` |
| Coverage sheet, volume/snapshot facts, hard-link/dataless/skip accounting | `abce87a` |
| Explorer selection, keyboard navigation, Quick Look, batch reclaim, breadcrumb, folder inspector | `f6c8ca5`, `45d3dc0`, `7a7bb90`, `99c8b64` |
| Quick-scan presets, request exclusions, coverage disclosure | `c53d8b5` |
| Engraved-platter identity, macOS alignment, Settings window | `17a7e29`, `794cd6a` |
| Settings for scan defaults and excluded paths | `607ef77` |
| Version from `VERSION`, About panel, in-app Help, CI | `d7155dc` |
| Category breakdown (Categories mode and its category detail), cleanup candidates through reclaim | `9a69a3b`, `71bae92`, `6266abc`, `031dbda` |
| Duplicate candidates with an explicit SHA-256 content check, and their own tab | `3603321`, `1ed5184` |
| Scan history: a versioned record per finished scan, and the comparison sheet | `5b07181` |

Details worth remembering:

- Coverage is opened by the **ⓘ button** in the results toolbar. It is icon-only and
  easy to miss; making it more discoverable is still open.
- `ScanAccounting` records hard-link overlaps, dataless files, skipped links,
  volumes, and special files, plus excluded-item counts. Totals are not
  deduplicated; the overlap is disclosed, and an excluded size is never invented.
- Reclaim is Trash-only. `ReclaimPolicy` refuses the scan root or an ancestor, volume
  roots, the home directory, protected system locations, read-only volumes, missing
  items, and any move while scanning. A successful move marks results stale; it does
  not edit the tree or auto-rescan.
- Scan presets are shortcuts, not a second scan path: each starts the same scan,
  options, cancellation, and permission handling as choosing the folder by hand.
  A missing preset stays visible and disabled.
- Exclusions are resolved once before traversal. An exclusion equal to or above the
  scan root is ignored; a nested exclusion is skipped without being entered, and its
  contents stay out of every total and ranking. Identity is matched before canonical
  path, so an unrelated hard link is not mistaken for the excluded path. Coverage
  reports the count as "Skipped by your exclusions" and never estimates the size of
  what was not read.
- Settings and the source screen's Scan Options sheet edit one
  `ScanOptionsStore.shared`. Both windows observe that object and every mutation is
  persisted, so neither can hold a private copy; Rescan reads the store, not the
  options its previous run began with. Adding an exclusion, removing one, or changing
  a default never edits the results already on screen — the next scan, including
  Rescan, reads the new choices. Appearance stays an app preference in the same
  window.
- The marketing version has one source: `VERSION`. `Scripts/bundle-app.sh` validates
  it, stamps `CFBundleShortVersionString` from it, and takes `CFBundleVersion` from
  the commit count; CI fails when the assembled bundle disagrees. About is the
  system panel with the app's own credits: it reads the bundle's name, version, and
  copyright, and shows the circular in-app mark rather than the rounded macOS icon.
- The mark has two bodies, drawn once by `Scripts/make-icon.swift`: the rounded
  square macOS asks for in `Resources/AppIcon.icns`, and the circle in
  `Sources/DiskUI/Resources/AppMark.png` that the UI and About show. The mark is a
  packaged image, so the renderer and any scratch host that hosts `DiskUI` must run
  beside `WillyDisk_DiskUI.bundle`; `Scripts/bundle-app.sh` copies that bundle into
  the app's Resources.
- Help is a sheet on the main window (⌘?), not a window of its own, so the app keeps
  one window. It restates the scan, coverage, and reclaim rules in short form;
  `Scripts/render-screens.sh -S help` renders it so the copy can be reviewed.
- The category breakdown is a fourth explorer mode, not a sheet: the chart pane draws
  one ring of the scan's categories, and the explorer lists the same slices. It reads
  `summary.categoryBreakdown`, which counts files by logical size — directories carry no
  bytes, and hard links count once per link. Shares are of the scan's own total, never of
  the categorised subset, and a share rounds to “<1%” rather than 0% or to “99%” rather
  than 100%.
- Choosing a slice or a row opens that category in place: the mode stays Categories and
  the list becomes the category's files, charted as its own sunburst with one wedge per
  listed file and hover and selection shared with the rows — the same chart/list pairing
  This Folder has. While the walk is loading, the ring shows the category outlined, and
  “All Categories” above the list closes it. The files come from a walk over the finished
  tree, run off the main actor and capped at 100 with every match still counted; a live
  scan uses the engine's ranked list and says it is the largest so far, then reloads when
  the root node lands. There is no category menu and no category filter: the mode is the
  only way in.
- Cleanup candidates come from the finished tree the summary already carries, never
  from a second filesystem pass. `CleanupPolicy` states the thresholds (500 MB and a
  year for large-and-old, six months for downloads), keeps at most 100 per section, and
  stops after 2,000,000 nodes; a truncated section and a stopped walk both say so.
  Caches are recognised by path (`Library/Caches`, Xcode `DerivedData`), offered as one
  folder with the subtree left unwalked, and the scan root is never suggested. Every
  move goes through the reclaim confirmation; the analysis itself deletes nothing.
- The cleanup sheet has two tabs: Old for large-and-old, cache, and old-download
  candidates, and Duplicates. It opens on Old, or on Duplicates when Old has nothing to
  show. Duplicate candidates are same-size files of at least 1 MB, capped to the largest
  20 size groups and 20 files per group; every match is counted and a truncated group
  says so. A size match is not a duplicate: Check Contents streams SHA-256 digests off
  the main actor with byte progress and cancel, and only matching contents are listed. A
  cancelled check confirms nothing, unreadable files are counted rather than called
  identical, and the sheet claims no saving. Moving a copy goes through the reclaim
  confirmation; hard links remain separate paths and moving one frees nothing until the
  other links are gone.
- Explorer selection is held as URLs, not node values, so a live snapshot can replace
  the nodes underneath it. Entering a folder, changing mode, a breadcrumb jump,
  Rescan, and Home clear it; search and filtering do not. Each scan revision prunes
  URLs that have left the list.
- Quick Look rechecks that every target still exists off the main thread before the
  panel is shown. Batch Quick Look, Reveal, and Move to Trash act on the whole
  selection; Move to Trash re-runs the per-item reclaim guard for every candidate.
- History is a versioned record, not the scan made codable. `ScanRecord`
  (`Sources/DiskCore/History/`) stores `schemaVersion`, timestamps, totals, counts,
  category sizes, the two ranked lists (100 entries at the current capacity), accounting,
  the scan options, and the volume facts — never the tree. One JSON file per finished scan lives under
  `~/Library/Application Support/WillyDisk/History/`, at most 20 per location and 100
  overall; the oldest fall off. A file with another schema version or unreadable bytes
  is skipped, reported, and never deleted by pruning, because a newer release may know
  what it says. A cancelled scan is not recorded: its totals cover part of the root, and
  comparing it with a complete run would present missing work as space that vanished.
- Comparison has two kinds of answer. Totals, counts, and the category breakdown are
  exact, because a scan measures every entry it walked. The ranked folders and files are
  each run's largest 100, matched by path, and labelled New, Grown, Shrunk, or Unchanged;
  when the earlier list was full its cut-off size is stated, so “New” is explained as
  absent from that list rather than certainly new. Entries that left the later list are
  counted, not called removals. Runs with different scan options say so: the difference
  may be what each walk included. Nothing in the comparison is called a saving.
- History opens from the results toolbar (or Scan ▸ History…) for the location on the
  engine's slot, and compares two of its runs. The current run is recorded as it
  settles; the sheet picks the two newest by default and lets any two be chosen. Clear
  History… removes every record for every location and touches no user file.
- The results toolbar carries no separate title or path, and the system title item is
  removed so the app name does not sit between the controls. It holds a Home button and
  a folder trail: the scanned location is always named, ancestors are clickable, and the
  current folder is text. Home returns to source selection; the trail covers stepping
  up, and the chart's spindle hole is the same move in the chart — up one folder, or back
  to all categories when one is open. There is no toolbar Back action.

## Ground rules

- `Sources/DiskCore/Models/**` and `Sources/DiskCore/Scanning/Contracts.swift` are
  frozen. A change is a design change: explain it and update
  `docs/ARCHITECTURE.md` §3/§4 in the same change.
- No third-party packages. macOS 14 deployment target.
- All filesystem work stays off the main actor; scans emit progressive `.partial`
  snapshots and exactly one terminal event.
- No fabricated progress, statistics, or reconciliation. No permanent-delete path.
  No automatic deletion. No tree surgery after a move.
- Comments are evergreen: no task numbers, no narration of what a change fixed.
- Do not use `swift run WillyDisk` to look at the UI; use `Scripts/run.sh` or the
  offscreen renderer.

## Verification

```bash
swift build --disable-sandbox
swift test --disable-sandbox
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S both -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S categories -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S help -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S settings -c -s 460x760 -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S cleanup -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S duplicates -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S history -c -o .build/renders/check
```

CI runs the build, the suite, the bundle version check, and all seven renders on every push.

`-S categories` renders the real results screen in Categories mode, window and all.
Help, Settings, and the cleanup sheet are sheets or a preferences window, so `-S`
captures their content. Settings renders with its own non-default sample options and two
exclusions, so the switches and the list are both reviewable; cleanup and duplicates are
the cleanup sheet's two tabs. They use one sample tree (sparse files with set ages, two
identical copies, and one same-size different file), so the Old render shows the other
sections and the Duplicates render shows a completed content check. History renders the
sheet over the finished fixture scan plus two older recorded runs, so the comparison
shows grown, new, and shrunk entries; it needs `-c` because it is a sheet. For any sheet
without a screen state, the working practice is a temporary `@MainActor` QA test that
hosts the view in `NSHostingView`, renders it with `cacheDisplay`, writes a PNG under
`.build/renders/`, and is deleted before commit. Do not ship a renderer hook for a
one-off visual check.

## Remaining work, in recommended order

### 1. Developer ID signing, notarization, and a DMG

The bundle is ad-hoc signed and does not ship as a notarized artifact. This needs an
Apple Developer ID certificate and credentials, so it cannot be finished without them;
write the scripts, document every input, and do not claim a notarized build until one
verifies.

- A DMG build script around `.build/WillyDisk.app`.
- `codesign` with a Developer ID and `notarytool` submission, plus a check that the
  stapled ticket validates.
- CI publishing the DMG on a tag, only when the signing secrets are present.

### 2. Global search

Search the whole finished scan, not just the current folder or the stored top 100.
The UI has the root’s tree in the summary, but a multi-million-file tree needs a
bounded, debounced search and virtualized results. Show the containing path and let a
result drill to its folder.

Acceptance: searching a deep path finds it; results are bounded and say so; typing
does not block the main actor; clearing restores the previous scope.

### 3. Diagnostics, performance, and polish

- Export a diagnostics bundle (scan settings, timing, issue counts, version) with no
  user file contents.
- Performance guardrails for million-file scans; the benchmark test is currently
  skipped unless an environment variable points at a root. The ceiling should become
  structural, not only measured: a per-directory node cap with small files folded into
  one expandable node, so a multi-million-file tree cannot grow the resident set without
  bound. That changes which files the explorer can open, so it needs its own design note.
- Polish: coverage discoverability, general staleness detection (only reclaim marks
  stale today), folder-level coverage disclosure, CSV accounting (JSON has it, CSV
  does not), pluralization, empty states, window sizing, accessibility audit.

### 4. A command-line scan

`WillyDisk scan <folder> --depth --top --json` over the same `FileScanEngine`: no second
scanner and no second accounting path. The JSON is the versioned record DTO the history
work introduced (`ScanRecord`), not `ScanSummary` made codable. Answering from an
already-running scan is a later refinement; a CLI that scans on its own is the first
release.

Acceptance: exit 0 on success and 2 on a usage error; `--help` lists the flags; no window
appears and no UI is built; SIGINT takes the engine's cancellation path and says so;
output for a fixture folder is byte-stable across runs.

### 5. Watch the scanned tree

FSEvents on the scan root while results are on screen, so a change made in Finder is
reflected without Rescan. The shape is invalidation, not patching: a change marks the
affected folder stale and re-scans it, because `ScanSummary` is a measurement of a moment
and must never be edited in place.

Acceptance: moving a file to the Trash in Finder updates that folder's totals within a
few seconds and offers Rescan; events outside the root and under excluded paths are
ignored; the watcher stops on cancellation, on leaving the screen, and on a new scan; a
`/` scan does not install a watch per volume.

### 6. Treemap as a second chart

Boxes instead of rings, same tree, same selection, hover and drill-down, chosen in
Settings. The sunburst stays the identity; the treemap exists for dense folders where
arcs are too thin to compare.

Acceptance: layout runs off the main actor for a large folder; one selection model
drives both charts; reduce-motion and keyboard navigation behave as in the sunburst; both
charts render in CI.

### 7. Localization

Extract every user-visible string into a catalog keyed by the English source, then finish
one language end to end before adding more. SwiftUI supplies script fallback and RTL
layout; the work is string discipline, not font plumbing.

Acceptance: no user-visible literal outside the catalog; a pseudolanguage render pass
catches truncation; one RTL language (`ar`) renders results, coverage and cleanup without
clipping; plurals are resolved rather than concatenated; the render harness takes a
`--locale`.

### 8. Reclaim past the Trash

Today the only removal path is Move to Trash, and Trash frees nothing until it is emptied.
The fuller flow is permanent delete, a secure erase that overwrites before removing, and
an optional copy to another folder or an external drive first — all behind the existing
confirmation, cancellable, and reporting bytes moved and errors rather than a savings
claim.

This needs a decision before any code: the ground rules say "No permanent-delete path",
and that rule stands until it is deliberately changed and recorded here. It is the only
item in this list that can destroy data nobody selected for destruction, so it needs its
own review of the guard, the wording, and the failure modes — a delete that stopped
halfway, a backup that failed, a read-only destination.

Acceptance, once the rule is changed: the guard runs again for every item at the moment
of removal; a permanent delete cannot be reached without a typed or held confirmation; a
failed backup removes nothing; a cancelled job says what was and was not removed; no
screen claims space was freed before it was.

### 9. Remote and cloud scans

Scan a machine reachable over SSH, and cloud remotes, through the same explorer.
`ScanEngine` is the seam: a second conformance that emits the same events, so the UI never
learns about transports. Credentials, key handling, a remote helper, and network failure
modes are the real work; traversal is not.

Acceptance: an SSH scan of the standard fixture folder produces the same totals as a local
scan of it; a dropped connection ends in `.finished` with issues or `.cancelled`, never a
stream that hangs; credentials never reach the export DTO or a diagnostics bundle; nothing
is scanned remotely without an explicit host choice.

### 10. Self-update, and platforms beyond macOS

Self-update is worth shipping only after item 1: a release feed, a verified download, and
a relaunch. Windows and Linux are a larger step — a UI without AppKit, per-platform
packaging, per-platform filesystem semantics — and wait until a signed macOS release
actually ships.

Acceptance (self-update): a newer version is offered with its notes; the download is
verified before it replaces anything; a failed check or download changes nothing and says
why; the app never updates without consent.

## Decisions to preserve

- Startup disk is a volume group with firmlinks; never reconcile a `/` scan against
  the `/` capacity figure. The coverage sheet explains, it does not subtract.
- Hard links are not deduplicated. The exact overlap is disclosed; which link is
  “first” is arbitrary under concurrent traversal.
- Dataless files are counted at logical size, with local bytes reported separately.
- Snapshots are listed by name only. macOS exposes no snapshot size; do not estimate
  one.
- Trash does not free space until it is emptied; result wording must say so.
- A move marks results stale and offers Rescan; it does not edit the tree or start an
  automatic full-disk rescan.
- The app is a single window. Coverage, reclaim, cleanup, history, and Help are sheets
  on the main window.
- History compares measurements, never claims savings. Only a finished scan is
  recorded, and a stored run's options travel with it so a difference in what each
  walk included is disclosed rather than read as a change on disk.
- The interface stays native AppKit and SwiftUI, so VoiceOver, Quick Look, menus, text
  editing and window chrome are the system's. A custom-drawn canvas is not an acceptable
  substitute for a chart or a list.

## Suggested opening prompt

> Read `docs/ROADMAP.md`. Verify `HEAD` and run the build and tests. Implement the
> Developer ID signing, notarization, and DMG work: write the scripts and document
> every input, keep the ad-hoc bundle path working without credentials, and do not
> claim a notarized build until one verifies. If the certificate and `notarytool`
> credentials are unavailable, stop after the scripts and documentation and say what
> is missing. Keep frozen contracts untouched, then commit.
