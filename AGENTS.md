# WillyDisk — agent notes

WillyDisk is a native macOS disk-space analyzer: SwiftUI + AppKit, deployment target
macOS 14, built with Swift Package Manager (no `.xcodeproj`).

**This file is injected into every session automatically, and it is the orientation.
Do not spend a session rediscovering the layout — read this and start on the task. A
question like "what is this project?" or "where does the scan engine live?" is answerable
from here.** Area-specific rules live in nested `AGENTS.md` files; those are injected
automatically the first time you read or edit a file in that directory, so never go
looking for them.

`README.md` is the public description for users and adds nothing you need in order to
orient — the summary above and the map below are the orientation. Go deeper only when the
task needs it: `CONTRIBUTING.md` (conventions) and `docs/ARCHITECTURE.md` (frozen
contracts, shared-interface rules §7, non-negotiables §8).

## Layout

| Path | What it holds |
|---|---|
| `Package.swift` | products: executable `WillyDisk`, libraries `DiskCore` and `DiskUI`; target `DiskCLI` |
| `VERSION` | the only source of the marketing version; the bundle script stamps it |
| `Resources/` | the macOS icon: `AppIcon.icns` and its 1024 `AppIcon-1024.png` |
| `Sources/DiskUI/Resources/AppMark.png` | the circular in-app mark the UI and About show |
| `Sources/DiskCore/Models/` | frozen value model: `FileCategory`, `ScanNode`, `ScanSummary` |
| `Sources/DiskCore/History/` | `ScanRecord` (versioned DTO), `ScanHistoryStore`, `ScanComparison` |
| `Sources/DiskCore/Scanning/Contracts.swift` | frozen `ScanRequest`, `ScanEvent`, `ScanProgress`, `ScanEngine`, `ScanIssueKind` |
| `Sources/DiskCore/Scanning/` (the rest) | the scan engine and its filesystem plumbing |
| `Sources/DiskCLI/` | the `WillyDisk scan` front end: parsing, text report, `ScanRecord` JSON |
| `Sources/DiskUI/` | screens, components, design system |
| `Sources/WillyDiskApp/` | `@main` executable, window, wiring, CLI/GUI dispatch |
| `Tests/DiskCoreTests/` | engine tests |
| `Tests/DiskCLITests/` | command-line parsing, report stability, exit statuses |
| `Tests/QATests/` | independent verification that does not trust the engine's own tests |
| `Scripts/` | build, bundle, launch, offscreen render, repo map |
| `.github/workflows/ci.yml` | build, test, bundle version check, CLI smoke, renders |
| `docs/` | `ARCHITECTURE.md` |

## Where things are

**`DiskCore` — pure logic, no UI.**
`Models/` is the data shape. `Scanning/Contracts.swift` is the frozen protocol surface.
`Scanning/FileScanEngine.swift` is the async engine (`ScanEngine` conformance:
traversal scheduling, cancellation, progressive `.partial` snapshots).
`Scanning/FileScanner.swift` holds traversal plus the `FileSystemAccess` seam that lets
tests inject permission failures. `Scanning/DirectoryReader.swift` is bulk directory
enumeration, `FileStat.swift` wraps `lstat`/`stat`, `FileCategorizer.swift` maps names
onto `FileCategory`, `ScanErrorClassifier.swift` maps errno onto `ScanIssueKind`.
`History/` stores finished runs: `ScanRecord.swift` is the versioned record DTO (never
the tree), `ScanHistoryStore.swift` the one-file-per-run store, and
`ScanComparison.swift` the totals/category/entry comparison.

**`DiskUI` — SwiftUI.**
`ScanViewModel.swift` is the `@MainActor @Observable` state machine that consumes
`AsyncStream<ScanEvent>`. `Screens/ScanFlowView.swift` routes phases,
`Screens/SourceSelectionView.swift` is screen A, `Screens/ResultsView.swift` is screen C
(and the live in-progress state), `Screens/HelpView.swift` is the help sheet's content,
`Screens/SettingsView.swift` is the preferences window. `Components/SunburstView.swift`
is the disk chart; `AccessNoticeRow`, `FlowLayout`, and `ScanOptionToggle` are the other
views.
`Components/HistorySheet.swift` is the scan-history comparison, backed by
`Support/ScanHistory.swift` (the `@Observable` view of the record store).
`DesignSystem/DesignSystem.swift` holds every token (`DS`), `ChartPalette.swift` the
chart fills, `FileCategory+UI.swift` the category symbols and labels, `AppAppearance.swift`
the stored system/light/dark appearance preference the Settings window edits.
`Support/` holds non-view helpers: `ExplorerQuery` (sorting/filtering), `Formatters`,
`LocationName` (a location's display name), `VolumeInfo` (mounted volumes),
`RecentLocations`, `FullDiskAccess` + `FullDiskAccessProbe` (TCC),
`ScanIssuesPresentation`, `ScanSlotPresentation`, `ReportExport` (JSON/CSV via
`NSSavePanel`), `AccessNoticeDismissal`, `ScanOptions` + `ScanOptionsStore` (the one
shared, persisted set of choices the next scan and Rescan use), `CleanupAnalysis` +
`DuplicateAnalysis` (bounded cleanup heuristics and the explicit SHA-256 content check),
`ScanHistory` (the observable view of the record store).

**`WillyDiskApp`.**
`WillyDiskApp.swift` holds the `@main` entry (`WillyDiskEntry`) that routes `WillyDisk
scan …` to `DiskCLI` before SwiftUI is touched, then the `App` itself. `AppState.swift`
builds the single `ScanViewModel` with `FileScanEngine` and the shared options store,
`ContentView.swift` hosts `ScanFlowView`, `AboutPanel.swift` presents the system About
panel, `AppDelegate.swift` is the lifecycle delegate.

**`DiskCLI` — the command line.**
`ScanCommand.swift` parses `scan <folder> --depth --top --json` and holds the help text;
`ScanCLI.swift` decides CLI vs app, drives `FileScanEngine`, and maps the terminal event
to an exit status (SIGINT/SIGTERM call `ScanEngine.cancel()`); `ScanReport.swift` renders
the deterministic text report and the `ScanRecord` JSON. It depends on `DiskCore` only,
so a scan never loads AppKit or SwiftUI. `--depth` and `--top` change what is printed,
never what is scanned or recorded.

## Commands

```
swift build                          # compile
swift test                           # full suite
swift test --filter FileScanEngineTests   # one test class
swift run WillyDisk scan <folder> --json  # command-line scan: no window, no UI loaded
bash Scripts/run.sh                  # build the bundle and launch it (the way to look at the UI)
bash Scripts/bundle-app.sh           # assemble .build/WillyDisk.app; its version comes from VERSION
bash Scripts/render-screens.sh       # offscreen PNGs (-S results|home|help|settings|categories|cleanup|duplicates|history|both), no window, no screen-recording permission
bash Scripts/repo-map.sh             # one-screen structural inventory (--types adds declarations)
```

`Scripts/make-icon.swift` draws both bodies from one mark: `Resources/AppIcon.icns` with
the rounded body macOS asks for, and `Sources/DiskUI/Resources/AppMark.png` as the circle
the hero, the chart, Help, and About show. Both are committed; the UI reads its mark from
DiskUI's resource bundle, which `Scripts/bundle-app.sh` copies into the app. Never draw a
second mark in code.

For a cosmetic change, stop early: edit, `swift build`, one render into a fresh directory
(`bash Scripts/render-screens.sh -a both -S <screen> -o .build/renders/<change>`), then
read the one PNG you need — a screenshot you read stays in the conversation and is re-sent
on every later step. The full ladder in `.agents/skills/willydisk-verify/` is for changes
that touch the engine, the bundle, or window chrome.

Do **not** use `swift run WillyDisk` to inspect the UI. SwiftPM stamps the executable's
linked SDK with the deployment target, so AppKit draws the legacy pre-Tahoe window
chrome. `Scripts/run.sh` goes through `Scripts/bundle-app.sh`, which restamps it; that
script fails loudly if the stamp is wrong. `docs/ARCHITECTURE.md` §6 has the details.
Inside an agent sandbox SwiftPM cannot nest its own sandbox. The render script detects
that and retries by itself; for the bundle script prefix `WILLYDISK_NO_SANDBOX=1`, and
add `--disable-sandbox` to a plain `swift build` or `swift test`.

## Recon rules — the cheap way to look at this repo

- **Never glob `**/*`.** It reaches ignored paths and reports thousands of entries,
  most of them `.build` byproducts. Enumerate with `git ls-files`, and search with the
  `grep` tool, which honours `.gitignore`.
- **`Sources/DiskUI/Screens/ResultsView.swift` and `Components/SunburstView.swift` are
  large.** Grep for the view or modifier you need instead of reading them whole. So is
  `Sources/DiskCore/Scanning/FileScanner.swift`.
- **Screenshots are not committed.** `Scripts/render-screens.sh` writes them into
  `.build/renders`, which is gitignored — there is nothing to read in the repository.
- Run `bash Scripts/repo-map.sh` when the map above looks stale; it prints one screen of
  paths, per-area line counts, the largest sources, and the working-tree status
  (`--types` adds every file's top-level declaration).

## Deeper context, loaded only when you ask

`docs/ROADMAP.md` records what is shipped, the remaining work in recommended order,
the decisions that must not be re-litigated, and a suggested opening prompt for a
fresh session.

`.agents/skills/willydisk-verify/` holds the end-to-end verification procedure (build,
test, bundle, launch, offscreen capture, and the SDK-stamp trap). It is offered as a
skill and its body loads only when you invoke it, so it costs nothing until then. Put
new repeatable procedures there rather than growing this file.

## Comment rule (non-negotiable)

Comments are evergreen explanations of current intent and behavior.

- Never cite a task, issue, or bug number. That belongs in the tracker and the commit
  message.
- Never narrate the bug a change fixed, or what the code did before.
- Point at durable references instead: other types, `docs/ARCHITECTURE.md`, or
  `Sources/DiskCore/Scanning/Contracts.swift`.

See `CONTRIBUTING.md` for the same rule addressed to human contributors.

## Shared interfaces

`Sources/DiskCore/Models/**` and `Sources/DiskCore/Scanning/Contracts.swift` are frozen.
A change to either is a design change: explain it and update `docs/ARCHITECTURE.md` in the
same change rather than diverging silently. `docs/ARCHITECTURE.md` §7 has the details.
