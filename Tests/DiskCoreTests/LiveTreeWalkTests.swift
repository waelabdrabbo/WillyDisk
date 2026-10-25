import XCTest
@testable import DiskCore

/// The two walks a screen uses to ask the whole tree a question: with names for a
/// search, and without them for a ranking.
final class LiveTreeWalkTests: XCTestCase {

    private let rootURL = URL(fileURLWithPath: "/scan/tree", isDirectory: true)

    private func file(_ name: String, _ size: Int64) -> ScanNode {
        ScanNode(
            id: UUID(), url: rootURL.appendingPathComponent(name), name: name,
            isDirectory: false, isSymlink: false, category: .documents,
            logicalSize: size, allocatedSize: size, fileCount: 1, directoryCount: 0,
            modifiedAt: nil, isAccessible: true, errorMessage: nil, children: []
        )
    }

    private func folder(_ name: String, _ children: [ScanNode], url: URL? = nil) -> ScanNode {
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
            modifiedAt: nil, isAccessible: true, errorMessage: nil, children: children
        )
    }

    private func makeTree() throws -> LiveTree {
        let root = folder(
            "tree",
            [
                folder("Documents", [file("a.txt", 100), file("b.txt", 200)]),
                folder("Photos", [folder("2024", [file("c.jpg", 300)])]),
                file("notes.md", 50),
            ],
            url: rootURL
        )
        let categories: [FileCategory: Int64] = [.documents: 650]
        let summary = ScanSummary(
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
        return try XCTUnwrap(LiveTree(scanning: summary))
    }

    // MARK: - Walking with names

    func testAWalkVisitsEveryEntryBelowTheRoot() throws {
        let tree = try makeTree()
        var names: [String] = []
        let visited = tree.walk { entry in
            names.append(entry.name)
            return .descend
        }

        XCTAssertEqual(visited, tree.nodeCount - 1, "the root is the scope, not one of its entries")
        XCTAssertEqual(Set(names), ["Documents", "a.txt", "b.txt", "Photos", "2024", "c.jpg", "notes.md"])
    }

    func testASkipStaysOutOfOneSubtree() throws {
        let tree = try makeTree()
        var names: [String] = []
        tree.walk { entry in
            names.append(entry.name)
            return entry.name == "Photos" ? .skipChildren : .descend
        }

        XCTAssertTrue(names.contains("Photos"))
        XCTAssertFalse(names.contains("2024"), "a skipped folder's contents are not visited")
        XCTAssertFalse(names.contains("c.jpg"))
        XCTAssertTrue(names.contains("a.txt"))
    }

    func testAStopEndsTheWalk() throws {
        let tree = try makeTree()
        var visited = 0
        tree.walk { _ in
            visited += 1
            return visited == 2 ? .stop : .descend
        }
        XCTAssertEqual(visited, 2)
    }

    func testTheRootsEntriesAreNotReported() throws {
        let tree = try makeTree()
        var sawRoot = false
        tree.walk { entry in
            if entry.name == "tree" { sawRoot = true }
            return .descend
        }
        XCTAssertFalse(sawRoot)
    }

    // MARK: - Walking without names

    func testTheFactsWalkSeesTheSameEntriesAndNumbers() throws {
        let tree = try makeTree()
        var files: [String: Int64] = [:]
        var folders = Set<String>()
        var total: Int64 = 0
        var visited = 0

        tree.walkNodes { facts in
            visited += 1
            if facts.kind == .file {
                files[facts.id.description] = facts.logicalSize
                total += facts.logicalSize
            } else {
                folders.insert(facts.id.description)
            }
            return .descend
        }

        XCTAssertEqual(visited, tree.nodeCount - 1)
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(total, tree.totalLogicalSize)
    }

    func testTheFactsMatchTheEntryTheyDescribe() throws {
        let tree = try makeTree()
        var mismatch: String?
        tree.walkNodes { facts in
            guard let entry = tree.entry(for: facts.id) else {
                mismatch = "facts for a missing entry"
                return .stop
            }
            if entry.logicalSize != facts.logicalSize || entry.kind != facts.kind {
                mismatch = "facts disagree with \(entry.name)"
                return .stop
            }
            return .descend
        }
        XCTAssertNil(mismatch)
    }

    // MARK: - While the tree is edited

    func testAWalkSurvivesBatchesAppliedMeanwhile() throws {
        let tree = try makeTree()
        let documents = try XCTUnwrap(tree.id(atPath: "/scan/tree/Documents"))

        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            if worker == 0 {
                for step in 0..<40 {
                    let node = ScanNode(
                        id: UUID(),
                        url: self.rootURL.appendingPathComponent("Documents/worker-\(step).bin"),
                        name: "worker-\(step).bin",
                        isDirectory: false, isSymlink: false, category: .other,
                        logicalSize: 10, allocatedSize: 10, fileCount: 1, directoryCount: 0,
                        modifiedAt: nil, isAccessible: true, errorMessage: nil, children: []
                    )
                    tree.apply([.insert(parent: documents, node: node)])
                }
            } else {
                for _ in 0..<20 {
                    var seen = 0
                    tree.walk { _ in
                        seen += 1
                        return .descend
                    }
                    XCTAssertGreaterThan(seen, 0)
                    tree.walkNodes { _ in .skipChildren }
                }
            }
        }

        XCTAssertEqual(tree.fileCount, 4 + 40)
    }
}
