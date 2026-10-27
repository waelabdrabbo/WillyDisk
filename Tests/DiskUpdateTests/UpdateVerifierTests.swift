import XCTest
@testable import DiskUpdate

/// The staged bundle checks. A fake app with a shell executable can prove the
/// identity and minimum-OS rules without building a signed Mach-O; the extraction
/// tests use `ditto` exactly as the updater will.
final class UpdateVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskUpdateVerifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Bundle identity

    func testRejectsAWrongBundleIdentifier() throws {
        assertProblem(.unexpectedIdentifier, bundling: try makeApp(identifier: "com.example.app"))
    }

    func testRejectsAMissingBundleIdentifier() throws {
        assertProblem(.missingIdentifier, bundling: try makeApp(identifier: nil))
    }

    func testRejectsAWrongVersion() throws {
        assertProblem(.unexpectedVersion, bundling: try makeApp(version: "9.9.9"))
    }

    func testRejectsAMissingVersion() throws {
        assertProblem(.missingVersion, bundling: try makeApp(version: nil))
    }

    func testRejectsAMissingExecutable() throws {
        assertProblem(.missingExecutable, bundling: try makeApp(executable: false))
    }

    func testRejectsAMalformedMinimumSystemVersion() throws {
        assertProblem(
            .malformedMinimumSystemVersion,
            bundling: try makeApp(minimum: "fourteen")
        )
    }

    func testRejectsAReleaseThatNeedsANewerMac() throws {
        assertProblem(.requiresNewerMacOS, bundling: try makeApp(minimum: "99.0"))
    }

    func testRejectsANonMachOExecutable() throws {
        // The plist is valid and the file is executable; `lipo` is what refuses it.
        assertProblem(.unsupportedArchitecture, bundling: try makeApp())
    }

    func testRejectsAMissingBundle() {
        XCTAssertThrowsError(
            try verifier().validate(bundleAt: directory.appendingPathComponent("Absent.app"))
        ) { error in
            XCTAssertEqual(error as? UpdateError, .bundleMissing)
        }
    }

    // MARK: - Extraction

    func testExtractsAndFindsTheApp() throws {
        let app = try makeApp()
        let archive = directory.appendingPathComponent("WillyDisk-1.0.1-arm64.zip")
        XCTAssertEqual(
            try ditto(["-c", "-k", "--keepParent", app.path, archive.path]),
            0
        )

        let destination = directory.appendingPathComponent("expanded", isDirectory: true)
        let expanded = try verifier().extract(archive: archive, into: destination)

        XCTAssertEqual(expanded.lastPathComponent, "WillyDisk.app")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: expanded.appendingPathComponent("Contents/Info.plist").path
            )
        )
    }

    func testRefusesToExpandIntoADirectoryWithFiles() throws {
        let app = try makeApp()
        let archive = directory.appendingPathComponent("WillyDisk-1.0.1-arm64.zip")
        XCTAssertEqual(
            try ditto(["-c", "-k", "--keepParent", app.path, archive.path]),
            0
        )

        let destination = directory.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: destination.appendingPathComponent("note.txt"))

        XCTAssertThrowsError(try verifier().extract(archive: archive, into: destination)) { error in
            XCTAssertEqual(error as? UpdateError, .extractionDirectoryNotEmpty)
        }
    }

    func testAnArchiveWithoutTheAppIsNotAnUpdate() throws {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not an app".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let archive = directory.appendingPathComponent("WillyDisk-1.0.1-arm64.zip")
        XCTAssertEqual(
            try ditto(["-c", "-k", "--keepParent", source.path, archive.path]),
            0
        )

        let destination = directory.appendingPathComponent("expanded", isDirectory: true)
        XCTAssertThrowsError(try verifier().extract(archive: archive, into: destination)) { error in
            XCTAssertEqual(error as? UpdateError, .bundleMissing)
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

    private func makeApp(
        identifier: String? = "com.willydisk.app",
        version: String? = "1.0.1",
        minimum: String? = "14.0",
        executable: Bool = true
    ) throws -> URL {
        let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let app = root.appendingPathComponent("WillyDisk.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)

        var plist: [String: Any] = [
            "CFBundleName": "WillyDisk",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "WillyDisk",
        ]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        if let version { plist["CFBundleShortVersionString"] = version }
        if let minimum { plist["LSMinimumSystemVersion"] = minimum }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        if executable {
            let executableURL = macos.appendingPathComponent("WillyDisk")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )
        }
        return app
    }

    private func assertProblem(_ problem: BundleProblem, bundling app: URL) {
        XCTAssertThrowsError(try verifier().validate(bundleAt: app)) { error in
            guard let updateError = error as? UpdateError,
                  case let .invalidBundle(found) = updateError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(found, problem)
        }
    }

    @discardableResult
    private func ditto(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
