import XCTest
@testable import DiskCore

/// The live arena: what it builds from a finished scan, what a read returns, and
/// what each kind of edit does to the numbers every screen shows.
final class LiveTreeTests: XCTestCase {

    private let rootURL = URL(fileURLWithPath: "/scan/tree", isDirectory: true)

    // MARK: - Fixtures

    private func file(_ name: String, _ size: Int64, category: FileCategory = .documents) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: rootURL.appendingPathComponent(name),
            name: name,
            isDirectory: false,
            isSymlink: false,
            category: category,
            logicalSize: size,
            allocatedSize: size,
            fileCount: 1,
            directoryCount: 0,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: []
        )
    }

    private func folder(
        _ name: String,
        _ children: [ScanNode],
        url: URL? = nil,
        accessible: Bool = true,
        error: String? = nil
    ) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: url ?? rootURL.appendingPathComponent(name, isDirectory: true),
            name: name,
            isDirectory: true,
            isSymlink: false,
            category: .other,
            logicalSize: children.reduce(0) { $0 + $1.logicalSize },
            allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
            fileCount: children.reduce(0) { $0 + $1.fileCount },
            directoryCount: 1 + children.reduce(0) { $0 + $1.directoryCount },
            modifiedAt: nil,
            isAccessible: accessible,
            errorMessage: error,
            children: children
        )
    }

    /// root/Downloads/{a.bin 1000, b.zip 4000}, root/notes.txt 500, root/empty
    private func sampleRoot() -> ScanNode {
        folder(
            "tree",
            [
                folder("Downloads", [
                    file("a.bin", 1_000),
                    file("b.zip", 4_000, category: .archives),
                ]),
                file("notes.txt", 500),
                folder("empty", []),
            ],
            url: rootURL
        )
    }

    /// root/Open/a.bin, root/Private (unreadable), root/Mixed/{Denied (unreadable), Fine},
    /// root/notes.txt. Two folders in the tree could not be read.
    private func coverageRoot() -> ScanNode {
        folder(
            "tree",
            [
                folder("Open", [file("a.bin", 10)]),
                folder("Private", [], accessible: false, error: "Permission denied"),
                folder("Mixed", [
                    folder("Denied", [], accessible: false, error: "Permission denied"),
                    folder("Fine", []),
                ]),
                file("notes.txt", 5),
            ],
            url: rootURL
        )
    }

    private func makeCoverageTree() throws -> LiveTree {
        try XCTUnwrap(LiveTree(scanning: summary(coverageRoot())))
    }

    private func summary(_ root: ScanNode) -> ScanSummary {
        var categories: [FileCategory: Int64] = [:]
        func visit(_ node: ScanNode) {
            if !node.isDirectory { categories[node.category, default: 0] += node.logicalSize }
            node.children.forEach(visit)
        }
        visit(root)
        return ScanSummary(
            root: rootURL,
            totalLogicalSize: root.logicalSize,
            totalAllocatedSize: root.allocatedSize,
            fileCount: root.fileCount,
            directoryCount: root.directoryCount,
            inaccessibleCount: 0,
            errorCount: 0,
            permissionDeniedCount: 0,
            surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: categories,
            largestFiles: [],
            largestDirectories: [root],
            rootChildren: []
        )
    }

    private func makeTree(file: StaticString = #filePath, line: UInt = #line) throws -> LiveTree {
        try XCTUnwrap(LiveTree(scanning: summary(sampleRoot())), file: file, line: line)
    }

    private func id(_ tree: LiveTree, _ path: String) throws -> LiveNodeID {
        try XCTUnwrap(tree.id(atPath: path), "no entry at \(path)")
    }

    // MARK: - Building

    func testBuildsTheMeasuredTree() throws {
        let tree = try makeTree()

        XCTAssertEqual(tree.rootPath, "/scan/tree")
        XCTAssertEqual(tree.totalLogicalSize, 5_500)
        XCTAssertEqual(tree.totalAllocatedSize, 5_500)
        XCTAssertEqual(tree.fileCount, 3)
        XCTAssertEqual(tree.directoryCount, 3, "the root counts itself")
        XCTAssertEqual(tree.nodeCount, 6)
        XCTAssertEqual(tree.categorySizes(), [.documents: 1_500, .archives: 4_000])

        let root = try XCTUnwrap(tree.entry(for: LiveTree.rootID))
        XCTAssertEqual(root.kind, .directory)
        XCTAssertEqual(root.category, .other, "the root's category is the one its name gives it")
        XCTAssertNil(root.parent)
        XCTAssertEqual(Set(tree.children(of: LiveTree.rootID).map(\.name)), ["Downloads", "notes.txt", "empty"])
    }

    func testAPathFindsItsEntryAndBack() throws {
        let tree = try makeTree()
        let entry = try id(tree, "/scan/tree/Downloads/b.zip")

        XCTAssertEqual(tree.entry(for: entry)?.name, "b.zip")
        XCTAssertEqual(tree.path(of: entry), "/scan/tree/Downloads/b.zip")
        XCTAssertEqual(tree.path(of: LiveTree.rootID), "/scan/tree")
        XCTAssertNil(tree.id(atPath: "/scan/tree/Downloads/missing"))
        XCTAssertNil(tree.id(atPath: "/elsewhere/a.bin"), "a path outside the root is not in the tree")
        XCTAssertNil(tree.id(atPath: "/scan/treehouse/a.bin"), "a sibling is not inside the root")
    }

    func testTheRootKeepsTheSpellingTheScanGaveIt() {
        // `/tmp` is a link to `/private/tmp`; resolving it would make every path
        // in the tree disagree with the scan's own and with Finder's.
        let tree = LiveTree(
            rootName: "tree",
            rootURL: URL(fileURLWithPath: "/tmp/tree", isDirectory: true)
        )
        XCTAssertEqual(tree.rootPath, "/tmp/tree")
        XCTAssertEqual(tree.path(of: LiveTree.rootID), "/tmp/tree")
    }

    func testALookupNormalizesThePathWithoutResolvingLinks() throws {
        let tree = try makeTree()
        let direct = try id(tree, "/scan/tree/Downloads/a.bin")

        XCTAssertEqual(tree.id(atPath: "/scan/tree/Downloads/../Downloads/./a.bin"), direct)
        XCTAssertEqual(tree.id(atPath: "//scan///tree/Downloads/a.bin"), direct)
    }

    func testAPathReportedThroughTheRootsResolvedSpellingFindsTheTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveTreeSpelling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appendingPathComponent("inside.bin"))

        let childNode = ScanNode(
            id: UUID(), url: root.appendingPathComponent("inside.bin"), name: "inside.bin",
            isDirectory: false, isSymlink: false, category: .documents,
            logicalSize: 1, allocatedSize: 1, fileCount: 1, directoryCount: 0,
            modifiedAt: nil, isAccessible: true, errorMessage: nil, children: []
        )
        let rootNode = ScanNode(
            id: UUID(), url: root, name: root.lastPathComponent,
            isDirectory: true, isSymlink: false, category: .other,
            logicalSize: 1, allocatedSize: 1, fileCount: 1, directoryCount: 1,
            modifiedAt: nil, isAccessible: true, errorMessage: nil, children: [childNode]
        )
        let summary = ScanSummary(
            root: root, totalLogicalSize: 1, totalAllocatedSize: 1,
            fileCount: 1, directoryCount: 1, inaccessibleCount: 0, errorCount: 0,
            permissionDeniedCount: 0, surfacedIssueCount: 0,
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1),
            categoryBreakdown: [.documents: 1], largestFiles: [],
            largestDirectories: [rootNode], rootChildren: []
        )
        let tree = try XCTUnwrap(LiveTree(scanning: summary))

        XCTAssertNotNil(tree.id(atPath: root.appendingPathComponent("inside.bin").path))

        // FSEvents names the real path: `/private/var/…` for a root the scan
        // reached as `/var/…`. The tree must answer for that spelling too.
        let resolvedRoot = LiveTree.canonicalPath(root.path)
        guard resolvedRoot != root.path else {
            throw XCTSkip("this volume spells the temporary folder both ways already")
        }
        XCTAssertNotNil(
            tree.id(atPath: resolvedRoot + "/inside.bin"),
            "a watcher's folder must find the tree's own entries"
        )
    }

    func testATreeIsRefusedWhenItDisagreesWithTheScan() {
        let root = sampleRoot()
        let honest = summary(root)
        let doctored = ScanSummary(
            root: honest.root,
            totalLogicalSize: honest.totalLogicalSize - 1,
            totalAllocatedSize: honest.totalAllocatedSize,
            fileCount: honest.fileCount,
            directoryCount: honest.directoryCount,
            inaccessibleCount: honest.inaccessibleCount,
            errorCount: honest.errorCount,
            permissionDeniedCount: honest.permissionDeniedCount,
            surfacedIssueCount: honest.surfacedIssueCount,
            startedAt: honest.startedAt,
            finishedAt: honest.finishedAt,
            categoryBreakdown: honest.categoryBreakdown,
            largestFiles: [],
            largestDirectories: [root],
            rootChildren: []
        )
        XCTAssertNil(LiveTree(scanning: doctored))
    }

    // MARK: - Editing

    func testInsertingAFileAddsItsBytesEverywhere() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")
        let before = tree.revision

        let report = tree.apply([
            .insert(parent: downloads, node: file("c.mov", 2_000, category: .video)),
        ])

        XCTAssertTrue(report.changed)
        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.ignored, 0)
        XCTAssertEqual(tree.revision, before + 1)
        XCTAssertEqual(tree.totalLogicalSize, 7_500)
        XCTAssertEqual(tree.fileCount, 4)
        XCTAssertEqual(tree.directoryCount, 3)
        XCTAssertEqual(tree.categorySizes()[.video], 2_000)
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: downloads)).logicalSize, 7_000)
        XCTAssertEqual(tree.children(of: downloads).count, 3)
    }

    func testUpdatingAFileMovesOnlyTheDifference() throws {
        let tree = try makeTree()
        let a = try id(tree, "/scan/tree/Downloads/a.bin")

        let report = tree.apply([
            .updateFile(id: a, logicalSize: 1_500, allocatedSize: 1_400, modifiedAt: nil, category: .documents),
        ])
        XCTAssertTrue(report.changed)
        XCTAssertEqual(tree.totalLogicalSize, 6_000)
        XCTAssertEqual(tree.totalAllocatedSize, 5_900)
        XCTAssertEqual(tree.categorySizes()[.documents], 2_000)

        tree.apply([
            .updateFile(id: a, logicalSize: 1_500, allocatedSize: 1_400, modifiedAt: nil, category: .code),
        ])
        XCTAssertEqual(tree.categorySizes()[.documents], 500)
        XCTAssertEqual(tree.categorySizes()[.code], 1_500)

        let revision = tree.revision
        let repeated = tree.apply([
            .updateFile(id: a, logicalSize: 1_500, allocatedSize: 1_400, modifiedAt: nil, category: .code),
        ])
        XCTAssertFalse(repeated.changed)
        XCTAssertEqual(tree.revision, revision, "a batch that changes nothing does not invalidate a screen")
    }

    func testInsertingAnExistingNameReplacesWhatWasThere() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")

        tree.apply([.insert(parent: downloads, node: file("a.bin", 2_000))])

        XCTAssertEqual(tree.totalLogicalSize, 6_500)
        XCTAssertEqual(tree.fileCount, 3, "the replaced entry is not counted twice")
        XCTAssertEqual(tree.children(of: downloads).count, 2)
    }

    func testRemovingAFolderTakesItsSubtreeWithIt() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")

        let report = tree.apply([.remove(id: downloads)])

        XCTAssertTrue(report.changed)
        XCTAssertNil(tree.entry(for: downloads), "a removed entry's id never names anything again")
        XCTAssertNil(tree.child(named: "Downloads", of: LiveTree.rootID))
        XCTAssertEqual(tree.totalLogicalSize, 500)
        XCTAssertEqual(tree.totalAllocatedSize, 500)
        XCTAssertEqual(tree.fileCount, 1)
        XCTAssertEqual(tree.directoryCount, 2, "the root and the empty folder")
        XCTAssertEqual(tree.nodeCount, 3)
        XCTAssertEqual(tree.categorySizes(), [.documents: 500])
    }

    func testTheRootCannotBeRemoved() throws {
        let tree = try makeTree()
        let report = tree.apply([.remove(id: LiveTree.rootID)])

        XCTAssertFalse(report.changed)
        XCTAssertEqual(report.ignored, 1)
        XCTAssertNotNil(tree.entry(for: LiveTree.rootID))
    }

    func testARenameKeepsIdentityAndSubtree() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")
        let before = try XCTUnwrap(tree.entry(for: downloads))

        let report = tree.apply([.move(id: downloads, toParent: LiveTree.rootID, name: "Archive")])

        XCTAssertTrue(report.changed)
        XCTAssertEqual(tree.path(of: downloads), "/scan/tree/Archive")
        let after = try XCTUnwrap(tree.entry(for: downloads))
        XCTAssertEqual(after.name, "Archive")
        XCTAssertEqual(after.logicalSize, before.logicalSize)
        XCTAssertEqual(tree.children(of: downloads).count, 2, "the subtree travelled with it")
        XCTAssertEqual(tree.totalLogicalSize, 5_500)
        XCTAssertEqual(tree.fileCount, 3)
    }

    func testMovingAFolderBetweenParentsMovesItsBytes() throws {
        let tree = try makeTree()
        let a = try id(tree, "/scan/tree/Downloads/a.bin")
        let downloads = try id(tree, "/scan/tree/Downloads")
        let empty = try id(tree, "/scan/tree/empty")

        tree.apply([.move(id: a, toParent: empty, name: "a.bin")])

        XCTAssertEqual(tree.path(of: a), "/scan/tree/empty/a.bin")
        XCTAssertEqual(tree.totalLogicalSize, 5_500, "a move changes no total")
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: downloads)).logicalSize, 4_000)
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: downloads)).fileCount, 1)
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: empty)).logicalSize, 1_000)
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: empty)).fileCount, 1)
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: empty)).directoryCount, 1)
    }

    // MARK: - Folder coverage

    func testUnreadableFoldersAreCountedPerSubtree() throws {
        let tree = try makeCoverageTree()

        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 2)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Private"), 1)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Mixed"), 1)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Mixed/Denied"), 1)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Mixed/Fine"), 0)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/notes.txt"), 0)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Open"), 0)
    }

    func testTouchingAFolderMovesItsUnreadableCount() throws {
        let tree = try makeCoverageTree()
        let open = try id(tree, "/scan/tree/Open")
        let notes = try id(tree, "/scan/tree/notes.txt")

        tree.apply([.touch(id: open, modifiedAt: nil, isAccessible: false, errorMessage: "Permission denied")])
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 3)
        XCTAssertEqual(tree.unreadableFolderCount(for: open), 1)

        // A file is not a folder, even when its metadata says it was denied.
        tree.apply([.touch(id: notes, modifiedAt: nil, isAccessible: false, errorMessage: "Permission denied")])
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 3)
        XCTAssertEqual(tree.unreadableFolderCount(for: notes), 0)

        tree.apply([.touch(id: open, modifiedAt: nil, isAccessible: true, errorMessage: nil)])
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 2)
        XCTAssertEqual(tree.unreadableFolderCount(for: open), 0)
    }

    func testGroupEditsKeepUnreadableCounts() throws {
        let tree = try makeCoverageTree()
        let new = folder("New", [folder("Inner", [], accessible: false)], accessible: false)

        tree.apply([.insertNew(parent: LiveTree.rootID, node: new)])
        let newID = try id(tree, "/scan/tree/New")
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 4)
        XCTAssertEqual(tree.unreadableFolderCount(for: newID), 2)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/New/Inner"), 1)

        let fine = try id(tree, "/scan/tree/Mixed/Fine")
        let privateFolder = try id(tree, "/scan/tree/Private")
        tree.apply([.move(id: privateFolder, toParent: fine, name: "Private")])
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 4)
        XCTAssertEqual(tree.unreadableFolderCount(for: fine), 1)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Mixed/Fine/Private"), 1)

        tree.apply([.remove(id: newID)])
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 2)

        let mixed = try id(tree, "/scan/tree/Mixed")
        tree.apply([.remove(id: mixed)])
        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 0)
        XCTAssertNil(tree.unreadableFolderCount(atPath: "/scan/tree/Mixed/Fine/Private"))
    }

    func testReplacingAFolderReconcilesItsUnreadableCount() throws {
        let tree = try makeCoverageTree()

        tree.apply([.insert(parent: LiveTree.rootID, node: folder("Private", []))])

        XCTAssertEqual(tree.unreadableFolderCount(for: LiveTree.rootID), 1)
        XCTAssertEqual(tree.unreadableFolderCount(atPath: "/scan/tree/Private"), 0)
    }

    func testAFolderCannotMoveInsideItself() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")

        let report = tree.apply([.move(id: downloads, toParent: downloads, name: "Archive")])

        XCTAssertFalse(report.changed)
        XCTAssertEqual(report.ignored, 1)
        XCTAssertEqual(tree.path(of: downloads), "/scan/tree/Downloads")
    }

    func testANewEntryCanBeInsertedWithoutLookingForItsName() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")

        tree.apply([.insertNew(parent: downloads, node: file("new.bin", 300, category: .code))])

        XCTAssertEqual(tree.totalLogicalSize, 5_800)
        XCTAssertEqual(tree.fileCount, 4)
        XCTAssertEqual(tree.directoryCount, 3)
        XCTAssertEqual(tree.categorySizes()[.code], 300)
        let newID = try XCTUnwrap(tree.child(named: "new.bin", of: downloads))
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: newID)).logicalSize, 300)
    }

    func testARemovedIdDoesNotComeBackWhenItsSlotIsReused() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")
        let a = try id(tree, "/scan/tree/Downloads/a.bin")
        let removedRowID = try XCTUnwrap(tree.scanNode(for: a)).id

        tree.apply([.remove(id: a)])
        tree.apply([.insertNew(parent: downloads, node: file("replacement.bin", 10))])

        let replacement = try XCTUnwrap(tree.child(named: "replacement.bin", of: downloads))
        XCTAssertNil(tree.entry(for: a), "the slot's new entry has a new identity")
        XCTAssertEqual(replacement.index, a.index, "the arena reuses the slot")
        let replacementRow = try XCTUnwrap(tree.scanNode(for: replacement))
        XCTAssertNotEqual(replacementRow.id, removedRowID, "a reused slot is a different row")
        XCTAssertEqual(tree.nodeCount, 6)
    }

    func testABatchIsOneRevisionAndOneLock() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")
        let empty = try id(tree, "/scan/tree/empty")
        let before = tree.revision

        let report = tree.apply([
            .insert(parent: downloads, node: file("one.bin", 100)),
            .insert(parent: empty, node: file("two.bin", 200)),
            .touch(id: downloads, modifiedAt: Date(timeIntervalSince1970: 1_000), isAccessible: true, errorMessage: nil),
            .insert(parent: empty, node: file("three.bin", 300)),
        ])

        XCTAssertEqual(report.applied, 4)
        XCTAssertEqual(tree.revision, before + 1, "a batch invalidates a screen once")
        XCTAssertEqual(tree.totalLogicalSize, 6_100)
        XCTAssertEqual(try XCTUnwrap(tree.entry(for: downloads)).modifiedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testAnEditThatNamesAMissingParentIsReportedNotCrash() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")
        let gone = try id(tree, "/scan/tree/empty")

        // The folder and an entry inside it arrive in one batch, children first.
        let report = tree.apply([
            .insert(parent: gone, node: file("inside.bin", 10)),
            .remove(id: gone),
        ])

        XCTAssertEqual(report.ignored, 0, "the child was inserted while its parent existed")
        XCTAssertNil(tree.entry(for: gone))
    }

    // MARK: - Materialization

    func testMaterializedNodesKeepTheSameIdentity() throws {
        let tree = try makeTree()

        let first = try XCTUnwrap(tree.scanNode(for: LiveTree.rootID, depth: 1))
        let second = try XCTUnwrap(tree.scanNode(for: LiveTree.rootID, depth: 1))

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.children.map(\.id), second.children.map(\.id))
        XCTAssertEqual(first.logicalSize, 5_500)
        XCTAssertEqual(first.name, "tree")
        XCTAssertEqual(first.children.first?.name, "Downloads", "materialized children are largest first")
        XCTAssertTrue(first.children.first?.children.isEmpty ?? false, "depth bounds what is materialized")

        let deep = try XCTUnwrap(tree.scanNode(for: LiveTree.rootID, depth: 2))
        XCTAssertEqual(deep.children.first?.children.count, 2)

        let downloads = try id(tree, "/scan/tree/Downloads")
        XCTAssertEqual(tree.scanNode(for: downloads)?.url.path, "/scan/tree/Downloads")
    }

    // MARK: - Concurrency

    func testReadsStayConsistentWhileBatchesAreApplied() throws {
        let tree = try makeTree()
        let downloads = try id(tree, "/scan/tree/Downloads")

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for step in 0..<50 {
                if worker == 0 {
                    tree.apply([.insert(parent: downloads, node: file("worker-\(step).bin", 10))])
                } else {
                    _ = tree.totalLogicalSize
                    _ = tree.children(of: LiveTree.rootID)
                    _ = tree.id(atPath: "/scan/tree/Downloads")
                    _ = tree.scanNode(for: LiveTree.rootID, depth: 1)
                }
            }
        }

        XCTAssertEqual(tree.fileCount, 3 + 50)
        XCTAssertEqual(tree.totalLogicalSize, 5_500 + 500)
        XCTAssertEqual(tree.children(of: downloads).count, 2 + 50)
    }
}
