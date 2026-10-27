import XCTest
@testable import DiskUpdate

/// The comparison the updater rests on: one wrong ordering either hides a release
/// or offers a downgrade. These pin the `VERSION` grammar and numeric ordering.
final class ReleaseVersionTests: XCTestCase {
    func testParsesOneToThreeComponents() {
        XCTAssertEqual(ReleaseVersion("1")?.components, [1, 0, 0])
        XCTAssertEqual(ReleaseVersion("1.2")?.components, [1, 2, 0])
        XCTAssertEqual(ReleaseVersion("1.2.3")?.components, [1, 2, 3])
    }

    func testAcceptsATagPrefixAndWhitespace() {
        XCTAssertEqual(ReleaseVersion("v1.2.3"), ReleaseVersion("1.2.3"))
        XCTAssertEqual(ReleaseVersion("V1.2.3"), ReleaseVersion("1.2.3"))
        XCTAssertEqual(ReleaseVersion("  1.2.3\n"), ReleaseVersion("1.2.3"))
    }

    func testPadsMissingComponentsForEquality() {
        XCTAssertEqual(ReleaseVersion("1.0"), ReleaseVersion("1.0.0"))
        XCTAssertFalse(ReleaseVersion("1.0")! < ReleaseVersion("1.0.0")!)
    }

    func testComparesNumbersNotStrings() {
        XCTAssertLessThan(ReleaseVersion("1.0.9")!, ReleaseVersion("1.0.10")!)
        XCTAssertLessThan(ReleaseVersion("1.9.0")!, ReleaseVersion("1.10.0")!)
        XCTAssertLessThan(ReleaseVersion("1.99.99")!, ReleaseVersion("2.0.0")!)
        XCTAssertGreaterThan(ReleaseVersion("2.0.0")!, ReleaseVersion("1.99.99")!)
    }

    func testSortsTheWayAFeedIsRead() {
        let versions = ["1.0.10", "1.0.2", "1.0.0", "1.0.9"]
            .compactMap(ReleaseVersion.init)
            .sorted()
        XCTAssertEqual(versions.map(\.description), ["1.0.0", "1.0.2", "1.0.9", "1.0.10"])
    }

    func testRejectsMalformedVersions() {
        let invalid = [
            "", "v", "V", "1.", ".1", "1..2", "1.2.3.4",
            "1.2.a", "-1.2.3", "1.2.3-beta", "1,2,3", "1 2 3",
            "999999999999999999999999",
        ]
        for raw in invalid {
            XCTAssertNil(ReleaseVersion(raw), "accepted \(raw.debugDescription)")
        }
    }

    func testDescriptionIsZeroPadded() {
        XCTAssertEqual(ReleaseVersion("1.2")?.description, "1.2.0")
        XCTAssertEqual(ReleaseVersion("v1.2.3")?.description, "1.2.3")
    }
}
