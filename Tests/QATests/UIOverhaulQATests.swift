import XCTest
import SwiftUI
@testable import DiskCore
@testable import DiskUI

/// Independent QA verification of the two-screen scan flow and the sunburst chart.
///
/// These tests re-derive the behaviour the UI promises, without trusting any
/// completion report:
///
/// * the sunburst's ring/angle geometry is proportional to real sizes, groups
///   excess children into one truthful remainder, ignores zero-size nodes, and
///   never lets a deeper ring escape its parent's span;
/// * the results screen's live state is fed by the engine's non-terminal
///   snapshots — items exist and grow *during* a scan, the terminal summary
///   supersedes the snapshot, and a cancelled scan keeps what it gathered;
/// * the engine never fabricates a completion fraction, so the in-progress
///   header can only ever show an honest indeterminate state with the shipped
///   engine;
/// * the Full Disk Access banner is driven by permission denials only, and the
///   detail list stays bounded while reporting the truthful total.
@MainActor
final class UIOverhaulQATests: XCTestCase {

    // MARK: - Fixtures

    private func makeNode(
        _ name: String,
        size: Int64,
        isDirectory: Bool = true,
        category: FileCategory = .other,
        path: String? = nil,
        children: [ScanNode] = []
    ) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path ?? "/qa/\(name)"),
            name: name,
            isDirectory: isDirectory,
            isSymlink: false,
            category: category,
            logicalSize: size,
            allocatedSize: size,
            fileCount: isDirectory ? children.filter { !$0.isDirectory }.count : 1,
            directoryCount: isDirectory ? children.filter(\.isDirectory).count : 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: children
        )
    }

    private func makeSummary(
        root: URL = URL(fileURLWithPath: "/qa"),
        logical: Int64 = 100,
        fileCount: Int = 1,
        directoryCount: Int = 1,
        errorCount: Int = 0,
        permissionDeniedCount: Int = 0,
        surfacedIssueCount: Int = 0,
        inaccessibleCount: Int = 0,
        largestDirectories: [ScanNode] = []
    ) -> ScanSummary {
        ScanSummary(
            root: root,
            totalLogicalSize: logical,
            totalAllocatedSize: logical,
            fileCount: fileCount,
            directoryCount: directoryCount,
            inaccessibleCount: inaccessibleCount,
            errorCount: errorCount,
            permissionDeniedCount: permissionDeniedCount,
            surfacedIssueCount: surfacedIssueCount,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: [.documents: logical],
            largestFiles: [],
            largestDirectories: largestDirectories
        )
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func makeFlatTree(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskUIOverhaul-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        for i in 0..<fileCount {
            try payload.write(to: root.appendingPathComponent("f\(i).txt"))
        }
        return root
    }

    // MARK: - Sunburst geometry

    func testFirstRingSpansTheFullCircleProportionally() {
        let roots = [
            makeNode("big", size: 500),
            makeNode("mid", size: 300),
            makeNode("small", size: 200),
        ]
        let segments = SunburstLayout.segments(roots: roots, maxRings: 3, maxChildren: 12)
        let ring1 = segments.filter { $0.ring == 1 }

        XCTAssertEqual(ring1.count, 3, "each positive-size child gets exactly one ring-1 wedge")
        XCTAssertEqual(ring1.first?.start ?? -1, 0, accuracy: 1e-9, "the first wedge starts at 12 o'clock")
        XCTAssertEqual(ring1.last?.end ?? -1, 2 * .pi, accuracy: 1e-9, "ring 1 closes the full circle")

        let spans = ring1.map { $0.end - $0.start }
        XCTAssertEqual(spans[0], 2 * .pi * 0.5, accuracy: 1e-9)
        XCTAssertEqual(spans[1], 2 * .pi * 0.3, accuracy: 1e-9)
        XCTAssertEqual(spans[2], 2 * .pi * 0.2, accuracy: 1e-9)
        // Contiguous, no overlap.
        for pair in zip(ring1, ring1.dropFirst()) {
            XCTAssertEqual(pair.0.end, pair.1.start, accuracy: 1e-9)
        }
    }

    // MARK: - Chart colour and the explorer icons

    /// A node's wedge colour and the same node's icon colour are one mapping.
    ///
    /// The explorer tints each row's icon from the chart's own layout
    /// (`SunburstLayout.fillsByPath`), so the two must agree for every entry the
    /// chart draws — the focused directory's own entries, and the descendants it
    /// draws on the rings outside them.
    func testIconColourMatchesTheWedgeColourForEveryEntry() {
        let deep = [
            makeNode("a.txt", size: 90, isDirectory: false, category: .documents, path: "/qa/Big/a.txt"),
            makeNode("b.txt", size: 60, isDirectory: false, category: .code, path: "/qa/Big/b.txt"),
        ]
        let roots = [
            makeNode("Big", size: 1000, path: "/qa/Big", children: deep),
            makeNode("Mid", size: 500, path: "/qa/Mid"),
            makeNode("Small", size: 100, isDirectory: false, category: .images, path: "/qa/small.png"),
        ]
        let segments = SunburstLayout.segments(roots: roots, maxRings: 3, maxChildren: 12)
        let fills = SunburstLayout.fillsByPath(roots: roots)

        XCTAssertFalse(segments.isEmpty)
        for segment in segments {
            guard let node = segment.node else { continue }
            XCTAssertEqual(fills[node.url.path], segment.fill,
                           "\(node.name)'s row icon must wear the colour of its own wedge")
        }

        // Ring 1, as the explorer lists it while the scanned root is focused, and
        // ring 2, as the detail pane shows a file picked inside a ring-1 folder.
        XCTAssertEqual(fills["/qa/Big"], segments.first { $0.node?.url.path == "/qa/Big" }?.fill)
        XCTAssertNotNil(fills["/qa/Big/a.txt"],
                        "the chart draws this file on an outer ring, so its icon has a colour")
        XCTAssertEqual(fills["/qa/Big/a.txt"],
                       segments.first { $0.node?.url.path == "/qa/Big/a.txt" }?.fill)
    }

    /// Drilling into a folder re-roots the chart, and the explorer follows it.
    ///
    /// The focused folder's children open colour families of their own on ring 1;
    /// they do not keep the family hue their folder wore one ring out. Colouring
    /// the icons from the levels *above* the focused folder painted every child in
    /// its parent's hue — the one colour the chart never draws them in.
    func testDrilledInChildrenWearTheirWedgeColourRatherThanTheirFolderHue() {
        let deep = [
            makeNode("a.txt", size: 90, isDirectory: false, category: .documents, path: "/qa/Big/a.txt"),
            makeNode("b.txt", size: 60, isDirectory: false, category: .code, path: "/qa/Big/b.txt"),
        ]
        let roots = [
            makeNode("Big", size: 1000, path: "/qa/Big", children: deep),
            makeNode("Mid", size: 500, path: "/qa/Mid"),
        ]
        let outerFills = SunburstLayout.fillsByPath(roots: roots)
        let focused = SunburstLayout.segments(roots: deep, maxRings: 3, maxChildren: 12)
        let focusedFills = SunburstLayout.fillsByPath(roots: deep)

        for child in deep {
            let wedge = focused.first { $0.node?.url == child.url }
            XCTAssertEqual(focusedFills[child.url.path], wedge?.fill,
                           "\(child.name)'s row icon must wear the colour of the wedge it is drawn as")
            XCTAssertNotEqual(focusedFills[child.url.path], outerFills[child.url.path],
                              "\(child.name) is coloured by the chart it is drawn in, not by the ring it left")
        }
    }

    /// A deeper entry inherits its subtree's hue in a softer shade, so the rings
    /// of one family stay legible and no descendant is mistaken for a sibling of
    /// its ancestor.
    func testDescendantKeepsItsFamilyHueInASofterShade() {
        let parent = makeNode("Family", size: 300, path: "/qa/Family")
        let rootFills = ChartPalette.fills(for: [parent], ring: 1, parentFill: nil)
        guard case .palette(let familyHue, let familyRing, _)? = rootFills[parent.url.path] else {
            return XCTFail("the first ring must colour by the tree-position palette")
        }
        XCTAssertEqual(familyRing, 1)

        let childFills = ChartPalette.fills(for: [makeNode("kid", size: 10, path: "/qa/Family/kid")],
                                            ring: 2, parentFill: rootFills[parent.url.path])
        guard case .palette(let childHue, let childRing, _)? = childFills["/qa/Family/kid"] else {
            return XCTFail("a descendant must keep the palette")
        }
        XCTAssertEqual(childRing, 2, "a child of a ring-1 folder is drawn on ring 2")
        XCTAssertLessThanOrEqual(abs(childHue - familyHue),
                                 DS.Sunburst.paletteFamilySpread + 1e-9,
                                 "a descendant stays inside its family's hue spread")
    }

    /// One family is one hue, and every ring outward is a paler tint of it.
    ///
    /// Saturation falls and brightness rises with each ring, so depth reads as the
    /// same colour going lighter and the rim is the airiest ring. A ramp that runs
    /// the other way makes a subtree's rings jump between a dark inside and a pale
    /// rim, and a hue that drifts between rings leaves the family looking like
    /// unrelated siblings.
    func testEachRingOutwardIsAPalerTintOfOneHue() {
        let families = [
            ("light", DS.Sunburst.paletteSaturation, DS.Sunburst.paletteBrightness),
            ("dark", DS.Sunburst.paletteDarkSaturation, DS.Sunburst.paletteDarkBrightness),
        ]
        for (name, saturation, brightness) in families {
            XCTAssertEqual(saturation.count, DS.Sunburst.maxRings,
                           "\(name): every ring the chart can draw needs a shade")
            XCTAssertEqual(brightness.count, DS.Sunburst.maxRings)
            for (inner, outer) in zip(saturation, saturation.dropFirst()) {
                XCTAssertGreaterThan(inner, outer,
                                     "\(name): a ring further out must be a paler tint")
            }
            for (inner, outer) in zip(brightness, brightness.dropFirst()) {
                XCTAssertLessThan(inner, outer,
                                  "\(name): a paler tint is also a lighter one")
            }
            for value in saturation {
                XCTAssertLessThanOrEqual(value, 0.9,
                                         "\(name): a wedge stays short of a pure hue")
            }
            // The palest ring is still a colour, not white: at the wedge opacity it
            // is drawn with, its saturation has to survive compositing on the pane.
            XCTAssertGreaterThan(Self.compositeSaturation(saturation.last!, brightness.last!),
                                 0.2,
                                 "\(name): the palest ring keeps a readable hue")
        }

        // A sibling group spans its family hue tightly while each index still
        // takes a shade of its own.
        let parent = makeNode("Family", size: 300, path: "/qa/Family")
        let siblings = (0..<6).map { makeNode("kid\($0)", size: 10, path: "/qa/Family/kid\($0)") }
        let parentFill = ChartPalette.fills(for: [parent], ring: 1, parentFill: nil)[parent.url.path]
        let fills = ChartPalette.fills(for: siblings, ring: 2, parentFill: parentFill)
        var hues: [Double] = []
        for sibling in siblings {
            guard case .palette(let hue, let ring, _)? = fills[sibling.url.path] else {
                return XCTFail("a descendant must keep the palette")
            }
            XCTAssertEqual(ring, 2)
            hues.append(hue)
        }
        XCTAssertEqual(hues.count, siblings.count)
        XCTAssertLessThanOrEqual(hues.max()! - hues.min()!,
                                 2 * DS.Sunburst.paletteFamilySpread + 1e-9,
                                 "siblings differ in shade, not by leaving the family hue")
    }

    /// The saturation the eye gets once a wedge is drawn at the chart's own
    /// opacity: the fill is composited over the pane, so a pale tint loses a
    /// little of its colour on the way to the screen.
    private static func compositeSaturation(_ saturation: Double, _ brightness: Double) -> Double {
        let background = 0.5
        let drawn = brightness * DS.Sunburst.fillOpacity + background * (1 - DS.Sunburst.fillOpacity)
        return saturation * brightness / max(drawn, 0.0001)
    }

    /// An entry with no bytes is not drawn by the chart, so it wears the neutral
    /// tint rather than claiming a colour the chart does not show.
    func testZeroSizeEntryHasNoChartColour() {
        let roots = [
            makeNode("real", size: 100, path: "/qa/real"),
            makeNode("empty", size: 0, path: "/qa/empty"),
        ]
        let fills = ChartPalette.fills(for: roots, ring: 1, parentFill: nil)
        XCTAssertNotNil(fills["/qa/real"])
        XCTAssertNil(fills["/qa/empty"], "a zero-byte entry has no wedge and so no chart colour")
    }

    func testExcessChildrenCollapseIntoOneTruthfulRemainder() {
        // 20 children, chart draws 12 → 12 named wedges + one aggregate wedge.
        let roots = (0..<20).map { makeNode("child\($0)", size: Int64(1000 - $0)) }
        let segments = SunburstLayout.segments(roots: roots, maxRings: 1, maxChildren: 12)
        let named = segments.filter { $0.node != nil }
        let remainder = segments.filter { $0.node == nil }

        XCTAssertEqual(named.count, 12)
        XCTAssertEqual(remainder.count, 1, "exactly one aggregate wedge for the hidden children")
        XCTAssertEqual(remainder.first?.remainderCount, 8)

        let hiddenSize = (12..<20).reduce(Int64(0)) { $0 + Int64(1000 - $1) }
        XCTAssertEqual(remainder.first?.size, hiddenSize, "the aggregate wedge carries the hidden bytes, not a guess")

        // Angles still account for the whole parent span including the remainder.
        let total = segments.reduce(0.0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(total, 2 * .pi, accuracy: 1e-9)
    }

    func testZeroSizeNodesAreNeverPlaced() {
        // An empty folder and an unreadable folder both report 0 bytes; neither
        // may paint a wedge over the chart.
        let roots = [
            makeNode("data", size: 4096),
            makeNode("empty", size: 0),
            makeNode("unreadable", size: 0),
        ]
        let segments = SunburstLayout.segments(roots: roots, maxRings: 3, maxChildren: 12)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.node?.name, "data")
        XCTAssertEqual(segments.first?.start ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(segments.first?.end ?? -1, 2 * .pi, accuracy: 1e-9)
    }

    func testDeeperRingsStayInsideTheirParentSpan() {
        let a1 = makeNode("a1", size: 60, isDirectory: false, category: .documents, path: "/qa/A/a1")
        let a2 = makeNode("a2", size: 40, isDirectory: false, category: .video, path: "/qa/A/a2")
        let b1 = makeNode("b1", size: 100, isDirectory: false, category: .images, path: "/qa/B/b1")
        let roots = [
            makeNode("A", size: 100, path: "/qa/A", children: [a1, a2]),
            makeNode("B", size: 100, path: "/qa/B", children: [b1]),
        ]
        let segments = SunburstLayout.segments(roots: roots, maxRings: 3, maxChildren: 12)
        let ring1 = segments.filter { $0.ring == 1 }
        let ring2 = segments.filter { $0.ring == 2 }

        XCTAssertEqual(ring1.count, 2)
        XCTAssertEqual(ring2.count, 3)

        for parent in ring1 {
            guard let parentURL = parent.node?.url else { return XCTFail("ring-1 wedge without a node") }
            let parentPath = parentURL.standardizedFileURL.path
            let children = ring2.filter {
                guard let childURL = $0.node?.url else { return false }
                return childURL.deletingLastPathComponent().standardizedFileURL.path == parentPath
            }
            XCTAssertFalse(
                children.isEmpty,
                "\(parent.node?.name ?? "?") [\(parentPath)] should place its children in ring 2"
            )
            for child in children {
                XCTAssertGreaterThanOrEqual(child.start, parent.start - 1e-9)
                XCTAssertLessThanOrEqual(child.end, parent.end + 1e-9)
            }
        }

        // A child's share of its parent's span mirrors its share of the bytes.
        let a = ring1.first { $0.node?.name == "A" }!
        let childA1 = ring2.first { $0.node?.name == "a1" }!
        let parentSpan = a.end - a.start
        XCTAssertEqual((childA1.end - childA1.start) / parentSpan, 0.6, accuracy: 1e-9)
    }

    func testEmptyInputProducesNoSegments() {
        XCTAssertTrue(SunburstLayout.segments(roots: [], maxRings: 3, maxChildren: 12).isEmpty)
        XCTAssertTrue(
            SunburstLayout.segments(roots: [makeNode("zero", size: 0)], maxRings: 3, maxChildren: 12).isEmpty
        )
    }

    func testCategoryPresentationIsDistinctPerCategory() {
        let names = Set(FileCategory.allCases.map(\.displayName))
        let symbols = Set(FileCategory.allCases.map(\.symbolName))
        XCTAssertEqual(names.count, FileCategory.allCases.count)
        XCTAssertEqual(symbols.count, FileCategory.allCases.count)
    }

    /// A drive offered under Volumes must not also be offered under Recent.
    ///
    /// Scanning a volume records it as a recent location too, so the two sections
    /// would otherwise list the same drive, the volume row saying strictly more
    /// about it. A location *inside* a volume is not that volume and keeps its
    /// recent row.
    func testVolumeMountPointsAreNotAlsoRecentLocations() {
        let startupDisk = VolumeInfo(
            url: URL(fileURLWithPath: "/"), name: "Macintosh HD",
            totalCapacity: 1_000, availableCapacity: 400,
            isInternal: true, isReadOnly: false
        )
        let external = VolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Backup"), name: "Backup",
            totalCapacity: 2_000, availableCapacity: 500,
            isInternal: false, isReadOnly: false
        )
        let volumes = [startupDisk, external]

        XCTAssertTrue(
            VolumeInfo.isMountPoint(URL(fileURLWithPath: "/"), ofVolumes: volumes),
            "the startup disk is a mount point"
        )
        XCTAssertTrue(
            VolumeInfo.isMountPoint(URL(fileURLWithPath: "/Volumes/Backup"), ofVolumes: volumes),
            "a mounted external volume is a mount point"
        )
        XCTAssertTrue(
            VolumeInfo.isMountPoint(URL(fileURLWithPath: "/Volumes/Backup/"), ofVolumes: volumes),
            "a trailing separator still names the same mount point"
        )
        XCTAssertFalse(
            VolumeInfo.isMountPoint(URL(fileURLWithPath: "/Volumes/Backup/Photos"), ofVolumes: volumes),
            "a location inside a volume is not the volume"
        )
        XCTAssertFalse(
            VolumeInfo.isMountPoint(URL(fileURLWithPath: "/Users/someone/Documents"), ofVolumes: volumes),
            "an ordinary folder is not a mount point"
        )
        XCTAssertFalse(
            VolumeInfo.isMountPoint(URL(fileURLWithPath: "/"), ofVolumes: []),
            "with no volumes enumerated, nothing is claimed to be a mount point"
        )
    }

    /// The hover the explorer and the chart share is what lights one from the
    /// other, so the rule that publishes it is verified on its own: entering a row
    /// claims the hover, and only the row that still holds it clears it — a row
    /// the pointer has already left must not drop the row it is on now.
    func testHoverIsClaimedByARowAndClearedOnlyByThatRow() {
        let hover = ChartHover()
        let first = URL(fileURLWithPath: "/qa/first")
        let second = URL(fileURLWithPath: "/qa/second")
        XCTAssertNil(hover.url, "nothing is hovered before the pointer arrives")

        hover.set(first, true)
        XCTAssertEqual(hover.url, first)

        hover.set(second, true)
        hover.set(first, false)
        XCTAssertEqual(hover.url, second, "leaving the old row does not clear the new one")

        hover.set(second, false)
        XCTAssertNil(hover.url)

        hover.set(first, true)
        hover.set(second, false)
        XCTAssertEqual(hover.url, first, "leaving a row that was never hovered changes nothing")
    }

    // MARK: - Live results: the model the results screen renders

    /// A scripted engine, so the view model's live/growing state can be asserted
    /// without racing a real scan.
    private final class ScriptedEngine: ScanEngine, @unchecked Sendable {
        let stream: AsyncStream<ScanEvent>
        private let continuation: AsyncStream<ScanEvent>.Continuation

        init() {
            (stream, continuation) = AsyncStream<ScanEvent>.makeStream()
        }

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> { stream }
        func cancel() async {}
        func emit(_ event: ScanEvent) { continuation.yield(event) }
        func end() { continuation.finish() }
    }

    func testLiveSummaryTracksSnapshotsThenTheTerminalResult() async {
        let engine = ScriptedEngine()
        let vm = ScanViewModel(engine: engine)
        let root = URL(fileURLWithPath: "/qa/live")

        vm.start(root: root)
        XCTAssertEqual(vm.phase, .scanning)
        XCTAssertNil(vm.liveSummary, "nothing is shown before the first snapshot arrives")

        let snapshot = makeSummary(
            root: root,
            logical: 1_000,
            fileCount: 3,
            directoryCount: 2,
            largestDirectories: [makeNode("Videos", size: 900)]
        )
        engine.emit(.started(root: root))
        engine.emit(.progress(ScanProgress(
            currentPath: "/qa/live/Videos/clip.mp4",
            filesScanned: 3, directoriesScanned: 2, bytesScanned: 1_000,
            fractionCompleted: nil, elapsed: 0.2
        )))
        engine.emit(.partial(snapshot))

        let live = await waitUntil { vm.liveSummary != nil }
        XCTAssertTrue(live, "the partial snapshot must reach the results screen")
        XCTAssertTrue(vm.isScanning, "the scan is still running while the snapshot is shown")
        XCTAssertEqual(vm.liveSummary?.totalLogicalSize, 1_000)
        XCTAssertEqual(vm.liveSummary?.largestDirectories.first?.name, "Videos")
        XCTAssertEqual(vm.filesScanned, 3)
        XCTAssertNil(vm.progress?.fractionCompleted, "no reliable total → no fraction")

        let terminal = makeSummary(
            root: root,
            logical: 5_000,
            fileCount: 12,
            directoryCount: 6,
            largestDirectories: [makeNode("Videos", size: 4_000)]
        )
        engine.emit(.finished(terminal))

        let finished = await waitUntil { vm.phase == .finished }
        XCTAssertTrue(finished)
        XCTAssertEqual(vm.liveSummary?.totalLogicalSize, 5_000, "the terminal summary supersedes the snapshot")
        XCTAssertTrue(vm.hasResults)
        engine.end()
    }

    func testCancelledScanKeepsTheGatheredResultsForTheScreen() async {
        let engine = ScriptedEngine()
        let vm = ScanViewModel(engine: engine)
        let root = URL(fileURLWithPath: "/qa/cancel")
        let partial = makeSummary(root: root, logical: 2_000, fileCount: 7, directoryCount: 3)

        vm.start(root: root)
        engine.emit(.started(root: root))
        engine.emit(.partial(partial))
        _ = await waitUntil { vm.liveSummary != nil }

        engine.emit(.cancelled(partial: partial))
        let stopped = await waitUntil { vm.phase == .cancelled }
        XCTAssertTrue(stopped)
        XCTAssertTrue(vm.hasResults, "a cancelled scan with partial results keeps them on screen")
        XCTAssertEqual(vm.liveSummary?.totalLogicalSize, 2_000)
        engine.end()
    }

    // MARK: - Live results against the real engine

    func testRealEngineStreamsGrowingResultsBeforeTheScanEnds() async throws {
        let root = try makeFlatTree(fileCount: 12_000)
        defer { try? FileManager.default.removeItem(at: root) }

        let engine = FileScanEngine()
        var partials: [ScanSummary] = []
        var finals: [ScanSummary] = []
        var fractions: [Double?] = []
        var fileCountsAtProgress: [Int] = []

        for await event in engine.scan(ScanRequest(root: root)) {
            switch event {
            case .partial(let snapshot): partials.append(snapshot)
            case .progress(let progress):
                fractions.append(progress.fractionCompleted)
                fileCountsAtProgress.append(progress.filesScanned)
            case .finished(let summary): finals.append(summary)
            default: break
            }
        }

        XCTAssertEqual(finals.count, 1, "exactly one terminal result")
        XCTAssertFalse(partials.isEmpty, "a scan this large must stream at least one snapshot")
        XCTAssertLessThan(partials.count, 100, "snapshots are throttled, not emitted per file")

        // Results exist and carry real items *during* the scan.
        let first = try XCTUnwrap(partials.first)
        XCTAssertGreaterThan(first.totalLogicalSize, 0)
        XCTAssertFalse(first.largestFiles.isEmpty, "the live results screen needs items to render")

        // Snapshots only ever report completed work, and grow towards the final.
        for pair in zip(partials, partials.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.totalLogicalSize, pair.1.totalLogicalSize)
            XCTAssertLessThanOrEqual(pair.0.fileCount, pair.1.fileCount)
        }
        let last = try XCTUnwrap(partials.last)
        let terminal = try XCTUnwrap(finals.first)
        XCTAssertLessThanOrEqual(last.totalLogicalSize, terminal.totalLogicalSize)
        XCTAssertEqual(terminal.fileCount, 12_000)

        // No fabricated completion: the engine never guesses a fraction, so the
        // in-progress header can only be indeterminate.
        XCTAssertTrue(fractions.allSatisfy { $0 == nil }, "progress must not invent a fraction")
        XCTAssertFalse(fractions.isEmpty, "progress events should be emitted while scanning")
        XCTAssertEqual(fileCountsAtProgress, fileCountsAtProgress.sorted(), "progress counts never go backwards")
        XCTAssertLessThanOrEqual(fileCountsAtProgress.last ?? .max, terminal.fileCount)
    }

    // MARK: - Issues presentation (Full Disk Access banner + bounded list)

    func testBannerAppearsOnlyForPermissionDenials() {
        let clean = ScanIssuesPresentation(issues: [], summary: makeSummary())
        XCTAssertFalse(clean.shouldShowBanner)
        XCTAssertFalse(clean.hasRows)

        let ioOnly = ScanIssuesPresentation(
            issues: [ScanIssue(path: "/qa/io", message: "I/O error", kind: .io)],
            summary: makeSummary(errorCount: 1, surfacedIssueCount: 1)
        )
        XCTAssertFalse(ioOnly.shouldShowBanner, "an I/O fault is not a Full Disk Access problem")
        XCTAssertTrue(ioOnly.hasRows)
        XCTAssertEqual(ioOnly.listTitle, "Issues")

        let denied = ScanIssuesPresentation(
            issues: [ScanIssue(path: "/qa/denied", message: "denied", kind: .permissionDenied)],
            summary: makeSummary(errorCount: 1, permissionDeniedCount: 1, surfacedIssueCount: 1, inaccessibleCount: 1)
        )
        XCTAssertTrue(denied.shouldShowBanner)
        XCTAssertTrue(denied.isDenialDominated)
        XCTAssertEqual(denied.restrictedLocationCount, 1)
        XCTAssertEqual(denied.listTitle, "Unreadable locations")
    }

    func testIssueListIsBoundedWhileReportingTheTruthfulTotal() {
        let issues = (0..<50).map { ScanIssue(path: "/qa/denied\($0)", message: "denied", kind: .permissionDenied) }
        let presentation = ScanIssuesPresentation(
            issues: issues,
            summary: makeSummary(errorCount: 512, permissionDeniedCount: 512, surfacedIssueCount: 50, inaccessibleCount: 512)
        )
        XCTAssertEqual(presentation.rows.count, 50)
        XCTAssertEqual(presentation.totalIssueCount, 512, "the truthful total is not capped")
        XCTAssertEqual(presentation.unlistedCount, 462)
        XCTAssertEqual(presentation.listSummaryText, "Showing the first 50 of 512 — 462 more not listed")
    }
}
