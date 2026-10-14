import XCTest
import Foundation
import Darwin
@testable import DiskCore

/// Tests for the bulk directory reader.
///
/// `DirectoryReader` replaces the per-entry `lstat` that dominated a scan with a
/// single `getattrlistbulk(2)` stream per directory. These tests pin the reader
/// against `lstat(2)`, which is the reference for every field the scanner uses:
/// type, device + inode (loop/duplicate detection), logical size, allocated
/// size, and modification time.
final class DirectoryReaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WillyDiskReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entriesByName(_ path: String) throws -> [String: DirectoryEntry] {
        var result: [String: DirectoryEntry] = [:]
        for entry in try DirectoryReader().read(path: path) {
            XCTAssertNil(result[entry.name], "\(entry.name) reported twice")
            result[entry.name] = entry
        }
        return result
    }

    // MARK: - Equivalence with lstat

    /// Every field the scanner consumes must agree with `lstat(2)` for regular
    /// files, directories and symlinks — including the 64-bit inode used for
    /// duplicate-subtree detection.
    func testBulkReadAgreesWithLstatForEveryEntryKind() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0, count: 1).write(to: root.appendingPathComponent("one.txt"))
        try Data(repeating: 0, count: 5_000).write(to: root.appendingPathComponent("big.bin"))
        try Data().write(to: root.appendingPathComponent("empty.dat"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("one.txt")
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let entries = try entriesByName(root.path)
        XCTAssertEqual(Set(entries.keys), Set(names), "the reader returns exactly the directory's children")

        for name in names {
            let entry = try XCTUnwrap(entries[name])
            let reference = FileStat.lstat(root.appendingPathComponent(name).path)

            XCTAssertEqual(entry.stat.error, 0, "\(name): metadata must be read without error")
            XCTAssertEqual(entry.stat.dev, reference.dev, "\(name): device")
            XCTAssertEqual(entry.stat.ino, reference.ino, "\(name): inode")
            XCTAssertEqual(entry.stat.mtimeSec, reference.mtimeSec, "\(name): modification time")
            XCTAssertEqual(entry.stat.mtimeNsec, reference.mtimeNsec, "\(name): modification time (nanoseconds)")

            // The type must match exactly, including symlinks being reported as
            // the link itself rather than its target.
            XCTAssertEqual(entry.stat.isDirectory, reference.isDirectory, "\(name): isDirectory")
            XCTAssertEqual(entry.stat.isSymlink, reference.isSymlink, "\(name): isSymlink")
            XCTAssertEqual(entry.stat.isRegularFile, reference.isRegularFile, "\(name): isRegularFile")

            // A directory's own size is not reported in bulk and is not part of
            // the scan's accounting — a directory's size is the sum of its
            // subtree. Only file data must agree.
            if reference.isRegularFile {
                XCTAssertEqual(entry.stat.size, reference.size, "\(name): logical size")
                XCTAssertEqual(entry.stat.allocatedSize, reference.allocatedSize, "\(name): allocated size")
            }
        }
    }

    func testBulkReadReportsSymlinkAsSymlinkNotTarget() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target-dir")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("to-dir"), withDestinationURL: target
        )

        let entries = try entriesByName(root.path)
        let link = try XCTUnwrap(entries["to-dir"])
        XCTAssertTrue(link.stat.isSymlink, "a symlink is reported as a link, never as its directory target")
        XCTAssertFalse(link.stat.isDirectory)

        // The reported size is the link's own payload (its target string), which
        // the scanner deliberately does not count — a link is a zero-size leaf.
        let reference = FileStat.lstat(root.appendingPathComponent("to-dir").path)
        XCTAssertEqual(link.stat.size, reference.size, "the link's own payload matches lstat")
        XCTAssertNotEqual(link.stat.ino, FileStat.lstat(target.path).ino, "the link and its target are distinct objects")
    }

    // MARK: - Coverage of the whole directory

    /// A directory larger than one bulk buffer must be read completely, and each
    /// child exactly once — the reader loops until the kernel reports no more.
    func testBulkReadReturnsEveryEntryAcrossMultipleBatches() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let count = 1_500
        for i in 0..<count {
            try Data(repeating: 0, count: i % 97)
                .write(to: root.appendingPathComponent(String(format: "file_%05d.txt", i)))
        }

        let entries = try DirectoryReader().read(path: root.path)
        XCTAssertEqual(entries.count, count)
        XCTAssertEqual(Set(entries.map(\.name)).count, count, "no duplicates and no omissions")
        XCTAssertEqual(
            Set(entries.map(\.name)),
            Set((0..<count).map { String(format: "file_%05d.txt", $0) })
        )
    }

    /// Hidden entries are returned; `includeHidden` filtering is the scanner's
    /// decision, not the reader's.
    func testBulkReadIncludesHiddenEntries() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0, count: 3).write(to: root.appendingPathComponent(".hidden"))
        try Data(repeating: 0, count: 3).write(to: root.appendingPathComponent("visible"))

        let entries = try entriesByName(root.path)
        XCTAssertNotNil(entries[".hidden"])
        XCTAssertNotNil(entries["visible"])
        XCTAssertNil(entries["."], "the reader never reports the directory itself")
        XCTAssertNil(entries[".."], "the reader never reports the parent")
    }

    // MARK: - Attribute completeness

    /// The scan must never use a group that is missing a field it reads: an
    /// absent object type or size would misclassify the entry or report a
    /// fabricated zero. Such an entry is re-read directly instead.
    func testAttributesAreCompleteRequiresEveryFieldTheScanReads() {
        let allCommon = UInt32(0x8000_0000 | 0x1 | 0x2 | 0x8 | 0x400 | 0x0200_0000)
        let fileSizes = UInt32(0x4 | 0x200)
        let vreg = UInt32(1), vdir = UInt32(2), vlnk = UInt32(5)

        XCTAssertTrue(DirectoryReader.attributesAreComplete(commonattr: allCommon, fileattr: fileSizes, objectType: vreg))
        XCTAssertTrue(DirectoryReader.attributesAreComplete(commonattr: allCommon, fileattr: fileSizes, objectType: vlnk))
        // A directory has no file attributes of its own, and needs none.
        XCTAssertTrue(DirectoryReader.attributesAreComplete(commonattr: allCommon, fileattr: 0, objectType: vdir))

        // Missing object type: the entry cannot even be classified.
        XCTAssertFalse(DirectoryReader.attributesAreComplete(commonattr: allCommon & ~0x8, fileattr: fileSizes, objectType: 0))
        // Missing device or inode: duplicate-subtree and loop detection break.
        XCTAssertFalse(DirectoryReader.attributesAreComplete(commonattr: allCommon & ~0x2, fileattr: fileSizes, objectType: vreg))
        XCTAssertFalse(DirectoryReader.attributesAreComplete(commonattr: allCommon & ~0x0200_0000, fileattr: fileSizes, objectType: vreg))
        // A regular file without its sizes would be reported as empty.
        XCTAssertFalse(DirectoryReader.attributesAreComplete(commonattr: allCommon, fileattr: 0, objectType: vreg))
        XCTAssertFalse(DirectoryReader.attributesAreComplete(commonattr: allCommon, fileattr: 0x200, objectType: vreg))
        XCTAssertFalse(DirectoryReader.attributesAreComplete(commonattr: allCommon, fileattr: 0x4, objectType: vreg))
    }

    // MARK: - Mount points
    /// A mount point must be identifiable, because the bulk read reports the
    /// *underlying* volume's device for it — the device alone cannot tell a scan
    /// that it is about to leave its volume.
    func testBulkReadFlagsMountPoints() throws {
        let rootEntries = try entriesByName("/")
        let dev = try XCTUnwrap(rootEntries["dev"], "/dev must be listed")
        XCTAssertTrue(dev.stat.isMountPoint, "/dev is a mount point")
        XCTAssertTrue(dev.stat.isDirectory)

        let system = try XCTUnwrap(rootEntries["System"], "/System must be listed")
        XCTAssertFalse(system.stat.isMountPoint, "/System is an ordinary directory")

        // The underlying device is reported for a mount point, so it matches the
        // root volume rather than the mounted volume.
        XCTAssertEqual(dev.stat.dev, system.stat.dev)
    }

    // MARK: - Failure
    func testBulkReadThrowsForUnreadableDirectory() throws {
        let root = try makeTempDir()
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertThrowsError(try DirectoryReader().read(path: locked.path)) { error in
            XCTAssertEqual(ScanErrorClassifier.kind(for: error), .permissionDenied)
        }
    }

    func testBulkReadThrowsForMissingDirectory() {
        XCTAssertThrowsError(try DirectoryReader().read(path: "/definitely/not/here/\(UUID().uuidString)"))
    }
}
