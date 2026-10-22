import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// Verifies that a search result's folder resolves to a chain of nodes the
/// explorer can re-root on, and that a folder the tree does not hold resolves to
/// nothing rather than to a wrong place.
final class ExplorerPathQATests: XCTestCase {

    func testChainNamesEveryFolderFromTheRootDown() throws {
        let root = directory("/scan", children: [
            directory("/scan/A", children: [
                directory("/scan/A/B", children: [
                    directory("/scan/A/B/C", children: []),
                ]),
            ]),
        ])

        let chain = try XCTUnwrap(
            ExplorerPath.chain(to: URL(fileURLWithPath: "/scan/A/B/C", isDirectory: true),
                               from: root)
        )

        XCTAssertEqual(chain.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(chain.last?.url.path, "/scan/A/B/C")
    }

    func testTheScannedRootItselfIsAnEmptyChain() throws {
        let root = directory("/scan", children: [])

        let chain = try XCTUnwrap(
            ExplorerPath.chain(to: URL(fileURLWithPath: "/scan", isDirectory: true), from: root)
        )

        XCTAssertTrue(chain.isEmpty)
    }

    func testAFolderOutsideTheTreeResolvesToNothing() {
        let root = directory("/Users/me", children: [])

        XCTAssertNil(ExplorerPath.chain(
            to: URL(fileURLWithPath: "/Users/me2/Projects", isDirectory: true),
            from: root
        ))
    }

    func testAFolderTheTreeDoesNotHoldResolvesToNothing() {
        let root = directory("/scan", children: [
            directory("/scan/A", children: []),
        ])

        XCTAssertNil(ExplorerPath.chain(
            to: URL(fileURLWithPath: "/scan/A/Missing", isDirectory: true),
            from: root
        ))
    }

    func testTheChainWorksWhenTheRootIsAWholeDisk() throws {
        let root = directory("/", children: [
            directory("/Users", children: [
                directory("/Users/wael", children: [
                    directory("/Users/wael/Documents", children: []),
                ]),
            ]),
        ])

        let chain = try XCTUnwrap(
            ExplorerPath.chain(
                to: URL(fileURLWithPath: "/Users/wael/Documents", isDirectory: true),
                from: root
            )
        )

        XCTAssertEqual(chain.map(\.name), ["Users", "wael", "Documents"])
    }

    // MARK: - Fixtures

    private func directory(_ path: String, children: [ScanNode]) -> ScanNode {
        ScanNode(
            id: UUID(),
            url: URL(fileURLWithPath: path, isDirectory: true),
            name: (path as NSString).lastPathComponent.isEmpty
                ? path
                : (path as NSString).lastPathComponent,
            isDirectory: true,
            isSymlink: false,
            category: .other,
            logicalSize: 0,
            allocatedSize: 0,
            fileCount: 0,
            directoryCount: children.count,
            modifiedAt: nil,
            isAccessible: true,
            errorMessage: nil,
            children: children
        )
    }
}
