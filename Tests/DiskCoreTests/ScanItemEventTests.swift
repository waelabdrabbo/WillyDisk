import XCTest
import CoreServices
@testable import DiskCore

/// One FSEvents item event reduced to what it can do to a scan: which events can
/// move a number the scan reported, and which folder each one changes.
final class ScanItemEventTests: XCTestCase {

    private func flags(_ bits: [Int]) -> FSEventStreamEventFlags {
        bits.reduce(into: FSEventStreamEventFlags(0)) { $0 |= FSEventStreamEventFlags($1) }
    }

    // MARK: - What counts as a change

    func testMetadataOnlyEventsCannotChangeMeasuredContents() {
        // Attribute, owner, extended-attribute, and clone metadata change
        // nothing a scan counts or sums.
        XCTAssertFalse(ScanItemEvent.changesMeasuredContents(flags([
            kFSEventStreamEventFlagItemInodeMetaMod,
            kFSEventStreamEventFlagItemIsFile,
        ])))
        XCTAssertFalse(ScanItemEvent.changesMeasuredContents(flags([
            kFSEventStreamEventFlagItemXattrMod,
            kFSEventStreamEventFlagItemIsFile,
        ])))
        XCTAssertFalse(ScanItemEvent.changesMeasuredContents(flags([
            kFSEventStreamEventFlagItemChangeOwner,
            kFSEventStreamEventFlagItemFinderInfoMod,
            kFSEventStreamEventFlagItemIsDir,
        ])))
        XCTAssertFalse(ScanItemEvent.changesMeasuredContents(flags([
            kFSEventStreamEventFlagItemCloned,
            kFSEventStreamEventFlagItemIsFile,
        ])))
        XCTAssertFalse(ScanItemEvent.changesMeasuredContents(0))
    }

    func testCreationRemovalRenameAndWriteAreChanges() {
        for bit in [
            kFSEventStreamEventFlagItemCreated,
            kFSEventStreamEventFlagItemRemoved,
            kFSEventStreamEventFlagItemRenamed,
            kFSEventStreamEventFlagItemModified,
        ] {
            XCTAssertTrue(
                ScanItemEvent.changesMeasuredContents(flags([bit, kFSEventStreamEventFlagItemIsFile])),
                "0x\(String(bit, radix: 16)) names a change a scan measures"
            )
        }
    }

    // MARK: - Which folder changed

    func testAFileEventChangesTheFolderThatHoldsIt() {
        XCTAssertEqual(
            ScanItemEvent.folderPath(
                for: "/scan/tree/downloads/file.bin",
                flags: flags([kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile])
            ),
            "/scan/tree/downloads"
        )
        XCTAssertEqual(
            ScanItemEvent.folderPath(
                for: "/scan/tree/file.bin",
                flags: flags([kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile])
            ),
            "/scan/tree"
        )
    }

    func testADirectoryWhoseOwnEntriesChangedNamesItself() {
        XCTAssertEqual(
            ScanItemEvent.folderPath(
                for: "/scan/tree/downloads",
                flags: flags([kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsDir])
            ),
            "/scan/tree/downloads"
        )
    }

    func testADirectoryArrivingOrLeavingChangesTheFolderThatHoldsIt() {
        for bit in [
            kFSEventStreamEventFlagItemCreated,
            kFSEventStreamEventFlagItemRemoved,
            kFSEventStreamEventFlagItemRenamed,
        ] {
            XCTAssertEqual(
                ScanItemEvent.folderPath(
                    for: "/scan/tree/downloads",
                    flags: flags([bit, kFSEventStreamEventFlagItemIsDir])
                ),
                "/scan/tree",
                "0x\(String(bit, radix: 16)) changes the entries of the folder that holds the directory"
            )
        }
    }

    func testTheRootIsItsOwnFolder() {
        XCTAssertEqual(
            ScanItemEvent.folderPath(
                for: "/",
                flags: flags([kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsDir])
            ),
            "/"
        )
        XCTAssertEqual(
            ScanItemEvent.folderPath(
                for: "/file.bin",
                flags: flags([kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile])
            ),
            "/"
        )
    }
}
