# WillyDisk

A native macOS disk-space analyzer. See what's taking up space, then find and reclaim it.

WillyDisk scans a volume or a folder, builds a size-attributed tree of what it finds, and
shows where the bytes went — an interactive sunburst chart, a sortable explorer, and a
breakdown by file category. Everything happens on your machine.

## Features

- **Live results.** The results screen renders progressive snapshots while a scan runs,
  then settles on the final summary. There is no separate "scanning" screen to wait on.
- **Honest numbers.** Progress, sizes, and issue counts are reported only when they are
  actually known. When a reliable total is unavailable the app shows no percentage rather
  than inventing one.
- **Interactive sunburst.** Click into a directory to drill down. The chart and the
  explorer are driven by the same tree, so they never disagree about what a folder holds.
- **Category breakdown.** Storage grouped by file kind, by both logical size and on-disk
  allocated size.
- **Permission-aware.** Full Disk Access is detected and explained in place. Directories
  that cannot be read are counted and surfaced instead of being silently skipped.
- **Cancellable.** A scan can be stopped at any point and still reports what it found.
- **Export.** Results export to JSON or CSV.
- **No third-party dependencies.** SwiftUI and AppKit only.

## Requirements

- macOS 14 or later to run.
- A Swift 6 toolchain (Xcode 16 or later) to build.

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
bash Scripts/render-screens.sh  # render the screens offscreen to PNGs in .build/renders
bash Scripts/repo-map.sh        # print a structural inventory of the repository
```

## Architecture

WillyDisk is a Swift Package with three targets:

- **`DiskCore`** — pure logic, no UI: the value model and the scanning engine.
- **`DiskUI`** — SwiftUI screens, components, and the design system.
- **`WillyDiskApp`** — the `@main` executable, the window, and the wiring.

Filesystem work happens off the main actor, cancellation is a first-class outcome, and
the engine's contract in `Sources/DiskCore/Scanning/Contracts.swift` is deliberately
frozen so the UI and the engine can evolve independently. The data model, the scanning
contract, the compatibility rules, and the non-negotiables are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Issues and pull requests are welcome.

## License

MIT — see [`LICENSE`](LICENSE).
