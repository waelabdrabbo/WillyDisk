# Tests — agent notes

Three targets with different jobs.

- `DiskCoreTests/` — engine behavior. Uses `@testable import DiskCore` and the
  `FileSystemAccess` seam in `Sources/DiskCore/Scanning/FileScanner.swift` to exercise
  permission-denial and I/O paths without touching the real filesystem.
  `ContractSmokeTests` exists so the target resolves; engine behavior belongs in
  `FileScanEngineTests`, `ProgressiveSnapshotTests`, and `ScanBenchmarkTests`.
- `DiskCLITests/` — the `WillyDisk scan` front end: argument parsing and help, the exit
  statuses, the text report's determinism and its `--depth`/`--top` widths, and the
  `ScanRecord` JSON (schema, ordering, stable bytes apart from the run identity). The
  scan itself runs the real `FileScanEngine` against a small temporary tree; the
  cancellation and terminal-event paths use a scripted `ScanEngine`.
- `QATests/` — independent verification of shipped behavior that deliberately does not
  trust the engine's own tests. It cross-checks the scanner against external ground truth
  (`find` / `du`) and probes the non-negotiables, covering scan correctness, the
  `ScanViewModel` state machine, the access notice, and the UI surface.

Two opt-in benchmarks, `ScanBenchmarkTests` and `LiveTreeBenchmarkTests`, skip unless
`WILLYDISK_BENCH_ROOT` points at a folder, so they never slow `swift test`.

Assert real behavior. Do not add placeholder or mock data that reaches the shipped app,
and do not assert fabricated progress — `fractionCompleted` must be `nil` whenever no
reliable total exists.

```
swift test                                  # every target
swift test --filter ScanCommandTests        # one class
swift test --filter ScanCorrectnessQATests  # one class
```
