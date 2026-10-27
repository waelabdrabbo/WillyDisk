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
| `Package.swift` | products: executable `WillyDisk`, executable `render-screens` (the offscreen renderer), libraries `DiskCore`, `DiskLocalization`, and `DiskUI`; targets `DiskCLI` and `DiskUpdate` (the latter the internal release-feed, verification, and install-helper library) |
| `VERSION` | the only source of the marketing version; the bundle script stamps it |
| `Resources/` | the macOS icon: `AppIcon.icns` and its 1024 `AppIcon-1024.png` |
| `Sources/DiskUI/Resources/AppMark.png` | the circular in-app mark the UI and About show |
| `Sources/DiskCore/Models/` | frozen value model: `FileCategory`, `ScanNode`, `ScanSummary` |
| `Sources/DiskCore/History/` | `ScanRecord` (versioned DTO), `ScanHistoryStore`, `ScanComparison` |
| `Sources/DiskCore/Live/` | the live results tree: one compact arena of measured entries, the edits a filesystem change becomes, the updater that applies a folder re-listing, and the build from a finished scan |
| `Sources/DiskCore/Cleanup/` | `CleanupRule` + `CleanupTier`, `CleanupPolicy`, `CleanupAnalysis` (bounded, tiered rules), the explicit SHA-256 duplicate check, and `ReclaimLog` (the moves behind Put Back) |
| `Sources/DiskCore/Scanning/Contracts.swift` | frozen `ScanRequest`, `ScanEvent`, `ScanProgress`, `ScanEngine`, `ScanIssueKind` |
| `Sources/DiskLocalization/` | the string catalog and `L10n`; generated `.lproj` tables under `Resources/` |
| `Sources/DiskCore/Scanning/` (the rest) | the scan engine and its filesystem plumbing |
| `Sources/DiskCore/Watching/` | FSEvents watcher and the scope that filters events to the scanned tree |
| `Sources/DiskCLI/` | the `WillyDisk scan` and `cleanup` front end: parsing, text reports, `ScanRecord`/`CleanupRecord` JSON |
| `Sources/DiskUpdate/` | the release feed, version comparison, `.sha256` check, and staged-bundle verification (Foundation + CryptoKit; no UI) |
| `Sources/DiskUI/` | screens, components, design system |
| `Sources/WillyDiskApp/` | `@main` executable, window, wiring, CLI/GUI dispatch |
| `Tests/DiskCoreTests/` | engine tests |
| `Tests/DiskCLITests/` | command-line parsing, report stability, exit statuses |
| `Tests/DiskUpdateTests/` | feed decoding, version ordering, checksum, staged-bundle validation |
| `Tests/QATests/` | independent verification that does not trust the engine's own tests |
| `Scripts/` | build, bundle, release packaging, launch, offscreen render, localization, repo map, Homebrew cask rendering |
| `.github/workflows/` | `ci.yml`: build, test, bundle version check, CLI smoke, renders, cask audit; `release.yml`: tagged unsigned zips (arm64, x86_64), checksums, and the cask committed to `Casks/` |
| `.github/homebrew/` | `willydisk.rb.tmpl`: the Homebrew cask template the release renders |
| `Casks/` | `Casks/willydisk.rb`, the rendered cask Homebrew reads; this repository is its own tap |
| `docs/` | `ARCHITECTURE.md` (frozen contracts), `LIVE-TREE.md`, `MEMORY.md` (the one-tree memory pass, measured; decision C keeps the arena linear), `CLEANUP.md` (cleanup rules, tiers, and accounting), `HOMEBREW.md` (the tap, the cask, the release step), `UPDATES.md` (the self-update design and verification rules), `ROADMAP.md` |

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
`Watching/` holds `ScanTreeWatcher` (one FSEvents stream per root) and `ScanWatchScope`
(the request's root, exclusions, and volume rule applied to event paths). A watcher only
reports changed folders; `LiveTreeUpdater` applies the measured edits to the live tree,
and a `ScanSummary` is never edited.
`Live/` holds the tree the results screen reads: `LiveTree.swift` is the compact
arena and its measured edits, `LiveTreeUpdater.swift` turns a changed folder into those
edits (with `LiveTreePolicy` keeping the scan's rules), and `LiveTree+ScanSummary.swift`
builds one from a finished scan. `docs/LIVE-TREE.md` is the design and the migration;
`docs/MEMORY.md` is the memory record — the one-tree pass, measured, and the decision to
keep the arena linear with no stored-entry cap.

**`DiskUpdate` — the release feed and the update checks.**
`ReleaseFeed.swift` reads GitHub's `releases/latest` through a `FeedTransport` seam;
`ReleaseVersion.swift` orders versions; `UpdateRelease.swift` names the
two assets for this Mac and decides newer/older; `UpdateDownloader.swift` streams either
asset with real byte progress and an ephemeral session; `Checksum.swift` parses the
published `.sha256` and hashes in chunks; `UpdateVerifier.swift` expands the zip with
`ditto` and checks identifier, version, executable, minimum macOS, architecture, and
signature; `UpdateInstaller.swift` writes the detached helper that backs up the running
app, swaps in the verified bundle, and reopens it. Foundation + CryptoKit only. The
controller, sheet, menu, and Settings wiring live in `DiskUI`; `docs/UPDATES.md` is the
contract.

**`DiskUI` — SwiftUI.**
`ScanViewModel.swift` is the `@MainActor @Observable` state machine that consumes
`AsyncStream<ScanEvent>` and keeps settled results current through the watcher. `Screens/ScanFlowView.swift` routes phases,
`Screens/SourceSelectionView.swift` is screen A, `Screens/ResultsView.swift` is screen C
(and the live in-progress state), `Screens/HelpView.swift` is the help sheet's content,
`Screens/SettingsView.swift` is the preferences window. `Components/SunburstView.swift`
and `Components/TreemapView.swift` are the disk chart's two drawings, chosen by
`AppChartStyle` in Settings; `AccessNoticeRow`, `FlowLayout`, and `ScanOptionToggle` are
the other views.
`Components/HistorySheet.swift` is the scan-history comparison, backed by
`Support/ScanHistory.swift` (the `@Observable` view of the record store).
`Components/UpdateSheet.swift` is the software-update sheet, including the ready state's
Install and Relaunch; `Support/UpdateController.swift` owns the check/download/verify/
install state, `UpdatePreferences.swift` the daily-check choice and last check,
`UpdateStorage.swift` the staging and recovery directories, and `UpdatePresentation.swift`
the value states the sheet draws.
`DesignSystem/DesignSystem.swift` holds every token (`DS`), `ChartPalette.swift` the
chart fills, `FileCategory+UI.swift` the category symbols and labels, `AppAppearance.swift`
the stored system/light/dark appearance preference the Settings window edits, and
`AppLanguage.swift` the stored System/English/العربية interface-language choice that
re-pins `L10n` without relaunch.
`Support/` holds non-view helpers: `ExplorerQuery` (sorting/filtering), `ScanSearch`
(the bounded whole-scan name search) + `ExplorerPath` (the folder chain a result drills
to), `Formatters`, `LocationName` (a location's display name), `VolumeInfo` (mounted
volumes), `RecentLocations`, `FullDiskAccess` + `FullDiskAccessProbe` (TCC),
`ScanIssuesPresentation`, `ScanSlotPresentation`, `ReportExport` (JSON/CSV via
`NSSavePanel`), `AccessNoticeDismissal`, `ScanOptions` + `ScanOptionsStore` (the one
shared, persisted set of choices the next scan and Rescan use), `CleanupPresentation`
(rule and tier wording for the sheet), `DuplicateCheck` (the sheet's cancellable content
check over `DiskCore`'s hasher), `ReclaimLog` (the app's persisted moves, and the restorer
behind Put Back), `ScanHistory` (the observable view of the record store),
`WatchPreferences` (the stored keep-current toggle), the update controller/preferences/
staging values above, and `TreeWatching` (the watcher seam tests substitute).

**`DiskLocalization` — every user-visible string.**
`L10n.swift` is the one lookup path: `L10n.string(_:)` and `L10n.format(_:_:)` resolve the
interface language and format plurals from the catalog. `Localizable.xcstrings` is the
source of truth, keyed by the English sentence with `%@`/`%lld` placeholders; its
compiled `en.lproj`, `ar.lproj`, and `en-XA.lproj` are generated by
`Scripts/localize.sh` and committed, because SwiftPM cannot compile the catalog without
also deriving Swift symbols that format-only keys cannot be. The target is Foundation
only, so `DiskCLI` links it without loading AppKit or SwiftUI. Arabic is the finished
translation; `en-XA` is the generated doubled-length pseudolanguage the renderer reviews
truncation with.

**`WillyDiskApp`.**
`WillyDiskApp.swift` holds the `@main` entry (`WillyDiskEntry`) that routes `WillyDisk
scan …` to `DiskCLI` before SwiftUI is touched, then the `App` itself. `AppState.swift`
builds the single `ScanViewModel` with `FileScanEngine`, the shared options store,
history, the watch preferences, and the FSEvents watcher,
`ContentView.swift` hosts `ScanFlowView`, `AboutPanel.swift` presents the system About
panel, `AppDelegate.swift` is the lifecycle delegate.

**`DiskCLI` — the command line.**
`ScanCommand.swift` parses `scan <folder> --depth --top --json` and `cleanup <folder>
[--json] [--check-contents]`, and holds both help texts; `ScanCLI.swift` decides CLI vs
app, drives `FileScanEngine`, and maps the terminal event to an exit status
(SIGINT/SIGTERM call `ScanEngine.cancel()`); `ScanReport.swift` renders the deterministic
scan report and the `ScanRecord` JSON, and `CleanupOutput.swift` the cleanup report and
the `CleanupRecord` JSON. It depends on `DiskCore` and
the Foundation-only `DiskLocalization`, so a scan never loads AppKit or SwiftUI.
`--depth` and `--top` change what is printed, never what is scanned or recorded. The
report and help follow the user's language; the JSON stays machine data.

## Commands

```
swift build                          # compile
swift test                           # full suite
swift test --filter FileScanEngineTests   # one test class
swift test --filter DiskUpdateTests        # feed, version, checksum, verification, installer
swift test --filter UpdateQATests          # controller, preferences, staging, install (fakes)
swift run WillyDisk scan <folder> --json  # command-line scan: no window, no UI loaded
swift run WillyDisk cleanup <folder> --json  # the cleanup rules, same engine; lists only
python3 Scripts/pseudolanguage.py    # regenerate en-XA from the English values
bash Scripts/localize.sh             # recompile the catalog into the shipped .lproj tables
bash Scripts/localize.sh --check     # fail if those resources are stale
bash Scripts/run.sh                  # build the bundle and launch it (the way to look at the UI)
bash Scripts/bundle-app.sh           # assemble .build/WillyDisk.app; its version comes from VERSION
bash Scripts/package-release.sh      # build the arm64 and Intel zips with their SHA-256s
bash Scripts/homebrew-cask.sh check  # render the cask template; --audit runs Homebrew's checks
bash Scripts/render-screens.sh       # offscreen PNGs (-S results|home|search|help|settings|update|update-ready|categories|treemap|coverage|cleanup|duplicates|moved|reclaim|history|both; -l en|ar|en-XA), no window, no screen-recording permission
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
- **`Sources/DiskUI/Screens/ResultsView.swift`, `Components/SunburstView.swift`, and
  `Components/TreemapView.swift` are large.** Grep for the view or modifier you need
  instead of reading them whole. So is `Sources/DiskCore/Scanning/FileScanner.swift`.
- **Screenshots are not committed.** `Scripts/render-screens.sh` writes them into
  `.build/renders`, which is gitignored — there is nothing to read in the repository.
- A user-visible string belongs in `Sources/DiskLocalization/Localizable.xcstrings` and
  is read through `L10n`; never add a literal to a view. After editing the catalog run
  `bash Scripts/localize.sh`. The QA guard test fails on a literal that bypasses the
  catalog, a source key missing from it, or a catalog key with no call site.
- Run `bash Scripts/repo-map.sh` when the map above looks stale; it prints one screen of
  paths, per-area line counts, the largest sources, and the working-tree status
  (`--types` adds every file's top-level declaration).

## Deeper context, loaded only when you ask

`docs/ROADMAP.md` records what is shipped, the remaining work in recommended order,
the decisions that must not be re-litigated, and a suggested opening prompt for a
fresh session. `docs/UPDATES.md` is the update contract: feed, verification, install
transaction, permissions, and Homebrew. `docs/MEMORY.md` is the memory record:
the measured baseline, the implemented one-tree rule, and the decision to keep the arena
linear (no cap) with its reopen trigger.

`.agents/skills/willydisk-verify/` holds the end-to-end verification procedure (build,
test, bundle, launch, offscreen capture, and the SDK-stamp trap). It is offered as a
skill and its body loads only when you invoke it, so it costs nothing until then. Put
new repeatable procedures there rather than growing this file.

## Commits

Never commit on your own initiative. Run `git commit` only when the current request
explicitly asks for a commit; a finished change, green `swift build` / `swift test`, or a
clean-looking tree is not permission. Leave the work in the working tree, report what
changed, and wait.

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
