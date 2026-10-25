# DiskCLI — agent notes

The `WillyDisk scan` front end. It is a **consumer** of `ScanEngine`, not a second
scanner: traversal, accounting, exclusions, and cancellation are all `DiskCore`'s. This
target depends on `DiskCore` and the Foundation-only `DiskLocalization`, so it never
imports `DiskUI`, AppKit, or SwiftUI.

## Where things are

- `ScanCommand.swift` — argument parsing, the usage error, and the help text. Accepts
  `--name value` and `--name=value`; one positional folder.
- `ScanCLI.swift` — `handles(_:)` decides whether the process is the CLI or the app,
  `run(arguments:)` is the entry the executable calls, and `execute(_:engine:output:)`
  is the testable scan driver. SIGINT/SIGTERM cancel through `ScanEngine.cancel()`.
- `ScanReport.swift` — the deterministic text report and the `ScanRecord` JSON. Every
  list is re-sorted size-first, path-second, because the engine ranks by size only and
  equal sizes can arrive in any order from a concurrent walk.

## Rules

- `--depth` and `--top` are **print** widths. They never change what is scanned, and
  they never narrow the `ScanRecord` (a record keeps the engine's ranked-list capacity).
- Exit status: `0` finished, `1` the folder does not exist / the report cannot be
  written, `2` usage, `130` cancelled. A cancelled scan prints no report.
- stdout carries the report and nothing else; diagnostics go to stderr, so
  `WillyDisk scan … --json | jq` stays clean.
- JSON is the versioned `ScanRecord` DTO, encoded with `.sortedKeys` and `.iso8601`.
  Two runs of an unchanged folder differ only in the record's `id` and its two
  timestamps — those are the run's identity, not a measurement. The record carries no
  volume figures: the whole disk's free space moves while the command runs, and it is
  not part of what the folder measured.
- Do not add scan options here that the app's `ScanRequest` cannot express; the
  frozen contract is `Sources/DiskCore/Scanning/Contracts.swift`.
- The report, help, and errors follow the user's language through `L10n`, so the labels
  are not a stable English interface; `--json` is. The report's label column is as wide
  as the widest translated label, and `ScanCommandTests` pins the source language so its
  assertions do not depend on the host's locale. The JSON's keys and category raw values
  are never localized.
