# DiskUI — agent notes

SwiftUI + AppKit presentation layer. It consumes `DiskCore` and never
re-implements scanning: `ScanViewModel` drives a `ScanEngine` and renders what the event
stream reports.

## Structure

- `ScanViewModel.swift` — the `@MainActor @Observable` state machine over
  `AsyncStream<ScanEvent>`. Owns the scan phases and the presentation types the screens
  render (`ScanIssue`, `ScanIssuesPresentation`, `ScanSlotPresentation`).
- `Screens/` — `ScanFlowView` routes phases; `SourceSelectionView` is screen A;
  `ResultsView` is screen C and also the live in-progress state; `HelpView` is the
  help sheet's content; `SettingsView` is the preferences window. Scanning is not a
  separate screen.
- `Components/` — `SunburstView` (the disk chart: wedges drawn in one static layer,
  with the hover emphasis painted over them), `CategoryRingView` (the scan by
  category, one ring; opening a category charts its files with `SunburstView`),
  `WedgeEmphasis` (the one hover/selection overlay both charts paint),
  `CleanupSheet` (large/old, cache, download, and duplicate candidates that go to the
  reclaim confirmation), `HistorySheet` (the recorded runs of a location, two compared),
  `AccessNoticeRow`, `FlowLayout`, `ScanOptionToggle` (one scan option, shared by the
  source screen's sheet and Settings), `ResultsStatusBadges` (the single watching/updating
  chip and the stale marker), `ControlStyles` (the shared row hover, inline and icon
  actions, and warning notice).
- `DesignSystem/` — `DesignSystem.swift` holds every token (`DS`), `ChartPalette.swift`
  the chart fills, `FileCategory+UI.swift` the category symbols and labels,
  `AppAppearance.swift` the stored system/light/dark preference the Settings window
  edits, `AppLanguage.swift` the stored System/English/العربية interface-language
  choice, `GrooveMark.swift` the packaged circular mark
  (`Resources/AppMark.png`) that the hero, the chart placeholder, Help, and About draw
  from — it is an image, not a shape drawn in code.
- `Support/` — non-view helpers: `ExplorerQuery` (sorting/filtering), `ScanSearch`
  (the bounded whole-scan name search, run off the main actor) + `ExplorerPath` (the
  folder chain a search result drills to), `Formatters`,
  `LocationName` (a location's display name), `VolumeInfo`, `RecentLocations`,
  `FullDiskAccess` + `FullDiskAccessProbe`, `ScanIssuesPresentation`,
  `ScanSlotPresentation`, `ReportExport` (JSON/CSV through `NSSavePanel`),
  `CategoryBreakdown` (sizes by category), `CategoryFiles` (a category's largest
  files, walked off the main actor), `CleanupAnalysis` (bounded large/old, cache, and
  download heuristics over the finished tree, including same-size duplicate
  candidates), `DuplicateAnalysis` (the explicit SHA-256 content check and its
  cancellable controller), `ScanOptions` + `ScanOptionsStore` (the one shared,
  persisted set of choices the next scan and Rescan use), `ScanHistory` (the observable
  view of the record store; finished scans are recorded through it, off the main actor),
  `WatchPreferences` (the stored keep-current choice), and `TreeWatching` (the watcher
  seam the tests substitute).

## Rules

- Take spacing, corner radii, type, and colors from `DS`. No magic numbers in views.
- Every user-visible string comes from `L10n` (`DiskLocalization`), never from a literal
  in a view. Use `L10n.string` for text and `L10n.format` for a value; a count noun is a
  catalog plural entry, not `count == 1 ? … : …` in code. Add the English, Arabic, and
  `en-XA` values to the catalog, then run `bash Scripts/localize.sh`.
- Leading and trailing are logical: layout mirrors when the interface language is
  right-to-left. Do not pin a pane to `.left` or `.right`; review `-l ar` and
  `-l en-XA` renders, which is where longer translations and truncation show up.
- A pointer hover must not re-derive what it did not change. The chart's wedges are
  drawn once and the emphasis is a shade and an outline over them; the hover the list
  and the chart share is `ChartHover` in `Screens/ResultsView.swift`, so a hover
  re-renders the list and the chart and leaves the rest of the screen alone.
- Light and dark must both be polished; controls stay keyboard-accessible.
- Verbs are part of the control vocabulary: "Cancel Scan" stops a scan,
  "Cancel" dismisses a modal task, and "Dismiss" hides a notice.
- Liquid Glass is an enhancement only: gate macOS 26 APIs behind
  `if #available(macOS 26.0, *)`. Never call a newer API unguarded.
- A watched change is an invalidation, not an edit. `ScanViewModel` names the changed
  folder and marks the results stale; a refresh keeps the old summary on screen,
  publishes no partial/progress/issue, and replaces it only with the terminal summary.
  Refreshes are not recorded in History. A refresh is not a live scan: `isLiveScan` is
  `isScanning && !isRefreshing`, and a stopped refresh leaves the old summary complete
  and stale.
- `.partial` snapshots are advisory — the engine may throttle or omit them — and are
  never terminal. Update in place; the terminal `.finished` replaces them. The scan
  root's entries arrive ready-made in `ScanSummary.rootChildren`, folders included
  while their subtrees are still being walked: never assemble them from the capped
  lists by matching paths.
- Search is a list scope, not a chart: the sunburst's wedges partition one folder's
  bytes, and a search's matches overlap. The chart pane says so while a query is open.
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
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S help -c -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S settings -c -s 460x760 -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S categories -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S coverage -c -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S search -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S results -l ar -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a light -S results -l en-XA -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S cleanup -c -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S duplicates -c -o .build/renders/<change>
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S history -c -o .build/renders/<change>
```

`-S` picks the screen: `results` (default), `home` (source selection), `search` (the
results screen with a whole-scan query open), `categories` (the results screen in
Categories mode), `coverage` (the coverage sheet), `help` and `settings` (the sheet and
preferences contents), `cleanup` and `duplicates` (the cleanup sheet's two tabs; they
scan the same sample tree), `history` (the comparison sheet over that scan plus two older
sample runs), or `both` (home and results). `-l` picks the interface language: `en`
(default), `ar` for the finished right-to-left translation, or `en-XA` for the
doubled-length pseudolanguage. The locale is part of the PNG's name.

The `-o` matters: renders are named after their size and appearance, so reusing a
directory reuses the path, and a viewer that already loaded it keeps showing the cached
bitmap. Give each review its own directory, and if a screenshot looks stale against the
source, read it from a path that has never been rendered before re-rendering anything.
`.agents/skills/willydisk-verify/` has the rest of the capture procedure.
