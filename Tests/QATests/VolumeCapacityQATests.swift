import XCTest
import Foundation
@testable import DiskUI

/// The source screen's capacity warning is a product decision, not a style
/// detail: the ring turns to trouble exactly when the row also says how much
/// room is left. These pin the boundary so the two never disagree.
final class VolumeCapacityQATests: XCTestCase {

    private func volume(total: Int64?, available: Int64?) -> VolumeInfo {
        VolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Test"),
            name: "Test",
            totalCapacity: total,
            availableCapacity: available,
            isInternal: false,
            isReadOnly: false
        )
    }

    func testNineTenthsUsedIsLowOnSpace() {
        XCTAssertTrue(volume(total: 1_000, available: 100).isLowOnSpace)
        XCTAssertTrue(volume(total: 1_000, available: 1).isLowOnSpace)
    }

    func testMoreThanOneTenthFreeIsNotWarned() {
        XCTAssertFalse(volume(total: 1_000, available: 101).isLowOnSpace)
        XCTAssertFalse(volume(total: 1_000, available: 800).isLowOnSpace)
    }

    func testUnknownCapacityIsNotGuessedAt() {
        XCTAssertFalse(volume(total: nil, available: 10).isLowOnSpace)
        XCTAssertFalse(volume(total: 1_000, available: nil).isLowOnSpace)
        XCTAssertFalse(volume(total: 0, available: 0).isLowOnSpace)
    }
}
