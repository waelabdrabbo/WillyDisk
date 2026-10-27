import XCTest
@testable import DiskUpdate

/// Asset selection and the newer/older decision. These are the rules that decide
/// whether a download is offered at all, so every branch gets a test.
final class UpdateReleaseTests: XCTestCase {
    func testSelectsTheRunningArchitecturesTwoAssetsByName() throws {
        let release = makeRelease(version: "1.0.1")

        let armArchive = try XCTUnwrap(release.archive(for: .arm64))
        XCTAssertEqual(armArchive.name, "WillyDisk-1.0.1-arm64.zip")
        XCTAssertEqual(release.checksum(for: .arm64)?.name, "WillyDisk-1.0.1-arm64.zip.sha256")

        let intelArchive = try XCTUnwrap(release.archive(for: .x86_64))
        XCTAssertEqual(intelArchive.name, "WillyDisk-1.0.1-x86_64.zip")
        XCTAssertEqual(release.checksum(for: .x86_64)?.name, "WillyDisk-1.0.1-x86_64.zip.sha256")
    }

    func testNewerReleaseIsAvailableWithBothAssets() throws {
        let release = makeRelease(version: "1.0.2")
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.1"), architecture: .arm64)

        guard case let .available(candidate) = evaluator.evaluate(release) else {
            return XCTFail("expected an available update")
        }
        XCTAssertEqual(candidate.version, ReleaseVersion("1.0.2"))
        XCTAssertEqual(candidate.marketingVersion, "1.0.2")
        XCTAssertEqual(candidate.archive.name, "WillyDisk-1.0.2-arm64.zip")
        XCTAssertEqual(candidate.checksum.name, "WillyDisk-1.0.2-arm64.zip.sha256")
        XCTAssertEqual(candidate.release, release)
    }

    func testEqualVersionIsUpToDate() {
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.1"), architecture: .arm64)
        XCTAssertEqual(evaluator.evaluate(makeRelease(version: "1.0.1")), .upToDate)
    }

    func testOlderReleaseNeverDowngrades() {
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.2"), architecture: .arm64)
        XCTAssertEqual(evaluator.evaluate(makeRelease(version: "1.0.1")), .newerThanLatest)
    }

    func testMissingCurrentVersionCannotBeCompared() {
        let evaluator = UpdateEvaluator(currentVersion: nil, architecture: .arm64)
        XCTAssertEqual(evaluator.evaluate(makeRelease(version: "1.0.1")), .unknownCurrentVersion)
    }

    func testMissingArchiveForThisMac() {
        let assets = [
            asset("WillyDisk-1.0.1-x86_64.zip"),
            asset("WillyDisk-1.0.1-x86_64.zip.sha256"),
        ]
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.0"), architecture: .arm64)
        XCTAssertEqual(evaluator.evaluate(makeRelease(version: "1.0.1", assets: assets)), .noBuildForThisMac)
    }

    func testMissingChecksumIsIncompleteRatherThanAvailable() {
        let assets = [asset("WillyDisk-1.0.1-arm64.zip")]
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.0"), architecture: .arm64)
        XCTAssertEqual(
            evaluator.evaluate(makeRelease(version: "1.0.1", assets: assets)),
            .incompleteRelease(missing: ["WillyDisk-1.0.1-arm64.zip.sha256"])
        )
    }

    func testIntelSelectsTheIntelSlice() {
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.0"), architecture: .x86_64)
        guard case let .available(candidate) = evaluator.evaluate(makeRelease(version: "1.0.1")) else {
            return XCTFail("expected an available update")
        }
        XCTAssertEqual(candidate.archive.name, "WillyDisk-1.0.1-x86_64.zip")
    }

    func testAssetsFromAnotherVersionAreNotSelected() {
        let assets = [
            asset("WillyDisk-1.0.0-arm64.zip"),
            asset("WillyDisk-1.0.0-arm64.zip.sha256"),
        ]
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("0.9.0"), architecture: .arm64)
        XCTAssertEqual(evaluator.evaluate(makeRelease(version: "1.0.1", assets: assets)), .noBuildForThisMac)
    }

    // MARK: - Fixtures

    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(
            name: name,
            url: URL(string: "https://example.com/\(name)")!,
            byteCount: 42
        )
    }

    private func makeRelease(version: String, assets: [ReleaseAsset]? = nil) -> UpdateRelease {
        let defaultNames = [
            "WillyDisk-\(version)-arm64.zip",
            "WillyDisk-\(version)-arm64.zip.sha256",
            "WillyDisk-\(version)-x86_64.zip",
            "WillyDisk-\(version)-x86_64.zip.sha256",
        ]
        return UpdateRelease(
            tag: "v\(version)",
            marketingVersion: version,
            version: ReleaseVersion(version)!,
            name: "WillyDisk \(version)",
            notes: "Release notes",
            pageURL: URL(string: "https://github.com/waelabdrabbo/WillyDisk/releases/tag/v\(version)")!,
            publishedAt: nil,
            assets: assets ?? defaultNames.map(asset)
        )
    }
}
