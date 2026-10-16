---
name: willydisk-verify
description: "Verify a change to WillyDisk before calling it done: build, test, bundle, launch, and capture the UI offscreen. Use when a WillyDisk change needs end-to-end verification, when a UI change must be reviewed visually, when a build or test failure needs the right command, when the app's window chrome looks wrong, or when a screenshot looks stale against the source. Covers swift build, swift test --filter, Scripts/bundle-app.sh, Scripts/run.sh, Scripts/render-screens.sh, why a re-rendered PNG can still look old (viewers cache bitmaps by path), the SwiftPM SDK-stamp trap behind `swift run`, the xcrun vtool check, and the WILLYDISK_NO_SANDBOX flag an agent sandbox needs."
---

# Verifying a WillyDisk change

WillyDisk is a SwiftUI macOS app built with SwiftPM — no `.xcodeproj`. Verification has
four rungs; stop at the highest one the change actually needs.

## 1. Build and test

```
swift build
swift test
swift test --filter FileScanEngineTests
```

`swift test` runs both targets: `DiskCoreTests` (engine behavior) and `QATests`
(independent verification). A change to traversal, cancellation, or batching should keep
`ProgressiveSnapshotTests` and `ScanBenchmarkTests` green.

## 2. Bundle it

```
bash Scripts/bundle-app.sh          # -> .build/WillyDisk.app
xcrun vtool -show-build .build/WillyDisk.app/Contents/MacOS/WillyDisk
```

Expect `sdk` >= 26 with `minos` 14.0. The bundle script restamps the executable's
`LC_BUILD_VERSION` `sdk` field with the real SDK while keeping the deployment target,
and fails loudly when the stamp is wrong.

This is the trap behind most "the window looks wrong" reports. SwiftPM stamps a plain
binary with the *deployment target* as its linked SDK, so macOS 26+ AppKit treats it as
pre-Tahoe and draws the legacy window: old traffic lights, a centered title, and a
toolbar that does not line up with the buttons. **Never verify UI through
`swift run WillyDisk`** — go through the bundle.

## 3. Look at it

```
bash Scripts/run.sh                      # build the bundle and launch it
CONFIGURATION=release bash Scripts/run.sh
```

`glassEffect` is an explicit runtime call and is unaffected by the stamp; only
*automatic* control and chrome modernization is SDK-gated.

## 4. Capture it offscreen

The only option in a locked session or inside an agent sandbox, and the way to leave a
reviewable artifact:

```
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a dark -c -o /tmp/renders
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -S both -o /tmp/renders
```

The renderer drives a real scan of a generated fixture tree, so the PNGs show real data.
It opens no window and needs no Screen Recording permission.

| Flag | Meaning | Default |
|---|---|---|
| `-o DIR` | output directory | `.build/renders` |
| `-s WxH` | render size in points | `1088x816` |
| `-a light\|dark\|both` | appearances | `both` |
| `-S results\|home\|both` | screens: results, source selection | `results` |
| `-t DIR` | scan this directory instead of the fixture | generated fixture |
| `-c` | capture the content alone, without the window | the window |

`WILLYDISK_NO_SANDBOX=1` matters inside an agent sandbox: SwiftPM cannot nest its own
sandbox there, and the shared module cache is unwritable, so the script adds
`--disable-sandbox` and points swiftc at a module cache under `.build`.

### Give every review a fresh output path

The renderer names its files after the size and appearance, so rendering the same size
twice reuses the same path — `results-window-light-1088x816.png`. A viewer that already
loaded that path (the session GUI, a browser, a preview pane) keeps serving the bitmap it
cached, and the screenshot then contradicts the source. Name the output directory for the
change instead:

```
WILLYDISK_NO_SANDBOX=1 bash Scripts/render-screens.sh -a both -o .build/renders/<change>
```

When a reader reports a screenshot that does not match the code, do not re-render and
assume it fixed itself, and do not doubt the build: copy the current PNG to a path that
has never been rendered and show that, which no cache can answer.

```
cp .build/renders/<change>/results-window-light-1088x816.png .build/renders/<change>/check.png
```

If the fresh path shows the change, the code was right and the reader's cache was stale.
Confirming it from the file itself is cheap either way: `stat` the mtime against the time
of the build, and `grep` the sources for the thing you expected to disappear.

### Reading colours out of a PNG

The renders are tagged **Display P3**, not sRGB, so the raw bytes are not the colours
the code asked for and differ from `#RRGGBB` in the source. Convert before comparing,
or a correct colour will look wrong by 20–50 per channel:

```python
im = Image.open(path)
im = ImageCms.profileToProfile(im.convert("RGB"),
        ImageCms.ImageCmsProfile(io.BytesIO(im.info["icc_profile"])),
        ImageCms.createProfile("sRGB"), outputMode="RGB")
```

Equally, do not infer a wedge's colour from a global colour histogram: the biggest
counts belong to the widest wedges, and a small wedge may fall below any threshold.
Sample the geometry directly, or resolve it from the source with a throwaway test.

### Measuring a screen's cost under a live scan

A PNG shows what a screen looks like, not what it costs. To measure that, host the real
view offscreen against a real scan and time the frames. Compile a scratch host in
gitignored `.build/` the way `Scripts/render-screens.sh` compiles its renderer:

```
xcrun swiftc -disable-sandbox -module-cache-path "$PWD/.build/render-module-cache" \
  -I "$PWD/.build/release" -L "$PWD/.build/release" -lDiskUI -lDiskCore \
  -o "$PWD/.build/probe" "$PWD/.build/probe.swift"
```

The host starts a `ScanViewModel(engine: FileScanEngine())`, puts `ResultsView` in an
`NSHostingView` (inside a never-ordered `NSWindow`), and runs the loop with a repeating
60 Hz `Timer`: on each fire, lay the window out, and record the interval since the last
fire. Report percentiles of those intervals — a stretched interval is a dropped frame.
Two runs make it answer something:

- **Control:** host no view at all. What is left is the scan's own call on the machine;
  a scan over a whole disk keeps ~30% of ticks a hair late and none past 33 ms. Only
  lateness beyond that belongs to the screen.
- **A/B:** build once, compile the host, run it, then `git stash push` the files under
  test, build and run again, and `git stash pop`. `.build/release` holds whichever
  sources were built last — a probe binary links its libraries statically, so compile
  the host *after* each build.

Attribute the cost by splitting ticks into those where `viewModel.resultsRevision`
changed and those where it did not: the first bucket is what one screen update costs.
`sample <pid> 5` on that process points at the frames inside it — in a live scan the
derived work shows up as `ResultsView.visibleRows` → `SunburstLayout.fillsByPath`.

Build the probe against `.build/release`: that is the configuration the shipped bundle
is made of, and debug inflates view-body work severalfold.

## Before you say it is done

- `swift build` and `swift test` pass.
- Shared contracts are untouched, or the change was raised as a design change — see §7
  of `docs/ARCHITECTURE.md`.
- Comments cite no task, issue, or bug number.
- A UI change was looked at in both light and dark through the bundle, not through
  `swift run`.
