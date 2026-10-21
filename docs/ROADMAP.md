# WillyDisk roadmap

What is shipped, what remains, and how to continue without re-deriving the product
decisions. This is a handoff document, not a specification of frozen interfaces —
`docs/ARCHITECTURE.md` is the source of truth for those.

## Current state

- The current code is the Explorer trust pass (`f6c8ca5`), quick-scan presets and
  request exclusions (`c53d8b5`), the engraved-platter identity and macOS alignment
  (`17a7e29`, `794cd6a`), the results and Home polish through `fdbc450`, and the
  install-trust work at `d7155dc`; this docs handoff follows on top. Working tree
  clean.
- Build: `swift build --disable-sandbox`.
- Tests: 119 QATests + 51 DiskCoreTests, 0 failures, 1 skipped
  (`ScanBenchmarkTests` needs `WILLYDISK_BENCH_ROOT`).
- CI: `.github/workflows/ci.yml` builds, tests, checks that the bundle reports
  `VERSION`, and uploads the offscreen renders on every push.
- The app is a working single-window analyzer: choose a volume, folder, or quick
  preset, watch a progressive scan, read the sunburst and explorer, inspect
  coverage, select rows with the mouse or keyboard, preview them with Quick Look,
  move items to the Trash behind a guard and confirmation, and read About or Help.

## Shipped — do not rebuild

| Area | Commit |
|---|---|
| Provenance line, This Folder / Top Files / Top Folders, scan options | `c0ca677` |
| Guarded Move to Trash, confirmation sheet, stale results + Rescan | `0915068`, `8beef48` |
| Coverage sheet, volume/snapshot facts, hard-link/dataless/skip accounting | `abce87a` |
| Explorer selection, keyboard navigation, Quick Look, batch reclaim, breadcrumb, folder inspector | `f6c8ca5`, `45d3dc0`, `7a7bb90`, `99c8b64` |
| Quick-scan presets, request exclusions, coverage disclosure | `c53d8b5` |
| Engraved-platter identity, macOS alignment, Settings window | `17a7e29`, `794cd6a` |
| Version from `VERSION`, About panel, in-app Help, CI | `d7155dc` |

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
- Explorer selection is held as URLs, not node values, so a live snapshot can replace
  the nodes underneath it. Entering a folder, changing mode, a breadcrumb jump,
  Rescan, and Home clear it; search and filtering do not. Each scan revision prunes
  URLs that have left the list.
- Quick Look rechecks that every target still exists off the main thread before the
  panel is shown. Batch Quick Look, Reveal, and Move to Trash act on the whole
  selection; Move to Trash re-runs the per-item reclaim guard for every candidate.
- The results toolbar carries no separate title or path, and the system title item is
  removed so the app name does not sit between the controls. It holds a Home button and
  a folder trail: the scanned location is always named, ancestors are clickable, and the
  current folder is text. Home returns to source selection; the trail covers stepping
  up, so there is no Back action.

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
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S help -c -o .build/renders/check
```

CI runs the build, the suite, the bundle version check, and both renders on every push.

Help is reachable because it is a view: `-S help` captures its content, not the sheet
presentation. For any other sheet, the working practice is a temporary `@MainActor` QA
test that hosts the view in `NSHostingView`, renders it with `cacheDisplay`, writes a
PNG under `.build/renders/`, and is deleted before commit. Do not ship a renderer hook
for a one-off visual check.

## Remaining work, in recommended order

### 1. Settings for scan defaults and exclusions

Appearance is the only preference in Settings. `ScanOptionsStore` already persists the
scan defaults and excluded paths, but they can only be changed on the source screen
before a scan starts. Add Settings sections that edit the same store — hidden items,
other volumes, symbolic links — and list the resolved exclusions with a way to remove
one. One store only: Settings and the Scan Options sheet must never hold different
values.

Acceptance: a change in Settings is what the next scan and Rescan use; the Scan Options
sheet shows the same values; removing an exclusion changes the next scan's totals and
never edits the tree already on screen.

### 2. Developer ID signing, notarization, and a DMG

The bundle is ad-hoc signed and does not ship as a notarized artifact. This needs an
Apple Developer ID certificate and credentials, so it cannot be finished without them;
write the scripts, document every input, and do not claim a notarized build until one
verifies.

- A DMG build script around `.build/WillyDisk.app`.
- `codesign` with a Developer ID and `notarytool` submission, plus a check that the
  stapled ticket validates.
- CI publishing the DMG on a tag, only when the signing secrets are present.

### 3. History and compare

Persist finished scan summaries and compare two runs of the same root: what grew,
what shrank, what appeared. `ScanSummary` is not `Codable`; introduce a versioned
export DTO rather than making the frozen model codable by accident. Do not persist
the full tree; store counts, top lists, accounting, and volume facts.

Acceptance: schema version is checked on read; a corrupt store degrades to no history;
comparison labels “new”, “grown”, “shrunk”, and “unchanged” with real numbers; no
fabricated savings claim.

### 4. Global search

Search the whole finished scan, not just the current folder or the stored top 100.
The UI has the root’s tree in the summary, but a multi-million-file tree needs a
bounded, debounced search and virtualized results. Show the containing path and let a
result drill to its folder.

Acceptance: searching a deep path finds it; results are bounded and say so; typing
does not block the main actor; clearing restores the previous scope.

### 5. Category breakdown and cleanup suggestions

- The data is already in `summary.categoryBreakdown`: add a chart and legend of the
  sizes by category. The explorer's category menu filters already, so the chart only
  has to show the split and offer that same filter.
- Cleanup suggestions are heuristics: large and old, caches, duplicate candidates
  (hash only on explicit user action), stale downloads. Never auto-delete; route
  every action through the reclaim sheet.

### 6. Diagnostics, performance, and polish

- Export a diagnostics bundle (scan settings, timing, issue counts, version) with no
  user file contents.
- Performance guardrails for million-file scans; the benchmark test is currently
  skipped unless an environment variable points at a root.
- Polish: coverage discoverability, general staleness detection (only reclaim marks
  stale today), folder-level coverage disclosure, CSV accounting (JSON has it, CSV
  does not), pluralization, empty states, window sizing, accessibility audit.

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
- The app is a single window. Coverage, reclaim, and Help are sheets on the main
  window.

## Suggested opening prompt

> Read `docs/ROADMAP.md`. Verify `HEAD` and run the build and tests. Implement the
> Settings work: sections for scan defaults and excluded paths that edit
> `ScanOptionsStore`, so the source screen's Scan Options sheet and Settings always
> show the same values. Keep frozen contracts untouched, verify light/dark with the
> renderer, then commit.
