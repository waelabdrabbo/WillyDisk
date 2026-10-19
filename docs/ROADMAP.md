# WillyDisk roadmap

What is shipped, what remains, and how to continue without re-deriving the product
decisions. This is a handoff document, not a specification of frozen interfaces —
`docs/ARCHITECTURE.md` is the source of truth for those.

## Current state

- `HEAD` is the Explorer trust pass (`f6c8ca5`) plus this handoff update; working
  tree clean.
- Build: `swift build --disable-sandbox`.
- Tests: 109 QATests + 48 DiskCoreTests, 0 failures, 1 skipped
  (`ScanBenchmarkTests` needs `WILLYDISK_BENCH_ROOT`).
- The app is a working single-window analyzer: choose a volume or folder, watch a
  progressive scan, read the sunburst and explorer, inspect coverage, select rows
  with the mouse or keyboard, preview them with Quick Look, and move items to the
  Trash behind a guard and confirmation.

## Shipped — do not rebuild

| Area | Commit |
|---|---|
| Provenance line, This Folder / Top Files / Top Folders, scan options | `c0ca677` |
| Guarded Move to Trash, confirmation sheet, stale results + Rescan | `0915068`, `8beef48` |
| Coverage sheet, volume/snapshot facts, hard-link/dataless/skip accounting | `abce87a` |
| Explorer selection, keyboard navigation, Quick Look, batch reclaim, breadcrumb, folder inspector | `f6c8ca5` |

Details worth remembering:

- Coverage is opened by the **ⓘ button** in the results toolbar. It is icon-only and
  easy to miss; making it more discoverable is still open.
- `ScanAccounting` records hard-link overlaps, dataless files, and skipped links,
  volumes, and special files. Totals are not deduplicated; the overlap is disclosed.
- Reclaim is Trash-only. `ReclaimPolicy` refuses the scan root or an ancestor, volume
  roots, the home directory, protected system locations, read-only volumes, missing
  items, and any move while scanning. A successful move marks results stale; it does
  not edit the tree or auto-rescan.
- Explorer selection is held as URLs, not node values, so a live snapshot can replace
  the nodes underneath it. Entering a folder, changing mode, Back, a breadcrumb jump,
  Rescan, and Home clear it; search and filtering do not. Each scan revision prunes
  URLs that have left the list.
- Quick Look rechecks that every target still exists off the main thread before the
  panel is shown. Batch Quick Look, Reveal, and Move to Trash act on the whole
  selection; Move to Trash re-runs the per-item reclaim guard for every candidate. The
  breadcrumb is clickable and hidden at the scanned root, where the header already
  names the folder.

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
```

Sheets are not reachable from the renderer's screen states. The working practice is a
temporary `@MainActor` QA test that hosts the view in `NSHostingView`, renders it with
`cacheDisplay`, writes a PNG under `.build/renders/`, and is deleted before commit.
Do not ship a renderer hook for a one-off visual check.

## Remaining work, in recommended order

### 1. Scan presets and exclusions

Presets are UI shortcuts and need no contract change: Home, Downloads, Applications,
Library/Caches, Xcode DerivedData, Trash.

Exclusions do need a frozen `ScanRequest` change: a set of canonical excluded paths,
pruned by the scanner, counted separately, and disclosed in the coverage sheet as
“Skipped by your exclusions”. Update `docs/ARCHITECTURE.md` §4 and the coverage
accounting model. Do not silently hide excluded bytes.

Acceptance: a preset starts a real scan of that location; exclusions are visible
before the scan starts, persisted, applied, and reported; tests cover a nested
excluded path, an excluded root, and a symlink edge.

### 2. Install and distribution trust

The app is ad-hoc signed, has no icon, no notarized DMG, no About/Settings window, and
no CI.

- App icon and `CFBundleIconFile`.
- Version from one source, not hardcoded `1.0`.
- Developer ID signing and notarization; a DMG build script.
- About window, Help, and a Settings scene (appearance, defaults, exclusions).
- CI that builds and tests every change, plus the renderer as a visual check.

This is cheap compared with history/compare and directly answers “is this safe to
install?”.

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

- A category breakdown screen already has the data: `summary.categoryBreakdown`.
  Add a chart/legend and a way to filter the explorer by category.
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
- The app is a single window. Coverage and reclaim are sheets on the results screen.

## Suggested opening prompt

> Read `docs/ROADMAP.md`. Verify `HEAD` and run the build and tests. Implement scan
> presets and path exclusions — presets as UI shortcuts, exclusions through the
> `ScanRequest` contract change and coverage disclosure described in the roadmap — as
> one PR if it stays coherent. Update `docs/ARCHITECTURE.md` §4 for the contract
> change and verify with tests and light/dark renders, then commit.
