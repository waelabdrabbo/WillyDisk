// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WillyDisk",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WillyDisk", targets: ["WillyDiskApp"]),
        .executable(name: "render-screens", targets: ["RenderScreens"]),
        .library(name: "DiskCore", targets: ["DiskCore"]),
        .library(name: "DiskLocalization", targets: ["DiskLocalization"]),
        .library(name: "DiskUI", targets: ["DiskUI"]),
    ],
    targets: [
        // DiskCore — pure logic (frozen models + scanning contracts). No UI, no deps.
        // The directory's AGENTS.md carries agent-facing notes, not package resources.
        .target(
            name: "DiskCore",
            dependencies: [],
            exclude: ["AGENTS.md"]
        ),

        // DiskLocalization — the string catalog and its one lookup path. It is
        // Foundation only, so the command line can use it without loading UI.
        .target(
            name: "DiskLocalization",
            // The catalog is the source of truth; `Scripts/localize.sh`
            // compiles it into the `.lproj` resources SwiftPM links, so the
            // package never asks the toolchain to derive Swift symbols for
            // format-only keys.
            exclude: ["AGENTS.md", "Localizable.xcstrings"],
            resources: [.process("Resources")]
        ),

        // DiskCLI — the `WillyDisk scan` front end. Depends on DiskCore only: the
        // command line consumes the same engine as the app and never loads UI.
        .target(
            name: "DiskCLI",
            dependencies: ["DiskCore", "DiskLocalization"],
            exclude: ["AGENTS.md"]
        ),

        // DiskUpdate — the release feed, version comparison, checksum, and
        // staged-bundle verification. Foundation and CryptoKit only: no UI, no
        // localization, no third-party package. The controller and sheet live in
        // DiskUI; this target must stay usable without AppKit.
        .target(
            name: "DiskUpdate",
            dependencies: [],
            exclude: ["AGENTS.md"]
        ),

        // DiskUI — SwiftUI design system + screens. Depends on the shared models
        // and the update core. The directory's AGENTS.md carries agent-facing
        // notes, not package resources. `Resources/AppMark.png` is the mark
        // `Scripts/make-icon.swift` draws.
        .target(
            name: "DiskUI",
            dependencies: ["DiskCore", "DiskLocalization", "DiskUpdate"],
            exclude: ["AGENTS.md"],
            resources: [.process("Resources")]
        ),

        // WillyDiskApp — @main executable that owns the window and wiring, and
        // dispatches `WillyDisk scan …` to DiskCLI before any UI exists.
        .executableTarget(
            name: "WillyDiskApp",
            dependencies: ["DiskCore", "DiskUI", "DiskCLI", "DiskLocalization"]
        ),

        // RenderScreens — the offscreen renderer `Scripts/render-screens.sh` runs.
        // It is tooling, not a shipped product, so it lives with the other scripts
        // and SwiftPM builds it beside the UI's resource bundle. Building it here
        // lets SwiftPM link the package on every build system; the older one keeps
        // no library archives a hand-written `swiftc` could link.
        .executableTarget(
            name: "RenderScreens",
            dependencies: ["DiskCore", "DiskUI", "DiskLocalization"],
            path: "Scripts/RenderScreens"
        ),

        // Test targets: engine behavior in DiskCoreTests, the command line in
        // DiskCLITests, independent verification in QATests.
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["DiskCore"]
        ),
        .testTarget(
            name: "DiskCLITests",
            dependencies: ["DiskCLI", "DiskCore", "DiskLocalization"]
        ),
        .testTarget(
            name: "DiskUpdateTests",
            dependencies: ["DiskUpdate"]
        ),
        .testTarget(
            name: "QATests",
            dependencies: ["DiskCore", "DiskUI", "DiskLocalization", "DiskCLI"]
        ),
    ]
)
