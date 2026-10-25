import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The screen takes the tree the engine built, instead of converting the summary
/// it was handed. The summary below has no root node, so a conversion from it
/// could not produce a tree at all — the screen must still get one.
@MainActor
final class LiveTreeEngineWiringQATests: XCTestCase {

    private final class ProvidingEngine: ScanEngine, LiveTreeScanning, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<ScanEvent>.Continuation?
        private var tree: LiveTree?

        init(tree: LiveTree) {
            self.tree = tree
        }

        func scan(_ request: ScanRequest) -> AsyncStream<ScanEvent> { open() }

        func scan(_ request: ScanRequest, buildingLiveTree: Bool) -> AsyncStream<ScanEvent> { open() }

        private func open() -> AsyncStream<ScanEvent> {
            let (stream, continuation) = AsyncStream<ScanEvent>.makeStream(bufferingPolicy: .unbounded)
            lock.withLock { self.continuation = continuation }
            return stream
        }

        func emit(_ event: ScanEvent) {
            lock.withLock { continuation }?.yield(event)
        }

        func finish() {
            lock.withLock { continuation }?.finish()
        }

        func cancel() async {
            finish()
        }

        func takeLiveTree() async -> LiveTree? {
            lock.withLock {
                let held = tree
                tree = nil
                return held
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testTheScreenInstallsTheEnginesTreeRatherThanConvertingTheSummary() async {
        let name = "LiveTreeWiringQA-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = UserDefaults(suiteName: name)!
        let preferences = WatchPreferences(defaults: defaults)

        // A summary without a root node: `LiveTree(scanning:)` would refuse it.
        let rootURL = URL(fileURLWithPath: "/scan/tree", isDirectory: true)
        let summary = ScanSummary(
            root: rootURL,
            totalLogicalSize: 10,
            totalAllocatedSize: 10,
            fileCount: 1,
            directoryCount: 1,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: [.documents: 10],
            largestFiles: [],
            largestDirectories: [],
            rootChildren: []
        )
        let tree = LiveTree(rootName: "tree", rootURL: rootURL)
        let engine = ProvidingEngine(tree: tree)
        let viewModel = ScanViewModel(
            engine: engine,
            watchPreferences: preferences,
            watcher: nil
        )

        viewModel.start(root: rootURL, options: .standard)
        engine.emit(.started(root: rootURL))
        engine.emit(.finished(summary))

        let installed = await waitUntil { viewModel.phase == .finished && viewModel.liveTree != nil }
        XCTAssertTrue(installed, "the screen should install the tree the engine built")
        XCTAssertTrue(viewModel.liveTree === tree, "and it should be that tree, not one made from the summary")
        engine.finish()
    }
}
