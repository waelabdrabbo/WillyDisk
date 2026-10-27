import XCTest
import Foundation
@testable import DiskCore
@testable import DiskUI

/// The Categories mode's open category keeps the list it has while it asks the
/// tree for a newer one, and only ever shows the newest walk's answer.
///
/// The tree is the live one: a watched disk changes while a walk over millions of
/// entries runs. A detail that emptied its list on every change would spend its
/// life on the reading state instead of the files it already found.
final class CategoryDetailQATests: XCTestCase {

    private let start = ContinuousClock().now
    private var later: ContinuousClock.Instant { start.advanced(by: .seconds(10)) }

    func testOpeningACategoryWaitsForItsFirstWalk() throws {
        var detail = CategoryDetail()
        let walk = detail.open(.video, at: start)

        XCTAssertEqual(detail.category, .video)
        XCTAssertTrue(detail.isOpen)
        XCTAssertNil(detail.files, "a newly opened category has nothing to show yet")
        XCTAssertTrue(detail.isLoading)
        XCTAssertEqual(detail.pendingWalk, walk)

        XCTAssertTrue(detail.accept(files(.video, ["a.mov"]), from: walk))
        XCTAssertEqual(detail.files?.files.map(\.name), ["a.mov"])
        XCTAssertFalse(detail.isLoading)
        XCTAssertNil(detail.pendingWalk)
    }

    func testARefreshKeepsTheFilesOnScreenUntilItLands() throws {
        var detail = CategoryDetail()
        let first = detail.open(.video, at: start)
        XCTAssertTrue(detail.accept(files(.video, ["old.mov"]), from: first))

        let second = try XCTUnwrap(startWalk(detail.refresh(at: later, interval: .seconds(3))))
        XCTAssertEqual(detail.files?.files.map(\.name), ["old.mov"],
                       "the list keeps what it has while the next walk runs")
        XCTAssertTrue(detail.isLoading)

        XCTAssertTrue(detail.accept(files(.video, ["new.mov"]), from: second))
        XCTAssertEqual(detail.files?.files.map(\.name), ["new.mov"])
    }

    func testTheFilesSurviveAWalkThatEndsWithoutAnAnswer() throws {
        var detail = CategoryDetail()
        let first = detail.open(.video, at: start)
        XCTAssertTrue(detail.accept(files(.video, ["kept.mov"]), from: first))

        let second = try XCTUnwrap(startWalk(detail.refresh(at: later, interval: .seconds(3))))
        detail.end(second)

        XCTAssertFalse(detail.isLoading)
        XCTAssertEqual(detail.files?.files.map(\.name), ["kept.mov"])
    }

    func testAReplacedWalkCannotPublish() throws {
        var detail = CategoryDetail()
        let first = detail.open(.video, at: start)
        // One click later the screen is inside a different category.
        let second = detail.open(.images, at: later)

        XCTAssertFalse(detail.accept(files(.video, ["stale.mov"]), from: first))
        XCTAssertNil(detail.files)
        XCTAssertEqual(detail.pendingWalk, second)

        XCTAssertTrue(detail.accept(files(.images, ["fresh.png"]), from: second))
        XCTAssertEqual(detail.files?.files.map(\.name), ["fresh.png"])
    }

    func testAClosedCategoryTakesNoAnswer() throws {
        var detail = CategoryDetail()
        let walk = detail.open(.video, at: start)
        detail.close()

        XCTAssertFalse(detail.isOpen)
        XCTAssertNil(detail.category)
        XCTAssertFalse(detail.isLoading)
        XCTAssertNil(detail.pendingWalk)
        XCTAssertFalse(detail.accept(files(.video, ["late.mov"]), from: walk))
        XCTAssertNil(detail.files)
    }

    func testReopeningACategoryAsksForItsFilesAgain() throws {
        var detail = CategoryDetail()
        let first = detail.open(.video, at: start)
        XCTAssertTrue(detail.accept(files(.video, ["before.mov"]), from: first))
        detail.close()

        let again = detail.open(.video, at: later)

        XCTAssertNil(detail.files, "the list starts over for the category it reopened")
        XCTAssertFalse(detail.accept(files(.video, ["before.mov"]), from: first))
        XCTAssertTrue(detail.accept(files(.video, ["after.mov"]), from: again))
        XCTAssertEqual(detail.files?.files.map(\.name), ["after.mov"])
    }

    func testARefreshWaitsOutTheInterval() throws {
        var detail = CategoryDetail()
        let walk = detail.open(.video, at: start)
        XCTAssertTrue(detail.accept(files(.video, ["a.mov"]), from: walk))

        let soon = start.advanced(by: .seconds(1))
        guard case .wait(let ready) = detail.refresh(at: soon, interval: .seconds(3)) else {
            return XCTFail("a walk started a second ago must not start another")
        }
        XCTAssertEqual(ready, start.advanced(by: .seconds(3)))
        XCTAssertFalse(detail.isLoading, "waiting is not walking")

        XCTAssertNotNil(startWalk(detail.refresh(at: ready, interval: .seconds(3))))
    }

    func testARefreshNeverReplacesAWalkThatIsStillOut() throws {
        var detail = CategoryDetail()
        _ = detail.open(.video, at: start)

        XCTAssertEqual(detail.refresh(at: later, interval: .seconds(3)), .busy,
                       "the walk that is out is already the newest answer")
        XCTAssertEqual(detail.files, nil)
        XCTAssertEqual(detail.category, .video)

        // With nothing open there is nothing to walk for.
        detail.close()
        XCTAssertEqual(detail.refresh(at: later, interval: .seconds(3)), .idle)
    }

    // MARK: - Fixtures

    private func startWalk(_ refresh: CategoryDetail.Refresh) -> CategoryDetail.Walk? {
        guard case .start(let walk) = refresh else { return nil }
        return walk
    }

    private func files(_ category: FileCategory, _ names: [String]) -> CategoryFiles {
        let nodes = names.enumerated().map { index, name in
            ScanNode(
                id: UUID(),
                url: URL(fileURLWithPath: "/scan/\(name)"),
                name: name,
                isDirectory: false,
                isSymlink: false,
                category: category,
                logicalSize: Int64(names.count - index),
                allocatedSize: Int64(names.count - index),
                fileCount: 1,
                directoryCount: 0,
                modifiedAt: nil,
                isAccessible: true,
                errorMessage: nil,
                children: []
            )
        }
        return CategoryFiles(
            category: category,
            files: nodes,
            matchCount: nodes.count,
            totalLogicalSize: nodes.reduce(0) { $0 + $1.logicalSize },
            visitedCount: nodes.count,
            stoppedAtLimit: false
        )
    }
}
