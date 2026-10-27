import XCTest
import Foundation
@testable import DiskUpdate

/// The swap helper, exercised with real directories and a detached `/bin/sh`.
/// The helper is told to skip `open`, so the test never launches an app.
final class UpdateInstallerTests: XCTestCase {
    private var root: URL!
    private let installer = UpdateInstaller()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskUpdateInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Destination checks

    func testRejectsANonApplication() throws {
        let plain = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertThrowsError(try installer.validateDestination(for: plain)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .notAnApplication)
        }
    }

    func testRejectsATranslocatedCopy() {
        let translocated = root.appendingPathComponent(
            "AppTranslocation/ABC-123/WillyDisk.app",
            isDirectory: true
        )
        XCTAssertThrowsError(try installer.validateDestination(for: translocated)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .translocated)
        }
    }

    func testRejectsAnUnwritableParent() throws {
        let parent = root.appendingPathComponent("readonly", isDirectory: true)
        let app = parent.appendingPathComponent("WillyDisk.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: parent.path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: parent.path
        )

        XCTAssertThrowsError(try installer.validateDestination(for: app)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .destinationNotWritable)
        }
    }

    func testRejectsAMissingStagedApp() throws {
        let host = try makeHost()
        let request = UpdateInstallRequest(
            targetApp: host,
            stagedApp: root.appendingPathComponent("staged/WillyDisk.app"),
            recoveryDirectory: root.appendingPathComponent("Recovery/1.0.2"),
            resultURL: root.appendingPathComponent("install-result"),
            version: "1.0.2",
            parentPID: 999_999,
            relaunch: false
        )
        XCTAssertThrowsError(try installer.install(request)) { error in
            XCTAssertEqual(error as? UpdateInstallError, .stagedAppMissing)
        }
    }

    // MARK: - Swap

    func testInstallsTheStagedAppAndKeepsTheOldOne() throws {
        let host = try makeHost(marker: "old")
        let staged = try makeStaged(marker: "new")
        let request = makeRequest(target: host, staged: staged)

        try installer.install(request)

        let outcome = try XCTUnwrap(waitForResult())
        XCTAssertEqual(outcome.status, .installed)
        XCTAssertEqual(outcome.version, "1.0.2")
        XCTAssertNil(outcome.failure)

        XCTAssertEqual(try marker(in: host), "new")
        XCTAssertEqual(try marker(in: backupURL()), "old")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: request.recoveryDirectory.appendingPathComponent("install.log").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: request.resultURL.path),
            "consumeResult should remove the result after reading it"
        )
    }

    func testAFailedCopyRestoresTheOldApp() throws {
        let host = try makeHost(marker: "old")
        let staged = try makeStaged(marker: "new")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: staged.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: staged.path
            )
        }

        let request = makeRequest(target: host, staged: staged)
        try installer.install(request)

        let outcome = try XCTUnwrap(waitForResult())
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertEqual(outcome.failure, .installFailed)
        XCTAssertEqual(try marker(in: host), "old")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: backupURL().path),
            "the backup is moved back to the target when the copy fails"
        )
    }

    // MARK: - Result

    func testConsumesAndRemovesAResult() throws {
        let result = root.appendingPathComponent("install-result")
        try Data(
            "status=installed\nversion=1.0.2\nrelaunched=1\nfailure=none\n".utf8
        ).write(to: result)

        let outcome = try XCTUnwrap(installer.consumeResult(at: result))
        XCTAssertEqual(outcome.status, .installed)
        XCTAssertEqual(outcome.version, "1.0.2")
        XCTAssertTrue(outcome.relaunched)
        XCTAssertNil(outcome.failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path))
    }

    func testRejectsAMalformedResult() throws {
        let result = root.appendingPathComponent("install-result")
        try Data("not a result\n".utf8).write(to: result)
        XCTAssertNil(installer.consumeResult(at: result))
    }

    // MARK: - Fixtures

    private func makeHost(marker: String = "old") throws -> URL {
        let parent = root.appendingPathComponent("host", isDirectory: true)
        let app = parent.appendingPathComponent("WillyDisk.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(marker.utf8).write(
            to: app.appendingPathComponent("Contents/marker")
        )
        return app
    }

    private func makeStaged(marker: String = "new") throws -> URL {
        let app = root.appendingPathComponent("staged/WillyDisk.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(marker.utf8).write(
            to: app.appendingPathComponent("Contents/marker")
        )
        return app
    }

    private func makeRequest(target: URL, staged: URL) -> UpdateInstallRequest {
        UpdateInstallRequest(
            targetApp: target,
            stagedApp: staged,
            recoveryDirectory: root.appendingPathComponent("Recovery/1.0.2"),
            resultURL: root.appendingPathComponent("install-result"),
            version: "1.0.2",
            parentPID: 999_999,
            relaunch: false
        )
    }

    private func backupURL() -> URL {
        root.appendingPathComponent("Recovery/1.0.2/backup/WillyDisk.app")
    }

    private func marker(in app: URL) throws -> String {
        try String(
            contentsOf: app.appendingPathComponent("Contents/marker"),
            encoding: .utf8
        )
    }

    private func waitForResult(timeout: TimeInterval = 5) -> UpdateInstallOutcome? {
        let result = root.appendingPathComponent("install-result")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome = installer.consumeResult(at: result) {
                return outcome
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
}
