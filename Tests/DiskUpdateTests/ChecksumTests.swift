import XCTest
@testable import DiskUpdate

/// The checksum is the only integrity gate between a download and the installed
/// app, so its parsing, naming, and streaming hash are pinned here.
final class ChecksumTests: XCTestCase {
    private let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskUpdateChecksumTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Digest value

    func testDigestValidatesAndNormalizes() {
        XCTAssertEqual(SHA256Digest(abcHash)?.hex, abcHash)
        XCTAssertEqual(SHA256Digest(abcHash.uppercased())?.hex, abcHash)
        XCTAssertEqual(SHA256Digest("  \(abcHash)\n")?.hex, abcHash)
        XCTAssertNil(SHA256Digest(String(abcHash.dropLast())))
        XCTAssertNil(SHA256Digest(abcHash + "0"))
        XCTAssertNil(SHA256Digest(String(repeating: "g", count: 64)))
        XCTAssertNil(SHA256Digest(""))
    }

    // MARK: - Parsing

    func testParsesShasumOutput() throws {
        let digest = try ChecksumFile.parse(
            "\(abcHash)  WillyDisk-1.0.1-arm64.zip\n",
            expecting: "WillyDisk-1.0.1-arm64.zip"
        )
        XCTAssertEqual(digest.hex, abcHash)
    }

    func testParsesBlankLinesAndTheBinaryMarker() throws {
        let digest = try ChecksumFile.parse(
            "\n\n\(abcHash) *WillyDisk-1.0.1-arm64.zip\n",
            expecting: "WillyDisk-1.0.1-arm64.zip"
        )
        XCTAssertEqual(digest.hex, abcHash)
    }

    func testRejectsAnEmptyOrBareChecksumFile() {
        assertMalformed("")
        assertMalformed("\n\n")
        assertMalformed(abcHash)
    }

    func testRejectsAChecksumForAnotherFile() {
        let expected = "WillyDisk-1.0.1-arm64.zip"
        XCTAssertThrowsError(
            try ChecksumFile.parse(
                "\(abcHash)  WillyDisk-1.0.1-x86_64.zip\n",
                expecting: expected
            )
        ) { error in
            guard let updateError = error as? UpdateError,
                  case let .checksumNameMismatch(expectation, found) = updateError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(expectation, expected)
            XCTAssertEqual(found, "WillyDisk-1.0.1-x86_64.zip")
        }
    }

    func testRejectsExtraFields() {
        assertMalformed("\(abcHash)  WillyDisk-1.0.1-arm64.zip extra\n")
    }

    func testRejectsMultipleEntries() {
        assertMalformed(
            "\(abcHash)  WillyDisk-1.0.1-arm64.zip\n"
                + "\(emptyHash)  WillyDisk-1.0.1-x86_64.zip\n"
        )
    }

    // MARK: - Hashing

    func testHashesAKnownFile() throws {
        let file = try write("abc", name: "abc.txt")
        XCTAssertEqual(try ChecksumFile.digestOfFile(at: file).hex, abcHash)
    }

    func testHashesAnEmptyFile() throws {
        let file = try write("", name: "empty.txt")
        XCTAssertEqual(try ChecksumFile.digestOfFile(at: file).hex, emptyHash)
    }

    func testMissingArchiveIsNamed() {
        XCTAssertThrowsError(
            try ChecksumFile.digestOfFile(
                at: directory.appendingPathComponent("missing.zip")
            )
        ) { error in
            XCTAssertEqual(error as? UpdateError, .archiveMissing)
        }
    }

    // MARK: - Verification

    func testVerifyMatchesThePublishedChecksum() throws {
        let archive = try write("hello world", name: "WillyDisk-1.0.1-arm64.zip")
        let digest = try ChecksumFile.digestOfFile(at: archive)
        let checksum = try write(
            "\(digest.hex)  WillyDisk-1.0.1-arm64.zip\n",
            name: "WillyDisk-1.0.1-arm64.zip.sha256"
        )

        let verified = try verifier().verify(archive: archive, checksumFile: checksum)
        XCTAssertEqual(verified, digest)
    }

    func testVerifyRejectsAMismatchWithoutTouchingTheArchive() throws {
        let archive = try write("hello world", name: "WillyDisk-1.0.1-arm64.zip")
        let checksum = try write(
            "\(abcHash)  WillyDisk-1.0.1-arm64.zip\n",
            name: "WillyDisk-1.0.1-arm64.zip.sha256"
        )
        let archiveHash = try ChecksumFile.digestOfFile(at: archive).hex

        XCTAssertThrowsError(try verifier().verify(archive: archive, checksumFile: checksum)) { error in
            guard let updateError = error as? UpdateError,
                  case let .checksumMismatch(expected, actual) = updateError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(expected, abcHash)
            XCTAssertEqual(actual, archiveHash)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testVerifyRejectsTheWrongArchiveName() throws {
        let archive = try write("hello world", name: "WillyDisk-1.0.1-arm64.zip")
        let checksum = try write("", name: "WillyDisk-1.0.1-arm64.zip.sha256")

        XCTAssertThrowsError(
            try verifier().verify(
                archive: archive,
                checksumFile: checksum,
                expectedArchiveName: "WillyDisk-1.0.1-x86_64.zip"
            )
        ) { error in
            guard let updateError = error as? UpdateError,
                  case .archiveNameMismatch = updateError else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testVerifyRejectsAMissingChecksumFile() throws {
        let archive = try write("hello world", name: "WillyDisk-1.0.1-arm64.zip")
        XCTAssertThrowsError(
            try verifier().verify(
                archive: archive,
                checksumFile: directory.appendingPathComponent("missing.sha256")
            )
        ) { error in
            XCTAssertEqual(error as? UpdateError, .checksumUnreadable)
        }
    }

    func testVerifyAcceptsTheExpectedByteCount() throws {
        let contents = "hello world"
        let archive = try write(contents, name: "WillyDisk-1.0.1-arm64.zip")
        let digest = try ChecksumFile.digestOfFile(at: archive)
        let checksum = try write(
            "\(digest.hex)  WillyDisk-1.0.1-arm64.zip\n",
            name: "WillyDisk-1.0.1-arm64.zip.sha256"
        )

        XCTAssertNoThrow(
            try verifier().verify(
                archive: archive,
                checksumFile: checksum,
                expectedByteCount: contents.utf8.count
            )
        )
    }

    func testVerifyRejectsAWrongByteCountBeforeHashing() throws {
        let archive = try write("hello world", name: "WillyDisk-1.0.1-arm64.zip")
        let digest = try ChecksumFile.digestOfFile(at: archive)
        let checksum = try write(
            "\(digest.hex)  WillyDisk-1.0.1-arm64.zip\n",
            name: "WillyDisk-1.0.1-arm64.zip.sha256"
        )

        XCTAssertThrowsError(
            try verifier().verify(
                archive: archive,
                checksumFile: checksum,
                expectedByteCount: 10
            )
        ) { error in
            guard let updateError = error as? UpdateError,
                  case let .sizeMismatch(expected, actual) = updateError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(expected, 10)
            XCTAssertEqual(actual, 11)
        }
    }

    func testVerifyRejectsAnOversizedChecksumFile() throws {
        let archive = try write("hello world", name: "WillyDisk-1.0.1-arm64.zip")
        let checksum = directory.appendingPathComponent("WillyDisk-1.0.1-arm64.zip.sha256")
        try Data(repeating: 0x41, count: ChecksumFile.maximumSize + 1).write(to: checksum)

        XCTAssertThrowsError(try verifier().verify(archive: archive, checksumFile: checksum)) { error in
            XCTAssertEqual(error as? UpdateError, .checksumMalformed)
        }
    }

    // MARK: - Fixtures

    private func verifier() -> UpdateVerifier {
        UpdateVerifier(
            expectedBundleIdentifier: "com.willydisk.app",
            expectedMarketingVersion: "1.0.1",
            architecture: .current,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 0,
                patchVersion: 0
            )
        )
    }

    private func write(_ text: String, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func assertMalformed(_ text: String) {
        XCTAssertThrowsError(
            try ChecksumFile.parse(text, expecting: "WillyDisk-1.0.1-arm64.zip")
        ) { error in
            XCTAssertEqual(error as? UpdateError, .checksumMalformed)
        }
    }
}
