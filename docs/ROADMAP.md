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
  tab at `1ed5184`, scan history with its comparison sheet, the command-line
  scan (`38f6e50`), the unsigned GitHub release pipeline (`7bec1d0`), the
  watched-tree refresh (`b8be044`), global search over the whole finished scan
  (`e7d6fff`), and the localization pass (`7c7c067`). This docs handoff follows it.
- Build: `swift build --disable-sandbox`.
- Tests: 310 QATests + 153 DiskCoreTests (3 skipped; the benchmark tests need
  `WILLYDISK_BENCH_ROOT`) + 30 DiskCLITests + 83 DiskUpdateTests, 0 failures.
- CI: `.github/workflows/ci.yml` builds, tests, checks that the bundle reports
  `VERSION`, runs the bundled binary's `scan` and its usage exit status, and uploads
  the offscreen renders on every push. `.github/workflows/release.yml` runs on a `v*`
  tag: it checks the tag against `VERSION`, builds arm64 and x86_64, and publishes
  both zips with their SHA-256s and the unsigned warning on the release page.
- Distribution: `Scripts/package-release.sh` produces
  `WillyDisk-<VERSION>-arm64.zip` and `WillyDisk-<VERSION>-x86_64.zip`, each with a
  `.sha256`. The bundles are ad-hoc signed, which is what lets them run on Apple
  Silicon, and they are unsigned in the Developer ID sense and not notarized. The
  release notes and README state that plainly, with the one-time approval step and
  the source-build alternative. `v1.0.0` and `v1.0.1` are tagged; `v1.0.1` is
  published and the repository is public, so the release assets and the tap are
  reachable without credentials.
- The working tree adds the update path: the `DiskUpdate` core (version ordering,
  the GitHub release feed, asset selection, the `.sha256` check, `ditto`
  extraction, and staged-bundle validation), the downloader with real progress, the
  controller, consent sheet, menu, and Settings toggle in `DiskUI`, and the detached
  install transaction (`UpdateInstaller.swift`) with its backup, swap, result, and
  relaunch. The Homebrew cask template declares `auto_updates true`. The remaining
  gate is a real update over `/Applications`: TCC/Full Disk Access, the App
  Management prompt, and the relaunch. `docs/UPDATES.md` is the contract.
- The app is a working single-window analyzer: choose a volume, folder, or quick
  preset, watch a progressive scan, read the sunburst and explorer, search the whole
  scan by name and drill from a result to its folder, inspect
  coverage, see where the bytes sit by file category, review large/old/cache candidates,
  check possible duplicates by their contents before trashing them, compare the recorded
  runs of a location, select rows with the mouse or keyboard, preview them with Quick
  Look, move items to the Trash behind a guard and confirmation, change the scan defaults
  and excluded paths in Settings, keep settled results current when the scanned tree
  changes, and read About or Help. It exports the analysis report as JSON or CSV, and a
  diagnostics report for support that names no user file. The same binary also scans a
  folder from the command line, as text or as the record JSON, with no window.

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
| Command-line scan over the same engine, with the record DTO as JSON | `38f6e50` |
| Watched results: FSEvents invalidation and a quiet root refresh | `b8be044` |
| Global search over the whole scan: bounded, off the main actor, drill to folder | `e7d6fff` |
| Unsigned GitHub releases: arm64 and x86_64 zips, checksums, tag workflow | `7bec1d0` |
| String catalog, Arabic (right to left), pseudolanguage, renderer `--locale` | `7c7c067` |

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
  year for large-and-old, six months for downloads), and a threshold applies to the
  bytes an item occupies on this Mac: an evicted iCloud file or a sparse file is not a
  candidate, because moving it would free nothing. Every size the sheet shows is the
  space a move would return. Each section keeps at most 100, and the walk stops after
  10,000,000 nodes. It visits each folder's largest entries first, so a stopped walk is
  a sample of the big end of the tree, and both a truncated section and a stopped walk
  say so. Four rebuildable rules offer one folder each with the subtree left unwalked —
  `Library/Caches` and Xcode `DerivedData`, Xcode's `* DeviceSupport` sets,
  `CoreSimulator/Devices`, and `Library/Logs` — and two personal rules list files: old
  downloads and large-and-old ones. The sheet groups the sections by tier and offers
  "Select All" only in a rebuildable one. The scan root is never suggested. Every move
  goes through the reclaim confirmation; the analysis itself deletes nothing.
- `WillyDisk cleanup <folder> [--json] [--check-contents]` runs the same rules from
  `DiskCore` with no UI loaded. The text report follows the interface language; `--json`
  prints the versioned `CleanupRecord` with English keys and rule identifiers, and
  `--check-contents` is the opt-in content check. It lists only: no move, no Trash, and
  no saving claim.
- Every successful move is logged (the most recent 20 batches) with each item's original
  path and where the system put it in the Trash, and the cleanup sheet's Moved tab lists
  them newest first. Put Back returns items from the Trash to their old place, checking
  both paths at the moment it runs: a missing Trash copy or an occupied destination is
  refused and named, nothing is overwritten, and restored items are marked in the log. It
  is a move, never a deletion, and the app still does not empty the Trash.
- The cleanup sheet has three tabs: Candidates for the rebuildable and personal rules,
  Duplicates, and Moved. It opens on Candidates, or on Duplicates when Candidates has
  nothing to show, and while it is open it follows the watched tree: a watcher batch
  queues another walk after a short pause, one walk runs at a time, and the old list
  stays until the new report is ready.
  Duplicate candidates are same-size files of at least 1 MB that are stored locally,
  capped to the largest 20 size groups and 20 files per group; every file in a shared size
  is counted before the cap and a truncated group says so. A size match is not a
  duplicate: Check Contents reads a 128 KB prefix of every candidate before the whole
  file, a few files at a time, off the main actor with byte progress and cancel, and only
  matching contents are listed. A cancelled check confirms nothing, unreadable files are
  counted rather than called identical, and paths that resolve to the same inode are
  disclosed as hard links and never offered as copies either, just like paths whose blocks
  are shared with another file (an APFS clone); the sheet claims no saving. Moving a
  copy goes through the reclaim confirmation; hard links remain separate paths and moving
  one frees nothing until the other links are gone.
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
- Watched results read a live tree. The stream is item-level: each file or folder that
  moved is reduced to the folder it changes, and events carrying no creation, removal,
  rename, or write are dropped, because attribute, owner, xattr, and clone metadata
  cannot change a measured number. `LiveTreeUpdater` reconciles each changed folder —
  files from their own `stat`, vanished entries removed, a folder that arrived measured
  once — under the scan's own `LiveTreePolicy`, applies the batch after 200 ms of quiet,
  and bumps one revision. Nothing is re-scanned, so there is no refresh budget and no
  run that is "too slow to keep current": a whole-disk scan is as live as a home folder
  (a re-listing measured 0.05 ms and an edit 1.19 µs on a 4.6M-entry tree). The stale
  marker is only for a screen that cannot follow — no tree, or the watch switched off.
  `ScanSummary` remains the scan's record for History, the CLI, export, diagnostics and
  coverage. The watcher is armed only while settled results are on the results
  screen; it stops on Home, on a new scan, on cancellation, and when the root is gone.
  The scope applies the engine's exclusions and `stayOnVolume` device rule, and maps
  `/System/Volumes/Data/…` back to `/…` because that is how FSEvents names the startup
  disk's data volume. `docs/LIVE-TREE.md` is the design, the invariants, and the stages.
- Search covers the whole tree the scan carries, from every explorer mode, not the folder
  or the ranked list on screen. The field's query replaces the list's scope only: the mode,
  the breadcrumb, and the sort are untouched, so clearing the field restores exactly the
  list that was there.
  The walk runs off the main actor behind a 250 ms quiet period, cancels on the next
  keystroke, and matches names case- and diacritic-insensitively; a query containing `/`
  is a path query and also matches each entry's full path, which is how `Photos/2024`
  finds what lives there without a one-letter query returning every path on the disk. It
  keeps the largest 200 matches, counts every one, and stops after 2,000,000 entries,
  saying on the summary line what it is showing and whether the walk stopped. Each row
  names the folder that holds it; Show in Folder (and Return on a folder result) clears
  the search and re-roots the explorer there, with the result selected. The chart pane is
  not a chart of the matches — the sunburst's wedges partition one folder's bytes, and a
  matched file inside a matched folder would be counted twice — so it says what the
  search found and that clearing the field brings the folder chart back. A live scan is
  searched as it stands and the search re-runs when the terminal summary lands, as it
  does after a quiet refresh; the live summary line says “so far”. Search never records
  history and never edits the tree.
- History opens from the results toolbar (or Scan ▸ History…) for the location on the
  engine's slot, and compares two of its runs. The current run is recorded as it
  settles; the sheet picks the two newest by default and lets any two be chosen. Clear
  History… removes every record for every location and touches no user file.
- Diagnostics and report export are different documents. Export ▸ Export Diagnostics…
  writes one JSON file (`schemaVersion` 1) with the run's choices (booleans and an
  exclusion **count**, never the paths), its timing and which measurement that timing
  came from, its measured totals and accounting, its issue counts, and the app's
  version, build, macOS version and build, architecture, and interface language. It
  carries no file name, path, excluded location, or file content. A finished run's
  timing is its own endpoints; a stopped one says it is the last snapshot; a live one
  uses the engine's clock and reports no totals until a snapshot exists; a quiet refresh
  reports the completed run still on screen as `refreshing`. The save panel says what
  the file does and does not contain. Report export (JSON/CSV) is the separate document
  that names paths.
- The command line is a front end over the same `FileScanEngine`, not a second scanner:
  `DiskCLI` depends on `DiskCore` only, and the executable's `@main` routes
  `WillyDisk scan …` (or a leading option such as `--help`) before SwiftUI is touched,
  so no `NSApplication`, window, or Dock icon exists. `--depth` and `--top` are print
  widths: the walk still measures everything, and `--json` keeps the engine's ranked
  capacity. The report and the record order every list size-first and path-second,
  because the engine ranks equal sizes arbitrarily; the JSON is the versioned
  `ScanRecord` and differs between runs only in its `id` and two timestamps. It carries
  no volume facts, which describe the whole disk and move while the command runs. A
  CLI scan writes no history record: the record goes to stdout, and only the app
  records runs. Exit statuses are 0 finished, 1 missing folder or unwritable report,
  2 usage, and 130 cancelled; SIGINT/SIGTERM call `ScanEngine.cancel()`, and a
  cancelled run prints no report.
- The results toolbar carries no separate title or path, and the system title item is
  removed so the app name does not sit between the controls. It holds a Home button and
  a folder trail: the scanned location is always named, ancestors are clickable, and the
  current folder is text. Home returns to source selection; the trail covers stepping
  up, and the chart's spindle hole is the same move in the chart — up one folder, or back
  to all categories when one is open. There is no toolbar Back action.
- Every user-visible string is looked up through `L10n`
  (`Sources/DiskLocalization/L10n.swift`) in one catalog,
  `Sources/DiskLocalization/Localizable.xcstrings`, keyed by the English source with
  `%@`/`%lld` placeholders. SwiftPM cannot compile that catalog without asking
  `xcstringstool` to derive Swift symbols, and format-only keys cannot all be symbols, so
  `Scripts/localize.sh` compiles it into committed `en.lproj`, `ar.lproj`, and
  `en-XA.lproj` resources; `--check` fails when they are stale. The app bundle copies
  the resource bundle and declares `CFBundleLocalizations` `en`/`ar`; the renderer links
  the same target, so a render and the app read one table. Arabic is the finished
  language, including all six plural categories; `en-XA` is generated, not written, and
  is the doubled-length pass for spotting truncation, regenerated from the English
  values by `Scripts/pseudolanguage.py`. The CLI's text and errors are
  localized too, and its report aligns each value under the widest translated label;
  the `ScanRecord` JSON stays machine data and is never localized. The app resolves the
  right-to-left direction from the chosen language, so `ar` mirrors the results,
  coverage, cleanup, settings, and Help without a separate layout. A guard test fails
  when a user-visible literal bypasses the catalog, when a source key is missing, or
  when a catalog key has no call site.
- Settings ▸ Language offers System, English, and العربية. The choice is stored under
  `appLanguage`, applied before SwiftUI builds the first window, and re-pins `L10n` when
  it changes, so the interface text and its reading direction change without relaunch;
  System clears the override and follows the macOS language, including a per-app choice.
  Each language is written in its own script, so a reader can find their language
  whatever the current one is. The rows reuse the Appearance section's full-row radio
  and arrow-key handling. The in-app choice changes WillyDisk's own windows and sheets;
  macOS panels and the CLI keep following the system language.

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
swift test --disable-sandbox --filter DiskUpdateTests
swift test --disable-sandbox --filter UpdateQATests
swift run --disable-sandbox WillyDisk scan . --depth 1 --top 5
swift run --disable-sandbox WillyDisk scan . --json | jq -e '.schemaVersion == 1'
python3 Scripts/pseudolanguage.py --check
bash Scripts/localize.sh --check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S both -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S categories -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S search -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S help -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S settings -c -s 460x760 -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S update -c -s 640x600 -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S update-ready -c -s 640x600 -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S cleanup -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S duplicates -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S history -c -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S results -l ar -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S coverage -c -l ar -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S cleanup -c -l ar -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S settings -c -s 460x760 -l ar -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S update -c -s 640x600 -l ar -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S update-ready -c -s 640x600 -l ar -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a light -S results -l en-XA -o .build/renders/check
WILLYDISK_NO_SANDBOX=1 bash Scripts/package-release.sh
```

CI runs the localization freshness check, the build, the suite, the bundle version
check, a bundled `scan` plus its usage exit status, and the renders — including Arabic
results, home, coverage, cleanup, settings, and the update sheet (offer and ready),
and the pseudolanguage results and coverage — on every push. `Scripts/package-release.sh` builds both
slices, expands each archive, and checks its architecture, version, and ad-hoc signature
before writing the two SHA-256s; `.github/workflows/release.yml` runs that on a `v*` tag,
re-checks both checksums, and publishes only when the tag matches `VERSION`. On an Apple
Silicon host the script executes only the arm64 slice; the Intel slice is checked by
`lipo` and `codesign`, so an Intel launch still needs an Intel Mac or Rosetta.

`-l ar` renders the finished Arabic translation and mirrors the layout; `-l en-XA`
renders the doubled-length pseudolanguage, which is how truncation shows up in review.
The locale is part of each PNG's name, so an English and an Arabic render of the same
size never overwrite each other. `-S coverage` renders the coverage sheet, which is a
sheet and therefore needs `-c`.
`-S categories` renders the real results screen in Categories mode, window and all.
`-S search` renders the same screen with a whole-scan search open (`p` over the fixture,
which every folder there has a match for), so the match list, the containing paths, the
summary line, and the chart's search state are reviewable. Help, Settings, the update
sheet (offer and ready), and the cleanup sheet are sheets or a preferences window, so
`-S` captures their content. Settings renders with its own non-default sample options and two exclusions, so
the switches and the list are both reviewable; cleanup, duplicates, and moved are the
cleanup sheet's three tabs. They use one sample tree (sparse files with set
ages, two identical copies, and one same-size different file), so the Candidates render
shows the other sections and the Duplicates render shows a completed content check.
History renders the sheet over the finished fixture scan plus two older recorded runs, so
the comparison shows grown, new, and shrunk entries; it needs `-c` because it is a sheet.
For any sheet without a screen state, the working practice is a temporary `@MainActor` QA
test that hosts the view in `NSHostingView`, renders it with `cacheDisplay`, writes a PNG
under `.build/renders/`, and is deleted before commit. Do not ship a renderer hook for a
one-off visual check.

## Remaining work, in recommended order

### 1. Performance and polish

- Performance guardrails for million-file scans; the benchmark test is currently
  skipped unless an environment variable points at a root. The ceiling should become
  structural, not only measured: a per-directory node cap with small files folded into
  one expandable node, so a multi-million-file tree cannot grow the resident set without
  bound. That changes which files the explorer can open, so it needs its own design note.
- Polish: coverage discoverability, folder-level coverage disclosure, CSV accounting
  (JSON has it, CSV does not), empty states, window sizing, accessibility audit.

### 2. Treemap as a second chart

Boxes instead of rings, same tree, same selection, hover and drill-down, chosen in
Settings. The sunburst stays the identity; the treemap exists for dense folders where
arcs are too thin to compare.

Acceptance: layout runs off the main actor for a large folder; one selection model
drives both charts; reduce-motion and keyboard navigation behave as in the sunburst; both
charts render in CI.

### 3. Reclaim past the Trash

Today the only removal path is Move to Trash, and Trash frees nothing until it is emptied.
Put Back (returning an item from the Trash to where it came from) ships with the move log;
this item is about deletion, not about undoing.
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

### 4. Remote and cloud scans

Scan a machine reachable over SSH, and cloud remotes, through the same explorer.
`ScanEngine` is the seam: a second conformance that emits the same events, so the UI never
learns about transports. Credentials, key handling, a remote helper, and network failure
modes are the real work; traversal is not.

Acceptance: an SSH scan of the standard fixture folder produces the same totals as a local
scan of it; a dropped connection ends in `.finished` with issues or `.cancelled`, never a
stream that hangs; credentials never reach the export DTO or a diagnostics bundle; nothing
is scanned remotely without an explicit host choice.

### 5. Self-update, and platforms beyond macOS

Self-update becomes worth shipping once a tagged release exists: the GitHub Release list is
the feed, the published SHA-256 is the download check, and a relaunch follows. Windows and
Linux are a larger step — a UI without AppKit, per-platform packaging, per-platform
filesystem semantics — and wait until a tagged macOS release has actually shipped.

Acceptance (self-update): a newer version is offered with its notes; the download is
verified against the release's published SHA-256 before it replaces anything; a failed
check or download changes nothing and says why; the app never updates without consent;
the update screen does not call an unsigned download verified or trusted.

The feed, verification core, downloader, controller, sheet, and install transaction are
implemented: version comparison, `releases/latest`, selection of the two assets by
architecture and exact name, the published `.sha256` check, `ditto` extraction,
staged-bundle identity/minimum-macOS/architecture/`codesign` validation, real download
progress, the daily check, skip, the Settings and menu wiring, and the detached
`/bin/sh` helper that backs up the old app, swaps in the staged one, writes a result,
and reopens the app. `Tests/DiskUpdateTests/` (including the real helper against fake
app directories) and `Tests/QATests/UpdateQATests.swift` hold the suites, and
`docs/UPDATES.md` is the contract. The cask template declares `auto_updates true`.
Remaining: one real update over `/Applications` to settle TCC/Full Disk Access, App
Management, and the relaunch, then a release that carries the updater.

## Decisions to preserve

- Startup disk is a volume group with firmlinks; never reconcile a `/` scan against
  the `/` capacity figure. The coverage sheet explains, it does not subtract.
- Hard links are not deduplicated. Each path counts in every total, and which link is
  “first” is arbitrary under concurrent traversal. Cleanup offers none of a multi-link
  file's paths: moving one frees nothing while another remains.
- Dataless files are counted at logical size, with local bytes reported separately.
- A cleanup finding is sized by local bytes, and its threshold applies to them. A file
  that is not stored on this Mac is not a finding: moving it frees nothing, and reading
  it would download it. The scan's accounting still counts dataless files at logical
  size, so cleanup is a promise about reclaimable space, not a second measurement.
- A hard link is not a duplicate, and neither is an APFS clone. Duplicate checking offers
  none of a multi-link file's paths and none of a clone's, because moving one frees
  nothing until the other references go; the counts are disclosed. The tree still counts
  each path's bytes, which is the accounting the explorer already uses.
- Snapshots are listed by name only. macOS exposes no snapshot size; do not estimate
  one.
- Trash does not free space until it is emptied; result wording must say so.
- A move reaches the tree like any other change. Moving an item to the Trash produces
  filesystem events, and the watched tree applies them; the screen updates without
  Rescan. When nothing can follow — watching is off, or the results never became a live
  tree — they are marked stale and Rescan is offered. A long run is never repeated
  automatically.
- The app is a single window. Coverage, reclaim, cleanup, history, and Help are sheets
  on the main window.
- Watching edits the live tree with measured changes; it never invents one. A folder is
  re-listed, a file is written from its own `stat`, and a folder that arrived is
  measured once with the engine, under the scan's own rules. A `ScanSummary` is never
  edited; it stays the record of the run that produced it.
- Live updates change the screen, not History. History records the finished runs the
  user started; the tree following the disk must not write records or push them out of
  the 20-per-location record.
- History compares measurements, never claims savings. Only a finished scan the user
  started is recorded, and a stored run's options travel with it so a difference in what each
  walk included is disclosed rather than read as a change on disk.
- Search results are a list, not a chart. A sunburst's wedges partition one folder's
  bytes; a search's matches overlap (a matched file can sit inside a matched folder), so
  drawing them would sum the same bytes twice and state a whole the app cannot explain.
  The chart pane says the chart maps one folder at a time and comes back when the field is
  cleared.
- No Apple Developer account, no Developer ID, no notarization. The bundle stays ad-hoc
  signed and every release artifact is plainly unsigned. Do not add signing or
  notarization steps that need credentials, and never describe the app as signed,
  notarized, or Gatekeeper-approved. Building from source is the first-class install path;
  the downloaded zips are offered with their checksums and one-time approval instructions.
- Releases are two thin archives, arm64 and x86_64, not one universal build, and each
  carries its own SHA-256. The release notes say which Mac gets which; do not fold them
  into one download without a reason recorded here.
- Self-update is hand-rolled: no third-party package, no Developer ID, no silent
  install, no privileged helper. The feed is GitHub's public `releases/latest`; the
  release's published SHA-256 and the staged bundle's identity, architecture, and
  ad-hoc signature are checked before anything is replaced. A checksum match is
  integrity, never a claim that the build is trusted. Automatic checking is a
  preference; installation is always a click. The helper backs up the old app in
  `Updates/Recovery/<version>/`, restores it on failure, and never deletes that
  recovery copy from a later download. `docs/UPDATES.md` is the contract.
- The interface stays native AppKit and SwiftUI, so VoiceOver, Quick Look, menus, text
  editing and window chrome are the system's. A custom-drawn canvas is not an acceptable
  substitute for a chart or a list.
- One catalog is the only source of user-visible text. English is the source and the
  fallback; a key is the English sentence with its placeholders, never a symbolic name.
  Arabic is the finished language and carries Arabic's plural categories; `en-XA` is a
  generated pseudolanguage for truncation review, not a language to ship. A count is one
  catalog entry with plural variations, never a number concatenated with a noun in code.
- The compiled `.lproj` tables are generated by `Scripts/localize.sh` and committed,
  because SwiftPM's catalog path insists on deriving Swift symbols that format-only keys
  cannot provide. Edit the catalog, run the script, and let the CI freshness check defend
  the agreement. The app ships the resource bundle and declares its languages; the
  pseudolanguage is removed from the app bundle.
- The command line's report and help are localized, but the `ScanRecord` JSON is not:
  keys, category raw values, and schema fields are an interface, not prose.

## Suggested opening prompt

> Read `docs/ROADMAP.md`. Verify `HEAD` and run the build and tests. Implement item 1,
> the performance guardrails: first write the design note for a per-directory node cap
> that folds small files into one expandable node, then give the benchmark a structural
> ceiling as well as a measured one. Keep frozen contracts untouched unless the note
> argues for a change, and update `docs/ARCHITECTURE.md` with it. Do not commit unless I
> ask.
