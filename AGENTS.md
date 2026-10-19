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
| `Package.swift` | products: executable `WillyDisk`, libraries `DiskCore` and `DiskUI` |
| `Sources/DiskCore/Models/` | frozen value model: `FileCategory`, `ScanNode`, `ScanSummary` |
| `Sources/DiskCore/Scanning/Contracts.swift` | frozen `ScanRequest`, `ScanEvent`, `ScanProgress`, `ScanEngine`, `ScanIssueKind` |
| `Sources/DiskCore/Scanning/` (the rest) | the scan engine and its filesystem plumbing |
| `Sources/DiskUI/` | screens, components, design system |
| `Sources/WillyDiskApp/` | `@main` executable, window, wiring |
| `Tests/DiskCoreTests/` | engine tests |
| `Tests/QATests/` | independent verification that does not trust the engine's own tests |
| `Scripts/` | build, bundle, launch, offscreen render, repo map |
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

**`DiskUI` — SwiftUI.**
`ScanViewModel.swift` is the `@MainActor @Observable` state machine that consumes
`AsyncStream<ScanEvent>`. `Screens/ScanFlowView.swift` routes phases,
`Screens/SourceSelectionView.swift` is screen A, `Screens/ResultsView.swift` is screen C
(and the live in-progress state). `Components/SunburstView.swift` is the disk chart;
`AccessNoticeRow`, `FlowLayout` are the other views.
`DesignSystem/DesignSystem.swift` holds every token (`DS`), `ChartPalette.swift` the
chart fills, `FileCategory+UI.swift` the category symbols and labels, `AppAppearance.swift`
the stored system/light/dark appearance preference behind the first screen's toolbar.
`Support/` holds non-view helpers: `ExplorerQuery` (sorting/filtering), `Formatters`,
`LocationName` (a location's display name), `VolumeInfo` (mounted volumes),
`RecentLocations`, `FullDiskAccess` + `FullDiskAccessProbe` (TCC),
`ScanIssuesPresentation`, `ScanSlotPresentation`, `ReportExport` (JSON/CSV via
`NSSavePanel`), `AccessNoticeDismissal`.

**`WillyDiskApp`.**
`WillyDiskApp.swift` is `@main`, `AppState.swift` builds the single
`ScanViewModel(engine: FileScanEngine())`, `ContentView.swift` hosts `ScanFlowView`,
`AppDelegate.swift` is the lifecycle delegate.

## Commands

```
swift build                          # compile
swift test                           # full suite
swift test --filter FileScanEngineTests   # one test class
bash Scripts/run.sh                  # build the bundle and launch it (the way to look at the UI)
bash Scripts/render-screens.sh       # offscreen PNGs of the app's screens (-S results|home|both), no window, no screen-recording permission
bash Scripts/repo-map.sh             # one-screen structural inventory (--types adds declarations)
```

Do **not** use `swift run WillyDisk` to inspect the UI. SwiftPM stamps the executable's
linked SDK with the deployment target, so AppKit draws the legacy pre-Tahoe window
chrome. `Scripts/run.sh` goes through `Scripts/bundle-app.sh`, which restamps it; that
script fails loudly if the stamp is wrong. `docs/ARCHITECTURE.md` §6 has the details.
Inside an agent sandbox SwiftPM cannot nest its own sandbox, so prefix
`WILLYDISK_NO_SANDBOX=1` when running the render or bundle scripts, and add
`--disable-sandbox` to a plain `swift build` or `swift test`.

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
