import XCTest
import Foundation
@testable import DiskUI

/// Independent verification of how a location is named for display.
///
/// The name is what the toolbar, the explorer header and the chart's centre label
/// all show, so a location that has no path component of its own — a mount point —
/// must still read as a place rather than as a slash.
final class LocationNameQATests: XCTestCase {

    func testFolderIsNamedByItsLastComponent() {
        XCTAssertEqual(LocationName.of(URL(fileURLWithPath: "/Users/someone/Documents")), "Documents")
        XCTAssertEqual(LocationName.of(URL(fileURLWithPath: "/Volumes/Backup")), "Backup")
    }

    func testTheStartupDiskIsNamedForItsVolumeRatherThanItsPath() {
        let root = URL(fileURLWithPath: "/")
        let name = LocationName.of(root)

        XCTAssertFalse(name.isEmpty)
        XCTAssertNotEqual(name, "/", "the startup disk must not render as a bare slash")

        // The volume's own name, when the system reports one, is exactly what the
        // name must be; a volume with no name falls back to the path.
        let values = try? root.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
        if let reported = values?.volumeLocalizedName ?? values?.volumeName, !reported.isEmpty {
            XCTAssertEqual(name, reported)
        } else {
            XCTAssertEqual(name, "/")
        }
    }

    func testATrailingSlashDoesNotChangeTheName() {
        XCTAssertEqual(LocationName.of(URL(fileURLWithPath: "/Users/someone/Downloads/")),
                       LocationName.of(URL(fileURLWithPath: "/Users/someone/Downloads")))
    }
}
