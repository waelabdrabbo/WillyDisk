// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WillyDisk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WillyDisk", targets: ["WillyDiskApp"]),
        .library(name: "DiskCore", targets: ["DiskCore"]),
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

        // DiskCLI — the `WillyDisk scan` front end. Depends on DiskCore only: the
        // command line consumes the same engine as the app and never loads UI.
        .target(
            name: "DiskCLI",
            dependencies: ["DiskCore"],
            exclude: ["AGENTS.md"]
        ),

        // DiskUI — SwiftUI design system + screens. Depends on the shared models.
        // The directory's AGENTS.md carries agent-facing notes, not package resources.
        // `Resources/AppMark.png` is the mark `Scripts/make-icon.swift` draws.
        .target(
            name: "DiskUI",
            dependencies: ["DiskCore"],
            exclude: ["AGENTS.md"],
            resources: [.process("Resources")]
        ),

        // WillyDiskApp — @main executable that owns the window and wiring, and
        // dispatches `WillyDisk scan …` to DiskCLI before any UI exists.
        .executableTarget(
            name: "WillyDiskApp",
            dependencies: ["DiskCore", "DiskUI", "DiskCLI"]
        ),

        // Test targets: engine behavior in DiskCoreTests, the command line in
        // DiskCLITests, independent verification in QATests.
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["DiskCore"]
        ),
        .testTarget(
            name: "DiskCLITests",
            dependencies: ["DiskCLI", "DiskCore"]
        ),
        .testTarget(
            name: "QATests",
            dependencies: ["DiskCore", "DiskUI"]
        ),
    ]
)
