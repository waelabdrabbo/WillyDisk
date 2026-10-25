# Contributing to WillyDisk

WillyDisk is a native macOS disk analyzer (SwiftUI + AppKit, macOS 14+) built as a Swift
Package. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first — it holds the frozen
data model, the scanning contract, the shared-interface rules (§7), and the
non-negotiables (§8).

## Build and verify

```
swift build
swift test
bash Scripts/bundle-app.sh    # -> .build/WillyDisk.app
bash Scripts/run.sh           # build the bundle and launch it
```

`swift run WillyDisk` renders the legacy window chrome, because SwiftPM stamps the
binary with the deployment-target SDK. Always look at the UI through `Scripts/run.sh` or
the bundle; see `docs/ARCHITECTURE.md` §6.

Tests live in two targets: `DiskCoreTests` covers engine behavior, and `QATests` is
independent verification that deliberately does not trust the engine's own tests — it
cross-checks the scanner against external ground truth. Run one class with
`swift test --filter FileScanEngineTests`.

## Comments

Write comments as evergreen explanations of current intent and behavior.

- **Do not cite task, issue, or bug numbers.** Those belong in the tracker and the commit
  message, not in the codebase.
- **Do not narrate the bug a change fixed.** No "this used to…", "fixed the case where…",
  "now returns X instead of Y". Describe what the code does and why it must do it.
- Point at durable references instead: other types and functions,
  `docs/ARCHITECTURE.md`, or `Sources/DiskCore/Scanning/Contracts.swift`.

This rule covers code comments and in-repo documentation. Reviewers should treat a
tracker ID or bug narration in a comment as a defect in the change.

## Localization

Every user-visible string lives in `Sources/DiskLocalization/Localizable.xcstrings` and is
read through `L10n` from `Sources/DiskLocalization/L10n.swift`. Do not put a literal in a
view, a menu, a panel, or a CLI message, and do not build a plural by concatenating a
number and a noun in code — a count is one catalog key with plural variations.

Keys are the English sentence with `%@`/`%lld` placeholders. Add `en`, `ar`, and `en-XA`
values, then run:

```
python3 Scripts/pseudolanguage.py          # regenerate en-XA from the English values
python3 Scripts/pseudolanguage.py --check  # fail if any pseudolanguage value is stale
bash Scripts/localize.sh                   # compile the catalog into the shipped .lproj tables
bash Scripts/localize.sh --check           # fail if those committed resources are stale
```

Arabic is the finished translation and needs its zero/one/two/few/many/other forms;
`en-XA` is generated, doubled-length pseudolanguage used only to review truncation.
`swift test` runs the guard that fails on a literal outside the catalog, a source key
missing from it, or a catalog key with no call site.

## Shared interfaces

`Sources/DiskCore/Models/**` and `Sources/DiskCore/Scanning/Contracts.swift` are frozen
surfaces. Treat a change to either as a design change rather than a refactor: explain the
reasoning in the pull request and update `docs/ARCHITECTURE.md` in the same change.

## Pull requests

- Keep a change focused; unrelated cleanups belong in their own pull request.
- Run `swift build` and `swift test` before opening it, and say what you ran.
- For a UI change, attach a light and a dark screenshot to the pull request —
  `bash Scripts/render-screens.sh -a both` produces both without opening a window. A
  change that adds or rewords text should also attach `-l ar` and `-l en-XA` renders,
  which is where a longer translation or a truncated line shows up.
  Renders are generated artifacts and are not committed.
- Match the surrounding code: its naming, layering, and error handling.
