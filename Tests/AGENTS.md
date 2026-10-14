# Tests — agent notes

Two targets with different jobs.

- `DiskCoreTests/` — engine behavior. Uses `@testable import DiskCore` and the
  `FileSystemAccess` seam in `Sources/DiskCore/Scanning/FileScanner.swift` to exercise
  permission-denial and I/O paths without touching the real filesystem.
  `ContractSmokeTests` exists so the target resolves; engine behavior belongs in
  `FileScanEngineTests`, `ProgressiveSnapshotTests`, and `ScanBenchmarkTests`.
- `QATests/` — independent verification of shipped behavior that deliberately does not
  trust the engine's own tests. It cross-checks the scanner against external ground truth
  (`find` / `du`) and probes the non-negotiables, covering scan correctness, the
  `ScanViewModel` state machine, the access notice, and the UI surface.

Assert real behavior. Do not add placeholder or mock data that reaches the shipped app,
and do not assert fabricated progress — `fractionCompleted` must be `nil` whenever no
reliable total exists.

```
swift test                                  # both targets
swift test --filter ScanCorrectnessQATests  # one class
```
