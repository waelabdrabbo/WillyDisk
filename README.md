# WillyDisk

A native macOS disk-space analyzer. See what's taking up space, then find and reclaim it.

WillyDisk scans a volume or a folder, builds a size-attributed tree of what it finds, and
shows where the bytes went — an interactive sunburst chart, a sortable explorer, and a
breakdown by file category. Everything happens on your machine.

## Features

- **Stays current.** While the results are on screen, a change in the scanned folder
  re-measures the root in the background. A long scan is not re-run automatically; it is
  marked stale and offers Rescan.
- **Live results.** The results screen renders progressive snapshots while a scan runs,
  then settles on the final summary. There is no separate "scanning" screen to wait on.
- **Honest numbers.** Progress, sizes, and issue counts are reported only when they are
  actually known. When a reliable total is unavailable the app shows no percentage rather
  than inventing one.
- **Interactive sunburst.** Click into a directory to drill down. The chart and the
  explorer are driven by the same tree, so they never disagree about what a folder holds.
- **Whole-scan search.** Find any name in the finished scan, not only the folder on
  screen. Each result names the folder that holds it, and Show in Folder drills there.
  The list is bounded, and it says how many matches it is showing.
- **Category breakdown.** Storage grouped by file kind, by both logical size and on-disk
  allocated size.
- **Permission-aware.** Full Disk Access is detected and explained in place. Directories
  that cannot be read are counted and surfaced instead of being silently skipped.
- **Localized.** The interface has a complete English and right-to-left Arabic
  translation, with resolved plurals, and Settings can switch between System, English,
  and العربية without relaunch. The command line's text follows the system language; its
  `--json` record stays machine-readable and untranslated.
- **Cancellable.** A scan can be stopped at any point and still reports what it found.
- **Export.** Results export to JSON or CSV.
- **Cleanup review.** A finished scan offers candidates worth reviewing: caches, Xcode
  device support and simulators, logs, old downloads, large old files, and same-size
  duplicates whose contents it can check. Sections are grouped by what the app rebuilds
  and what is yours, and only the first can be selected whole. Nothing is deleted: a
  move goes to the Trash through a confirmation, space returns when the Trash is
  emptied, and a move can be put back while the Trash still holds it.
- **Command-line scan.** `WillyDisk scan <folder>` measures a folder with the same
  engine the app uses, with no window. `--json` prints the versioned `ScanRecord` the
  history feature stores.
- **Command-line cleanup.** `WillyDisk cleanup <folder>` lists the same candidates
  without a window; `--json` prints the versioned `CleanupRecord`, and
  `--check-contents` reads the duplicates. It only lists.
- **No third-party dependencies.** SwiftUI and AppKit only.

## Requirements

- macOS 14 or later to run.
- Xcode 26 or later, for the macOS 26 SDK the UI builds against, even though the app
  runs on macOS 14.

## Install

### Homebrew

```
brew tap waelabdrabbo/willydisk https://github.com/waelabdrabbo/WillyDisk
brew trust --tap waelabdrabbo/willydisk   # current Homebrew: a third-party tap must be trusted
brew install --cask willydisk
```

The cask installs `WillyDisk.app` into `/Applications` and links the same binary into
Homebrew's `bin` as `willydisk`, so the command line works without opening a window:

```
willydisk scan ~/Downloads
```

Older Homebrew versions have no `brew trust`; skip that line there. Once the cask is
installed, `brew upgrade --cask willydisk` picks up each new release.

**The app is unsigned and not notarized**, so macOS blocks its first launch — including
`willydisk` in a terminal, which is killed until the app itself is approved once. Approve
it in System Settings → Privacy & Security → Open Anyway, or clear the download flag:

```
xattr -dr com.apple.quarantine /Applications/WillyDisk.app
```

This repository is its own tap: Homebrew clones it and reads `Casks/willydisk.rb`, which
the release pipeline renders from the published checksums. It is not in `homebrew/cask`
because Homebrew requires a notarized build there. [`docs/HOMEBREW.md`](docs/HOMEBREW.md)
has the whole arrangement.

### Download

Download the zip for your Mac from the
[Releases page](https://github.com/waelabdrabbo/WillyDisk/releases) —
`WillyDisk-<version>-arm64.zip` on Apple Silicon, `-x86_64.zip` on Intel
(`uname -m` tells you which) — and check it against the published SHA-256:

```
shasum -a 256 -c WillyDisk-<version>-<arch>.zip.sha256
```

Unzip the download and move `WillyDisk.app` to `/Applications`.

**The app is unsigned and not notarized.** There is no Apple Developer account behind
it, so macOS refuses the download the first time it is opened. That is expected; no
build here is approved by Apple. Approve it in System Settings → Privacy & Security →
Open Anyway (Control-click → Open is not offered on macOS 15 and later), or remove the
download flag:

```
xattr -dr com.apple.quarantine /Applications/WillyDisk.app
```

The checksum detects a corrupted or altered download; it is not proof that the build is
trustworthy. Full Disk Access is optional: without it the app measures what it can read
and reports what it could not.

Building from source avoids the approval step entirely — a local build carries no
quarantine flag.

### Updating

WillyDisk checks GitHub for a newer release once a day when **Check for updates
automatically** is on in Settings; **Check for Updates…** in the app menu always
checks. Nothing is downloaded until you choose Download, the archive is checked
against the release's published SHA-256, and nothing is replaced until you choose
Install and Relaunch. The app quits, swaps the bundle, and reopens. The checksum
shows the download arrived intact; it does not prove who built it.

Homebrew users can also run `brew upgrade --cask willydisk`. The next release's
cask declares `auto_updates true`, so Homebrew compares the installed app's version
and does not replace a newer self-updated copy. Because the app is ad-hoc signed, macOS may ask
for Full Disk Access again after an update.

## Build and run

```
swift build
swift test
bash Scripts/run.sh
```

`Scripts/run.sh` builds the `.app` bundle and launches it. Use it instead of
`swift run WillyDisk`: SwiftPM stamps a plain binary with the deployment target as its
linked SDK, so AppKit would draw the legacy pre-Tahoe window chrome — old traffic lights
and a toolbar that does not line up with the buttons. The bundle script restamps the SDK
and fails loudly if the stamp is wrong. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §6.

Other scripts:

```
bash Scripts/bundle-app.sh      # build .build/WillyDisk.app without launching it
bash Scripts/package-release.sh # build the arm64 and Intel zips with their SHA-256s
bash Scripts/homebrew-cask.sh   # render the Homebrew cask the tap serves
bash Scripts/render-screens.sh  # render the screens offscreen to PNGs in .build/renders
bash Scripts/repo-map.sh        # print a structural inventory of the repository
```

## Command-line scan

The same binary also scans without opening a window:

```
swift run WillyDisk scan ~/Downloads
swift run WillyDisk scan ~/Downloads --json | jq .
swift run WillyDisk scan ~/Downloads --depth 3 --top 20
```

`--depth` and `--top` decide how much of the report is printed; they never change what
is scanned. `--json` prints the versioned `ScanRecord` instead of the text report. The
command exits 0 when the scan finishes, 2 on a usage error, and 130 after an interrupt;
`WillyDisk scan --help` lists every flag. The bundled
`.build/WillyDisk.app/Contents/MacOS/WillyDisk` takes the same arguments.

The cleanup review runs the same way, and only lists:

```
swift run WillyDisk cleanup ~/Downloads
swift run WillyDisk cleanup ~/Downloads --json | jq .
swift run WillyDisk cleanup ~/Downloads --check-contents
```

`--check-contents` is opt-in because it reads every candidate's bytes; sizes in the
report are bytes on disk, not logical sizes. `WillyDisk cleanup --help` lists the
rules and flags.

## Architecture

WillyDisk is a Swift Package with four targets:

- **`DiskCore`** — pure logic, no UI: the value model and the scanning engine.
- **`DiskCLI`** — the command-line front end over `DiskCore` (no UI dependency).
- **`DiskUI`** — SwiftUI screens, components, and the design system.
- **`WillyDiskApp`** — the `@main` executable, the window, and the wiring; it routes a
  `scan` invocation to `DiskCLI` before any UI is created.

Filesystem work happens off the main actor, cancellation is a first-class outcome, and
the engine's contract in `Sources/DiskCore/Scanning/Contracts.swift` is deliberately
frozen so the UI and the engine can evolve independently. The data model, the scanning
contract, the compatibility rules, and the non-negotiables are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Issues and pull requests are welcome.

## License

MIT — see [`LICENSE`](LICENSE).
