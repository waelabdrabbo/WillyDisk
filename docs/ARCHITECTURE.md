# WillyDisk — Architecture & Shared Contracts

> The frozen Architecture & Shared Contracts document. A change to a shared interface is
> a design change: raise it in an issue or a pull request, and update this document in
> the same change — do not silently diverge.

## 1. Environment (verified)

- macOS 27.0.1, Xcode 27.0, Swift 6.4.
- No xcodegen/tuist. `git`, `jq`, `python3` available.
- **Project workspace (repo root):** this repository.

## 2. Project layout — Swift Package Manager (no `.xcodeproj`)

Deployment target **macOS 14**.

```
Package.swift
Sources/
  DiskCore/                 # pure logic, no UI
    Models/                 # frozen value model
    Scanning/               # scan engine implementations
    Scanning/Contracts.swift# frozen protocols/types
  DiskUI/                   # SwiftUI + design system
    DesignSystem/
    Components/
    Screens/
  WillyDiskApp/             # @main executable, window, wiring
Tests/
  DiskCoreTests/            # engine tests
  QATests/                  # independent verification
Scripts/bundle-app.sh       # builds the .app bundle
docs/                       # ARCHITECTURE.md
```

`Package.swift` products: executable `WillyDisk`; libraries `DiskCore`, `DiskUI`.

Commands:

- Build: `swift build`
- Test: `swift test`
- Run (dev): `bash Scripts/run.sh` → builds `.build/WillyDisk.app` and opens it.
  Do **not** use `swift run WillyDisk` to inspect the UI: a bare SwiftPM binary
  is stamped with the deployment target as its linked SDK and renders the legacy
  window chrome (see §6, "Window chrome / Liquid Glass"). `Scripts/run.sh` goes
  through `bundle-app.sh`, which restamps the SDK.
- Bundle: `bash Scripts/bundle-app.sh` → `.build/WillyDisk.app` (launch with `open`)

## 3. Frozen data model (`DiskCore/Models`)

All types `public`, `Sendable`, Swift 6 concurrency-safe.

```swift
public enum FileCategory: String, CaseIterable, Codable, Sendable {
    case applications, documents, images, video, audio, archives, code, system, other
}

/// A node in the scanned tree. Value type, compact.
public struct ScanNode: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let category: FileCategory
    public let logicalSize: Int64      // sum of file logical sizes in subtree
    public let allocatedSize: Int64    // on-disk allocated bytes (st_blocks*512) where available
    public let fileCount: Int          // files in subtree (1 for a file)
    public let directoryCount: Int     // dirs in subtree
    public let modifiedAt: Date?
    public let isAccessible: Bool
    public let errorMessage: String?
    public let children: [ScanNode]    // sorted desc by logicalSize; empty for files
    public var isLeaf: Bool { !isDirectory }
}

/// Terminal result (`.finished`) and in-flight snapshot (`.partial`); for a
/// partial snapshot `finishedAt` is the snapshot timestamp.
public struct ScanSummary: Sendable {
    public let root: URL
    public let totalLogicalSize: Int64
    public let totalAllocatedSize: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let inaccessibleCount: Int       // distinct dirs that could not be read
    public let errorCount: Int              // truthful, uncapped non-fatal issue total
    public let permissionDeniedCount: Int   // TCC/POSIX-denied dirs (⊆ inaccessibleCount); drives the banner
    public let surfacedIssueCount: Int      // per-path issue events actually surfaced (≤ engine cap)
    public let startedAt: Date
    public let finishedAt: Date
    public let categoryBreakdown: [FileCategory: Int64]   // by logical size
    public let largestFiles: [ScanNode]                   // top N, default 100
    public let largestDirectories: [ScanNode]             // top N, default 100
}
```

## 4. Frozen scanning contract (`DiskCore/Scanning/Contracts.swift`)

The engine implements this contract in `Sources/DiskCore/Scanning/`.

```swift
public struct ScanRequest: Sendable {
    public var root: URL
    public var followSymlinks: Bool = false   // default safe: do not follow
    public var stayOnVolume: Bool = true      // do not cross mount boundaries
    public var includeHidden: Bool = true
    public init(root: URL, followSymlinks: Bool = false, stayOnVolume: Bool = true, includeHidden: Bool = true)
}

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let filesScanned: Int
    public let directoriesScanned: Int
    public let bytesScanned: Int64
    /// nil when progress cannot be computed reliably (e.g. no known total). Never fabricate.
    public let fractionCompleted: Double?
    public let elapsed: TimeInterval
}

public enum ScanEvent: Sendable {
    case started(root: URL)
    case progress(ScanProgress)
    /// Non-fatal; the scan continues. Carries the `ScanIssueKind` so a consumer
    /// can separate expected permission denials from hard faults.
    case issue(kind: ScanIssueKind, path: String, message: String)
    /// Progressive, non-terminal snapshot of results accumulated so far. May be
    /// emitted zero or more times between `.started` and the single terminal event.
    /// Payload is a `ScanSummary` populated only with completed work; `finishedAt`
    /// is the snapshot timestamp. Never fabricated, never terminal.
    case partial(ScanSummary)
    case finished(ScanSummary)
    case cancelled(partial: ScanSummary?)        // cancellation is a first-class outcome
}

/// Classifier vocabulary shared by the engine and the UI.
public enum ScanIssueKind: Sendable, Hashable {
    case permissionDenied, brokenSymlink, io, other
}

public protocol ScanEngine: Sendable {
    /// Streams events. May emit zero or more non-terminal `.partial` snapshots,
    /// then emits `.finished` or `.cancelled` exactly once, then ends.
    func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent>
    func cancel() async
}
```

Rules: one dedicated `Task`/actor does filesystem work; never on the main actor.
Issues never terminate the scan; each surfaced `.issue` carries a `ScanIssueKind`.
The per-path issue stream is bounded by the engine while
`ScanSummary.errorCount` stays the truthful, uncapped total; `surfacedIssueCount`
reports how many were actually surfaced. Symlink loops and out-of-scope
traversal must be prevented (track visited dev/inode). Progress
`fractionCompleted` is `nil` unless a reliable total is known. Progressive
`.partial` snapshots are non-terminal: the engine may emit any number of them,
each reflecting only completed work, and the stream still ends with exactly one
`.finished` or `.cancelled`.

## 5. UI contract (DiskUI)

- `ScanViewModel` (`@MainActor @Observable`) drives the scan flow through its
  phases from `AsyncStream<ScanEvent>`; it calls `DiskCore` only — never
  re-implements scanning.
- `ScanEvent.partial` lets the results screen render progressively while a scan
  runs: the same `ScanSummary` shape (tree, largest items, category breakdown)
  updates in place, then the terminal `.finished` summary replaces it. Snapshots
  are advisory — the engine may throttle or omit them — and `.partial` is never
  terminal.
- Screens: `SourceSelectionView` (A) and `ResultsView` (C). Scanning is not a
  separate screen: `ScanFlowView` routes the model's `.scanning` phase to
  `ResultsView`, which renders the honest in-progress state until the terminal
  summary arrives. `WillyDiskApp` (`Sources/WillyDiskApp`) owns the window and
  injects the view model: `AppState` creates one
  `ScanViewModel(engine: FileScanEngine())` and `ContentView` hosts
  `ScanFlowView`, which switches between source selection and results on the view
  model's phase. There is no separate sidebar/toolbar navigation — a single
  "Choose Folder…" menu command (⌘O) opens a panel and starts a real scan.
- Design tokens live in `DiskUI/DesignSystem/DesignSystem.swift` (spacing scale,
  corner radii, typography roles, semantic colors). UI never hard-codes magic numbers.
- The disk chart is `SunburstView` — custom SwiftUI shapes with ring/angle
  geometry, no third-party deps.

## 6. Compatibility rules (all agents)

- Deployment target macOS 14; verify APIs instead of assuming.
- Liquid Glass is an enhancement: guard with `if #available(macOS 26.0, *)`
  (e.g. `.glassEffect`, `GlassEffectContainer`). macOS 15 → materials/translucency;
  macOS 14 → solid native surfaces, separators, restrained depth.
- **Window chrome / Liquid Glass (SDK stamp).** macOS 26+ gates the window
  chrome — traffic-light style, titlebar/toolbar layout, window corner radius,
  and automatic "modern" control rendering — on a linked-on-or-after check
  against the executable's `LC_BUILD_VERSION` `sdk` field. SwiftPM stamps that
  field with the *deployment target* (14.0), so a plain `swift build` / `swift run`
  binary is treated as pre-Tahoe and draws the legacy window (old traffic lights,
  centered title, toolbar that does not line up with the buttons). The bundle
  script restamps `sdk` to the real SDK with `vtool` while keeping `minos 14.0`,
  and fails loudly if the stamp is wrong. Always validate UI through
  `Scripts/run.sh` / `Scripts/bundle-app.sh`, and verify with
  `xcrun vtool -show-build .build/WillyDisk.app/Contents/MacOS/WillyDisk`
  (expect `sdk` ≥ 26, `minos` 14.0). `glassEffect` is unaffected — it is an
  explicit runtime call — only *automatic* control/chrome modernization is
  SDK-gated.
- Never call a newer API unguarded. No third-party packages without approval.
- Light and dark must both be polished; controls keyboard-accessible.

## 7. Shared interfaces & change process

- The frozen surfaces are `Sources/DiskCore/Models/**` and
  `Sources/DiskCore/Scanning/Contracts.swift`. A change to either is a design change,
  not a refactor: explain the reasoning in the pull request and update this document in
  the same change.
- `Package.swift`, `Scripts/**`, and this document are shared too. When a change to one
  of them affects another area, say so in the pull request rather than working around it.
- Everything else is ordinary code. Keep it consistent with the files around it.

## 8. Non-negotiables

Off-main-thread scanning; working cancellation; graceful permission failures; no
automatic deletion (confirmation + clear identification only); no fabricated
progress/statistics; no dead controls; no placeholder/mock data in the shipped app.

**Comments are evergreen.** A code comment must never cite a task, issue, or bug
number, and must never narrate the bug a change fixed. Comments explain only current
intent and behavior — they are not a changelog. See `CONTRIBUTING.md`.
