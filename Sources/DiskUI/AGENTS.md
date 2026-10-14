# DiskUI — agent notes

SwiftUI + AppKit presentation layer. It consumes `DiskCore` and never
re-implements scanning: `ScanViewModel` drives a `ScanEngine` and renders what the event
stream reports.

## Structure

- `ScanViewModel.swift` — the `@MainActor @Observable` state machine over
  `AsyncStream<ScanEvent>`. Owns the scan phases and the presentation types the screens
  render (`ScanIssue`, `ScanIssuesPresentation`, `ScanSlotPresentation`).
- `Screens/` — `ScanFlowView` routes phases; `SourceSelectionView` is screen A;
  `ResultsView` is screen C and also the live in-progress state. Scanning is not a
  separate screen.
- `Components/` — `SunburstView` (the disk chart), `CategoryBar`,
  `AccessNoticeRow`, `FlowLayout`.
- `DesignSystem/` — `DesignSystem.swift` holds every token (`DS`), `ChartPalette.swift`
  the chart fills, `FileCategory+UI.swift` the category colors and labels,
  `AppAppearance.swift` the stored system/light/dark preference behind the first
  screen's toolbar menu.
- `Support/` — non-view helpers: `ExplorerQuery` (sorting/filtering), `Formatters`,
  `VolumeInfo`, `RecentLocations`, `FullDiskAccess` + `FullDiskAccessProbe`,
  `ScanIssuesPresentation`, `ScanSlotPresentation`, `ReportExport` (JSON/CSV through
  `NSSavePanel`), `AccessNoticeDismissal`.

## Rules

- Take spacing, corner radii, type, and colors from `DS`. No magic numbers in views.
- Light and dark must both be polished; controls stay keyboard-accessible.
- Liquid Glass is an enhancement only: gate macOS 26 APIs behind
  `if #available(macOS 26.0, *)`. Never call a newer API unguarded.
- `.partial` snapshots are advisory — the engine may throttle or omit them — and are
  never terminal. Update in place; the terminal `.finished` replaces them.
- `Screens/ResultsView.swift` and `Components/SunburstView.swift` are large. Grep for
  the view or modifier you need instead of reading them whole.

## Looking at the UI

`bash Scripts/run.sh` builds the bundle and launches it — that is the only way to see
real window chrome. `swift run WillyDisk` draws the legacy pre-Tahoe window
(`docs/ARCHITECTURE.md` §6). For an offscreen capture with no window and no
Screen Recording permission:

```
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S home -o .build/renders/<change>
```

`-S` picks the screen: `results` (default), `home` (source selection), or `both`.

The `-o` matters: renders are named after their size and appearance, so reusing a
directory reuses the path, and a viewer that already loaded it keeps showing the cached
bitmap. Give each review its own directory, and if a screenshot looks stale against the
source, read it from a path that has never been rendered before re-rendering anything.
`.agents/skills/willydisk-verify/` has the rest of the capture procedure.
