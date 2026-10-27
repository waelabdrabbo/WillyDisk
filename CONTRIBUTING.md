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

## Releasing

`ci.yml` must accept a commit before it is published, and `release.yml` publishes only a
`v*` tag that names the version in `VERSION`.

**Bump `VERSION` and push.**

```
printf '1.0.3\n' > VERSION
git add VERSION && git commit -m "chore(release): 1.0.3"
git push origin main
```

`.github/workflows/auto-release.yml` watches CI finish on `main`. When the commit it
accepted carries a `VERSION` with no tag yet, it creates `v<version>` and pushes it, which
starts the release. Pushes that leave `VERSION` alone — including the cask commit a
release writes back to `main` — find their tag already there and release nothing.

That workflow needs one repository secret, `RELEASE_TOKEN`: a fine-grained personal access
token with **Contents: read and write** on this repository (a classic token with `repo`
also works). The default `GITHUB_TOKEN` is not enough — a tag pushed with it does not
start another workflow, so `release.yml` would never run. Without the secret the workflow
fails and says so.

Nothing checks that the number is higher than the last release: `release.yml` only checks
that the tag names `VERSION`, so a mistaken or repeated number releases nothing — its tag
already exists — instead of failing.

**Publishing without waiting for CI** — CI is degraded, or the commit has to ship now — is
the tag alone. It must point at a commit whose `VERSION` already says that number:

```
git tag -a v1.0.3 -m "WillyDisk 1.0.3" && git push origin v1.0.3
```

**If a release fails after its tag exists** — the token was missing, the cask push was
blocked, a checksum check failed — re-run the failed `Release` run from the Actions tab.
`auto-release.yml` will not retry, because the tag is already there.

`CFBundleVersion` is the commit count, so nothing else is bumped. After a release, `main`
carries one commit you did not push: the workflow commits the rendered
`Casks/willydisk.rb` back to it, so pull before the next change.
