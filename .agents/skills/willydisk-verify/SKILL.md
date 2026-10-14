---
name: willydisk-verify
description: "Verify a change to WillyDisk before calling it done: build, test, bundle, launch, and capture the UI offscreen. Use when a WillyDisk change needs end-to-end verification, when a UI change must be reviewed visually, when a build or test failure needs the right command, or when the app's window chrome looks wrong. Covers swift build, swift test --filter, Scripts/bundle-app.sh, Scripts/run.sh, Scripts/render-screens.sh, the SwiftPM SDK-stamp trap behind `swift run`, the xcrun vtool check, and the WILLYDISK_NO_SANDBOX flag an agent sandbox needs."
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
```

The renderer drives a real scan of a generated fixture tree, so the PNGs show real data.
It opens no window and needs no Screen Recording permission.

| Flag | Meaning | Default |
|---|---|---|
| `-o DIR` | output directory | `.build/renders` |
| `-s WxH` | render size in points | `1088x816` |
| `-a light\|dark\|both` | appearances | `both` |
| `-t DIR` | scan this directory instead of the fixture | generated fixture |
| `-c` | capture the content alone, without the window | the window |

`WILLYDISK_NO_SANDBOX=1` matters inside an agent sandbox: SwiftPM cannot nest its own
sandbox there, and the shared module cache is unwritable, so the script adds
`--disable-sandbox` and points swiftc at a module cache under `.build`.

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

## Before you say it is done

- `swift build` and `swift test` pass.
- Shared contracts are untouched, or the change was raised as a design change — see §7
  of `docs/ARCHITECTURE.md`.
- Comments cite no task, issue, or bug number.
- A UI change was looked at in both light and dark through the bundle, not through
  `swift run`.
