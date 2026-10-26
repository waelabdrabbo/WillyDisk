# WillyDisk — Architecture & Shared Contracts

> The frozen Architecture & Shared Contracts document. A change to a shared interface is
> a design change: raise it in an issue or a pull request, and update this document in
> the same change — do not silently diverge.

## 1. Environment (verified)

- macOS 27.0.1, Xcode 27.0, Swift 6.4.
- No xcodegen/tuist. `git`, `jq`, `python3` available.
- **Project workspace (repo root):** this repository.

## 2. Project layout — Swift Package Manager (no `.xcodeproj`)

Deployment target **macOS 14**.

```
Package.swift
Sources/
  DiskCore/                 # pure logic, no UI
    Models/                 # frozen value model
    Scanning/               # scan engine implementations
    Scanning/Contracts.swift# frozen protocols/types
    Watching/               # FSEvents watcher + the scope that filters its events
    Live/                   # the live results tree: arena, edits, updater, build from a scan
    History/                # scan records, the per-run store, the comparison
    Cleanup/                # cleanup rules + policy, the SHA-256 content check, and the move log
  DiskLocalization/         # string catalog + L10n (Foundation only)
    Localizable.xcstrings   #   source of truth; compiled into Resources/*.lproj
  DiskCLI/                  # `WillyDisk scan` and `cleanup` front end (DiskCore + DiskLocalization)
  DiskUI/                   # SwiftUI + design system
    DesignSystem/
    Components/
    Screens/
  WillyDiskApp/             # @main executable, window, wiring, CLI/GUI dispatch
Tests/
  DiskCoreTests/            # engine tests
  DiskCLITests/             # command-line parsing, report, exit statuses
  QATests/                  # independent verification
Scripts/bundle-app.sh       # builds the .app bundle
Scripts/RenderScreens/      # the offscreen renderer (package executable)
docs/                       # ARCHITECTURE.md, LIVE-TREE.md, CLEANUP.md, ROADMAP.md
```

`Package.swift` products: executables `WillyDisk` and `render-screens` (the offscreen
renderer); libraries `DiskCore`, `DiskLocalization`, `DiskUI`. `DiskCLI` is a target, not
a product: it is linked into the one executable, whose `@main` chooses between the command
line and the app.

Commands:

- Build: `swift build`
- Test: `swift test`
- Scan from the command line (no window, no UI loaded):
  `swift run WillyDisk scan <folder> [--depth N] [--top N] [--json]`.
  The bundled binary takes the same arguments; the SDK stamp below only affects
  window chrome, so it does not matter to a scan.
- Run (dev): `bash Scripts/run.sh` → builds `.build/WillyDisk.app` and opens it.
  Do **not** use `swift run WillyDisk` to inspect the UI: a bare SwiftPM binary
  is stamped with the deployment target as its linked SDK and renders the legacy
  window chrome (see §6, "Window chrome / Liquid Glass"). `Scripts/run.sh` goes
  through `bundle-app.sh`, which restamps the SDK.
- Bundle: `bash Scripts/bundle-app.sh` → `.build/WillyDisk.app` (launch with `open`)
- Localization: `bash Scripts/localize.sh` compiles the catalog into the committed
  `.lproj` tables; `--check` fails when they are stale.

## 3. Frozen data model (`DiskCore/Models`)

All types `public`, `Sendable`, Swift 6 concurrency-safe.

```swift
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case applications, documents, images, video, audio, archives, code, system, other
}

/// A node in the scanned tree. Value type, compact.
public struct ScanNode: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let category: FileCategory
    public let logicalSize: Int64      // sum of file logical sizes in subtree
    public let allocatedSize: Int64    // on-disk allocated bytes (st_blocks*512) where available
    public let fileCount: Int          // files in subtree (1 for a file)
    public let directoryCount: Int     // dirs in subtree
    public let modifiedAt: Date?
    public let isAccessible: Bool
    public let errorMessage: String?
    public let children: [ScanNode]    // sorted desc by logicalSize; empty for files
    public var isLeaf: Bool { !isDirectory }
}

/// What the totals include twice, leave off this disk, or did not enter.
public struct ScanAccounting: Sendable, Equatable {
    public let hardlinkFileCount: Int              // distinct regular files with st_nlink > 1
    public let hardlinkExtraLogicalSize: Int64     // bytes counted again for later links
    public let hardlinkExtraAllocatedSize: Int64
    public let datalessFileCount: Int              // SF_DATALESS: data lives in the cloud
    public let datalessLogicalSize: Int64
    public let datalessAllocatedSize: Int64        // what such files occupy locally
    public let skippedSymlinkCount: Int            // links not followed + broken/outside/duplicate
    public let skippedVolumeCount: Int             // dirs left because stayOnVolume is set
    public let specialFileCount: Int               // sockets, devices, FIFOs skipped
    public let excludedItemCount: Int              // entries the request's exclusions left out
    public var hasFindings: Bool { ... }
    public static let zero = ScanAccounting()
}

/// Terminal result (`.finished`) and in-flight snapshot (`.partial`); for a
/// partial snapshot `finishedAt` is the snapshot timestamp.
public struct ScanSummary: Sendable {
    public let root: URL
    public let totalLogicalSize: Int64
    public let totalAllocatedSize: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let inaccessibleCount: Int       // distinct dirs that could not be read
    public let errorCount: Int              // truthful, uncapped non-fatal issue total
    public let permissionDeniedCount: Int   // TCC/POSIX-denied dirs (⊆ inaccessibleCount); drives the banner
    public let surfacedIssueCount: Int      // per-path issue events actually surfaced (≤ engine cap)
    public let startedAt: Date
    public let finishedAt: Date
    public let categoryBreakdown: [FileCategory: Int64]   // by logical size
    public let largestFiles: [ScanNode]                   // top N, default 100
    public let largestDirectories: [ScanNode]             // top N, default 100
    public let rootChildren: [ScanNode]                   // the root's own entries, live ones included
    public let accounting: ScanAccounting                 // what the totals double-count or omit
}
```

The totals count every entry the walk reached. They deliberately do not deduplicate:
the first link of a hard-linked inode contributes its bytes to the total, and each
later link contributes again — the overlap is disclosed in
`ScanAccounting.hardlinkExtraLogicalSize`/`hardlinkExtraAllocatedSize`, not silently
subtracted, because concurrent traversal makes which link is "first" arbitrary and a
deduplicated total would disagree with the tree and the ranking. Dataless files are
counted at their full logical size, with their local bytes and cloud-only share
reported separately. Skips are counted by kind. The engine reports these facts only
when it observed them; a default `ScanAccounting.zero` means no finding, never an
unchecked guess. Exclusions are counted, not sized: the walk never enters an
excluded item, so no byte total for it would be measured.

Persistence is deliberately outside this model. `DiskCore/History/ScanRecord.swift`
is an explicit, versioned DTO (`schemaVersion`, currently 1) that keeps one finished
scan's totals, counts, ranked top lists, accounting, scan options, and volume facts —
never its tree. The frozen types are not a file format: making `ScanSummary` `Codable`
would turn every field and node identity into one.

## 4. Frozen scanning contract (`DiskCore/Scanning/Contracts.swift`)

The engine implements this contract in `Sources/DiskCore/Scanning/`.

```swift
public struct ScanRequest: Sendable {
    public var root: URL
    public var followSymlinks: Bool = false   // default safe: do not follow
    public var stayOnVolume: Bool = true      // do not cross mount boundaries
    public var includeHidden: Bool = true
    public var excludedPaths: [URL] = []      // paths the walk leaves out entirely
    public init(
        root: URL,
        followSymlinks: Bool = false,
        stayOnVolume: Bool = true,
        includeHidden: Bool = true,
        excludedPaths: [URL] = []
    )
}

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let bytesScanned: Int64
    /// nil when progress cannot be computed reliably (e.g. no known total). Never fabricate.
    public let fractionCompleted: Double?
    public let elapsed: TimeInterval
}

public enum ScanEvent: Sendable {
    case started(root: URL)
    case progress(ScanProgress)
    /// Non-fatal; the scan continues. Carries the `ScanIssueKind` so a consumer
    /// can separate expected permission denials from hard faults.
    case issue(kind: ScanIssueKind, path: String, message: String)
    /// Progressive, non-terminal snapshot of results accumulated so far. May be
    /// emitted zero or more times between `.started` and the single terminal event.
    /// Payload is a `ScanSummary` populated only with completed work; `finishedAt`
    /// is the snapshot timestamp. Never fabricated, never terminal.
    case partial(ScanSummary)
    case finished(ScanSummary)
    case cancelled(partial: ScanSummary?)        // cancellation is a first-class outcome
}

/// Classifier vocabulary shared by the engine and the UI.
public enum ScanIssueKind: Sendable, Hashable {
    case permissionDenied, brokenSymlink, io, other
}

public protocol ScanEngine: Sendable {
    /// Streams events. May emit zero or more non-terminal `.partial` snapshots,
    /// then emits `.finished` or `.cancelled` exactly once, then ends.
    func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent>
    func cancel() async
}
```

Rules: one dedicated `Task`/actor does filesystem work; never on the main actor.
Issues never terminate the scan; each surfaced `.issue` carries a `ScanIssueKind`.
The per-path issue stream is bounded by the engine while
`ScanSummary.errorCount` stays the truthful, uncapped total; `surfacedIssueCount`
reports how many were actually surfaced. Symlink loops and out-of-scope
traversal must be prevented (track visited dev/inode). Request exclusions are
resolved once before traversal starts. An exclusion equal to the scan root, or
above it, is ignored: the scanned location always wins. A nested exclusion is
skipped without entering it, and its contents contribute nothing to the totals.
Identity (device + inode) is matched first, then the canonical path, so an
unrelated hard link elsewhere is not mistaken for the excluded path; a followed
link that lands in an excluded folder is skipped as well. `ScanAccounting.excludedItemCount` reports how many entries were skipped, never an invented size.
Progress
`fractionCompleted` is `nil` unless a reliable total is known. Progressive
`.partial` snapshots are non-terminal: the engine may emit any number of them,
each reflecting only completed work, and the stream still ends with exactly one
`.finished` or `.cancelled`. Completed work includes the scan root's own entries
while their subtrees are still being walked: `rootChildren` reports the root's
whole entry group at once — its folders included before they have been walked —
each with the bytes counted under it so far, which is finished work that grows,
never a projection. A screen colours an entry by its place among its siblings, so
the group is reported complete and ordered by the paths it holds, and a colour
once on screen does not move as the scan proceeds. It is empty once the summary
carries the root node itself in `largestDirectories`.

## 5. UI contract (DiskUI)

- `ScanViewModel` (`@MainActor @Observable`) drives the scan flow through its
  phases from `AsyncStream<ScanEvent>`; it calls `DiskCore` only — never
  re-implements scanning.
- `ScanEvent.partial` lets the results screen render progressively while a scan
  runs: the same `ScanSummary` shape (tree, largest items, category breakdown)
  updates in place, then the terminal `.finished` summary replaces it. Snapshots
  are advisory — the engine may throttle or omit them — and `.partial` is never
  terminal. Because a scan may surface them far faster than a screen can usefully
  redraw, the view model takes them at a bounded cadence, where the newest
  snapshot wins: the chart's rings and the explorer's rows are re-derived at a
  rate a person can see, never once per snapshot. While the explorer is being
  scrolled the newest snapshot is held and taken when the scroll ends, so a
  redraw never lands under a moving list.
- Settled results read a live tree. `ScanTreeWatcher` owns one item-level FSEvents
  stream over the root, so a batch names the files and folders that moved.
  `ScanItemEvent` reduces each item to the folder it changes — a file's event is its
  parent folder, a directory's own entry change is the directory — and drops events
  that carry no creation, removal, rename, or write: owner, attribute, xattr, and clone
  metadata cannot move a number a scan reported, and a busy root emits them
  continuously. `ScanWatchScope` is the only thing that decides whether a folder
  belongs to what the scan measured: canonical `realpath` root and exclusions, an
  exclusion at or above the root ignored, the same `stayOnVolume` device rule as the
  traversal, and `/System/Volumes/Data/…` mapped back to `/…` for a `/` scan.
  `LiveTree` holds the scan as a compact arena of measured entries, and the engine
  fills it while it walks (`LiveTreeScanning`): a folder's entries are inserted in one
  batch when its listing is done, and the tree is handed to the screen just before
  `.finished`, only when it agrees with the summary the same walk produced.
  `LiveTreeUpdater` reconciles each changed folder after that — a file from its own
  `stat`, a vanished entry removed, a folder that arrived measured once with the engine
  — under the scan's own `LiveTreePolicy`, so an edit can never put in the tree
  something that scan would have skipped. A batch is applied after a short quiet period and bumps one
  `revision`, so the screen rebuilds once. Nothing is re-measured and no run is too
  slow to keep current: a whole-disk scan is as live as a home folder. The stale marker
  is only for a screen that cannot follow a change (no tree, or the watch switched
  off). Two questions need the whole tree rather than one folder: the explorer's
  largest lists and the whole-scan search. Both walk it off the main actor, take the
  lock per folder, and run on their own intervals — every entry they visit was
  measured, though the answer is not a snapshot of one instant. The cleanup and
  duplicate candidates and the category file list walk the tree the same way.
  `ScanSummary` stays the scan's record — History, the CLI, export, diagnostics and the
  coverage sheet describe the run, not the screen. The watcher stops on Home, on a new
  scan, on cancellation, and when the root disappears.
- `SourceSelectionView` offers quick-scan presets (Home, Downloads, Applications,
  Caches, Derived Data, Trash) that start the same real scan as picking the folder
  by hand, and lists the next scan's excluded paths in its Scan Options popover.
  Exclusion choices persist with the other scan options; a missing preset is shown
  disabled rather than silently dropped.
- Screens: `SourceSelectionView` (A) and `ResultsView` (C). Scanning is not a
  separate screen: `ScanFlowView` routes the model's `.scanning` phase to
  `ResultsView`, which renders the honest in-progress state until the terminal
  summary arrives. `WillyDiskApp` (`Sources/WillyDiskApp`) owns the window and
  injects the view model: `AppState` creates one
  `ScanViewModel(engine: FileScanEngine(), …, watcher: ScanTreeWatcher())` and
  `ContentView` hosts
  `ScanFlowView`, which switches between source selection and results on the view
  model's phase. There is no sidebar navigation — a single
  "Choose a Folder…" menu command (⌘O) opens a panel and starts a real scan.
- The coverage sheet explains the scan rather than reconciling it. It shows the
  scan's own totals and accounting next to the volume's own capacity facts
  (`VolumeFactsProbe`), lists local snapshots via `tmutil` (`SnapshotProbe`), and
  says when a number is unavailable. Request exclusions appear there as
  "Skipped by your exclusions" with the count of skipped entries and the statement
  that their contents are not in the totals — the sheet never estimates the size
  of what it did not read. It never subtracts the scanned total from
  the volume's used space to name an "unaccounted" remainder: those figures
  measure different things, and the difference is not an explanation.
- Reclaim is Trash-only and guarded. `ReclaimPolicy` refuses the scan root or an
  ancestor, volume roots, the home directory, protected system locations, missing
  items, read-only volumes, and any move while scanning; `ReclaimSheet` explains
  a refusal instead of only disabling its button. After a move the results are
  marked stale and Rescan is offered; the totals are not edited locally, because
  a locally adjusted tree would no longer be a scan.
- Scan history is a versioned DTO, not the scan made codable. A finished run is
  recorded as a `ScanRecord` (schema 1) under
  `~/Library/Application Support/WillyDisk/History/`, at most 20 per location and 100
  overall. A cancelled run is not recorded: its totals cover part of the root, and a
  comparison against them would present missing work as space that vanished. The store
  skips a file it cannot read or whose schema it does not know, reports how many, and
  never deletes one by pruning. `HistorySheet` compares two runs of the location on the
  slot: totals, counts, and the category breakdown are exact; the ranked folders and
  files are the largest entries each run recorded (100 at the current engine capacity),
  matched by path and labelled New, Grown, Shrunk, or Unchanged. A later entry is called
  New only when the earlier run would have recorded it: it is absent from a list that
  held everything it found, or larger than a truncated list's cut-off. An entry at or
  below that cut-off is not compared, because it may simply have ranked lower then.
  A record carries the capacity it was written with,
  so changing that number later does not misread older runs. Different scan options
  between the runs are disclosed, and nothing is called a saving — a smaller scan is a
  smaller measurement, and the Trash still has to be emptied.
- Appearance is a user preference rather than scan state: `DiskUI`'s
  `AppAppearance` (system, light, dark) is persisted in `UserDefaults` under one
  key, offered by the gear menu in `SourceSelectionView`'s toolbar, and applied by
  `AppState` as `NSApplication.appearance` — one carrier that every window, the
  app's chrome, the panels it presents, and the menu bar inherit, and whose
  changes SwiftUI's color scheme follows.
- The command line is a second front end over the same engine, not a second scanner.
  `DiskCLI` depends on `DiskCore` and the Foundation-only `DiskLocalization`. The executable's `@main` checks the process
  arguments before SwiftUI is touched and routes `WillyDisk scan …` (and `--help`) to
  `ScanCLI`, so no `NSApplication`, window, or Dock icon is created. The text report is
  derived from the terminal `ScanSummary`; `--json` prints the versioned `ScanRecord`
  (the history schema), with every list ordered size-first and path-second so equal
  sizes print deterministically. `--depth` and `--top` are print widths: they never
  narrow what was scanned or recorded. SIGINT/SIGTERM call `ScanEngine.cancel()`; a
  cancelled run prints no report and exits 130. Exit statuses are 0 (finished), 1
  (missing folder or unwritable report), 2 (usage), and 130 (cancelled).
- Design tokens live in `DiskUI/DesignSystem/DesignSystem.swift` (spacing scale,
  corner radii, typography roles, semantic colors). UI never hard-codes magic numbers.
- Localization is a contract of its own. Every user-visible string is a catalog key in
  `Sources/DiskLocalization/Localizable.xcstrings`, read through `L10n.string` or
  `L10n.format`; a view, sheet, menu, panel, or CLI message never carries a literal of
  its own. A key is the English source sentence with `%@`/`%lld` placeholders, and a
  count is one entry with plural variations rather than a number concatenated with a
  noun. Language resolution is explicit (an `.lproj` chosen from the preferred
  languages) because a Swift Package resource bundle is not the main bundle, and the
  chosen language also sets the layout direction. `ar` is the finished translation and
  carries Arabic's zero/one/two/few/many/other forms; `en-XA` is the generated
  doubled-length pseudolanguage. SwiftPM will not compile the catalog without deriving
  Swift symbols that format-only keys cannot provide, so `Scripts/localize.sh` compiles
  the committed `en.lproj`/`ar.lproj`/`en-XA.lproj`; CI checks freshness and
  `Tests/QATests/LocalizationGuardQATests` checks source/catalog agreement. The
  `ScanRecord` JSON and category raw values are data and stay in the source language.
  The app's language is itself a preference: `AppLanguage` (`system`, `english`,
  `arabic`) is stored under `appLanguage`, applied before the first window, and re-pins
  `L10n` when Settings changes it; `system` clears the override so the catalog follows
  macOS. The override governs WillyDisk's own windows and date formatting, not AppKit's
  panels or the command line.
- Resource bundles are located, not assumed. SwiftPM's `Bundle.module` answers only
  from the directory `Bundle.main.bundleURL` names and the build path the module was
  compiled under; inside an `.app` the first is the app itself, so a downloaded build
  could not reach the bundles `Scripts/bundle-app.sh` installs in
  `Contents/Resources`. `BundledResources` (`Sources/DiskLocalization/`) searches that
  directory first, then the directory the binary runs from, then the place a test
  bundle keeps them, and fails with every path it tried. Both resource bundles
  (`WillyDisk_DiskUI`, `WillyDisk_DiskLocalization`) load through it, and
  `Tests/QATests/ResourceBundleLayoutQATests` holds the app layout to that search.
- The disk chart is `SunburstView` — custom SwiftUI shapes with ring/angle
  geometry, no third-party deps.

## 6. Compatibility rules (all agents)

- Deployment target macOS 14; verify APIs instead of assuming.
- Liquid Glass is an enhancement: guard with `if #available(macOS 26.0, *)`
  (e.g. `.glassEffect`, `GlassEffectContainer`). macOS 15 → materials/translucency;
  macOS 14 → solid native surfaces, separators, restrained depth.
- **Window chrome / Liquid Glass (SDK stamp).** macOS 26+ gates the window
  chrome — traffic-light style, titlebar/toolbar layout, window corner radius,
  and automatic "modern" control rendering — on a linked-on-or-after check
  against the executable's `LC_BUILD_VERSION` `sdk` field. SwiftPM stamps that
  field with the *deployment target* (14.0), so a plain `swift build` / `swift run`
  binary is treated as pre-Tahoe and draws the legacy window (old traffic lights,
  centered title, toolbar that does not line up with the buttons). The bundle
  script restamps `sdk` to the real SDK with `vtool` while keeping `minos 14.0`,
  and fails loudly if the stamp is wrong. Always validate UI through
  `Scripts/run.sh` / `Scripts/bundle-app.sh`, and verify with
  `xcrun vtool -show-build .build/WillyDisk.app/Contents/MacOS/WillyDisk`
  (expect `sdk` ≥ 26, `minos` 14.0). `glassEffect` is unaffected — it is an
  explicit runtime call — only *automatic* control/chrome modernization is
  SDK-gated.
- Never call a newer API unguarded. No third-party packages without approval.
- Light and dark must both be polished; controls keyboard-accessible.

## 7. Shared interfaces & change process

- The frozen surfaces are `Sources/DiskCore/Models/**` and
  `Sources/DiskCore/Scanning/Contracts.swift`. A change to either is a design change,
  not a refactor: explain the reasoning in the pull request and update this document in
  the same change.
- `Package.swift`, `Scripts/**`, the localization catalog, and this document are shared
  too. A new or changed catalog key changes every screen and the command line, so treat
  it as a shared surface: explain the wording change and run
  `bash Scripts/localize.sh` in the same change.
- Everything else is ordinary code. Keep it consistent with the files around it.

## 8. Non-negotiables

Off-main-thread scanning; working cancellation; a live results tree edited only with
measured changes — never an invented one — and a `ScanSummary` that is never edited;
graceful permission failures; no automatic deletion (confirmation + clear identification only); no fabricated
progress/statistics; no invented reconciliation between a folder scan and a
volume's used space; no dead controls; no placeholder/mock data in the shipped app; no
user-visible literal outside the string catalog; no count built by concatenating a
number and a noun when the catalog can resolve its plural.

**Comments are evergreen.** A code comment must never cite a task, issue, or bug
number, and must never narrate the bug a change fixed. Comments explain only current
intent and behavior — they are not a changelog. See `CONTRIBUTING.md`.
