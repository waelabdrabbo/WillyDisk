import XCTest
import Foundation
import DiskUI
import DiskUpdate

/// The update controller, its preferences, and the staging directory, exercised
/// with a fake feed, downloader, and verifier. Nothing here opens a socket or
/// builds a signed bundle.
@MainActor
final class UpdateQATests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var storage: UpdateStorage!
    private var preferences: UpdatePreferences!

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "WillyDiskUpdateQATests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        preferences = UpdatePreferences(defaults: defaults)
        storage = UpdateStorage(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("WillyDiskUpdateQATests-\(UUID().uuidString)")
        )
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let storage {
            try? FileManager.default.removeItem(at: storage.root)
        }
        try super.tearDownWithError()
    }

    // MARK: - Checking

    func testCheckOffersTheNewerReleaseWithoutAConditionalRequest() async {
        let feed = StubFeed(
            result: .release(makeRelease(version: "1.0.2"), etag: "\"e1\"")
        )
        let controller = makeController(feed: feed)

        await controller.check(manual: true)

        guard case let .available(offer) = controller.state else {
            return XCTFail("expected an available update, got \(controller.state)")
        }
        XCTAssertEqual(offer.version, "1.0.2")
        XCTAssertEqual(offer.currentVersion, "1.0.1")
        XCTAssertEqual(offer.notes, "Notes for 1.0.2")
        XCTAssertEqual(offer.downloadBytes, 64)
        XCTAssertEqual(preferences.lastCheck, fixedNow)
        XCTAssertNil(feed.lastETag)
    }

    func testAnUnrequestedNotModifiedIsNotUpToDate() async {
        let feed = StubFeed(result: .notModified(etag: "\"e1\""))
        let controller = makeController(feed: feed)

        await controller.check(manual: true)

        XCTAssertEqual(controller.state, .failed(.unknown, pageURL: nil))
        XCTAssertNil(feed.lastETag)
        XCTAssertNil(preferences.lastCheck)
        XCTAssertEqual(preferences.lastAttempt, fixedNow)
    }

    func testAutomaticCheckHonoursSkipButManualCheckShowsIt() async {
        preferences.skip(try! XCTUnwrap(ReleaseVersion("1.0.2")))
        let feed = StubFeed(
            result: .release(makeRelease(version: "1.0.2"), etag: nil)
        )
        let controller = makeController(feed: feed)

        await controller.check(manual: false)
        XCTAssertEqual(controller.state, .upToDate(currentVersion: "1.0.1"))

        await controller.check(manual: true)
        guard case .available = controller.state else {
            return XCTFail("a manual check must ignore the skip, got \(controller.state)")
        }
    }

    func testFailureIsTypedAndRecordsOnlyAnAttempt() async {
        let feed = StubFeed(error: .networkUnavailable)
        let controller = makeController(feed: feed)

        await controller.check(manual: true)

        XCTAssertEqual(controller.state, .failed(.offline, pageURL: nil))
        XCTAssertNil(preferences.lastCheck)
        XCTAssertEqual(preferences.lastAttempt, fixedNow)
    }

    func testANewerInstalledBuildIsNotOfferedAsADowngrade() async {
        let feed = StubFeed(
            result: .release(makeRelease(version: "1.0.0"), etag: nil)
        )
        let controller = makeController(feed: feed, build: makeBuild(version: "1.0.1"))

        await controller.check(manual: true)

        XCTAssertEqual(
            controller.state,
            .newerThanLatest(currentVersion: "1.0.1", latestVersion: "1.0.0")
        )
    }

    // MARK: - Downloading

    func testDownloadReachesReady() async {
        let feed = StubFeed(
            result: .release(makeRelease(version: "1.0.2"), etag: nil)
        )
        let controller = makeController(
            feed: feed,
            downloader: StubDownloader(),
            verifier: StubVerifier()
        )

        await controller.check(manual: true)
        await controller.download()

        guard case let .ready(ready) = controller.state else {
            return XCTFail("expected a verified download, got \(controller.state)")
        }
        XCTAssertEqual(ready.version, "1.0.2")
        XCTAssertEqual(ready.currentVersion, "1.0.1")
        XCTAssertEqual(ready.digest, "test-digest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.archiveURL.path))
        XCTAssertEqual(ready.pageURL.absoluteString, "https://example.com/releases/1.0.2")
    }

    func testAnHTTPFailureDuringDownloadIsADownloadFailure() async {
        let release = makeRelease(version: "1.0.2")
        let controller = makeController(
            feed: StubFeed(result: .release(release, etag: nil)),
            downloader: HTTPFailureDownloader(),
            verifier: StubVerifier()
        )

        await controller.check(manual: true)
        await controller.download()

        XCTAssertEqual(
            controller.state,
            .failed(.downloadFailed, pageURL: release.pageURL)
        )
    }

    func testAVerificationFailureRetainsItsOwnReason() async {
        let release = makeRelease(version: "1.0.2")
        let controller = makeController(
            feed: StubFeed(result: .release(release, etag: nil)),
            downloader: StubDownloader(),
            verifier: ThrowingVerifier()
        )

        await controller.check(manual: true)
        await controller.download()

        XCTAssertEqual(
            controller.state,
            .failed(.checksumMismatch, pageURL: release.pageURL)
        )
    }

    func testRetryAfterADownloadFailureResumesWithoutRefetchingTheFeed() async {
        let feed = StubFeed(
            result: .release(makeRelease(version: "1.0.2"), etag: nil)
        )
        let controller = makeController(
            feed: feed,
            downloader: FlakyDownloader(),
            verifier: StubVerifier()
        )

        await controller.check(manual: true)
        await controller.download()
        guard case .failed(.downloadFailed, _) = controller.state else {
            return XCTFail("expected a download failure, got \(controller.state)")
        }

        await controller.retry()

        guard case .ready = controller.state else {
            return XCTFail("expected the retry to reach ready, got \(controller.state)")
        }
        XCTAssertEqual(feed.requestCount, 1)
    }

    func testDownloadFailureKeepsTheOfferAndRemovesTheStagingDirectory() async {
        let release = makeRelease(version: "1.0.2")
        let feed = StubFeed(result: .release(release, etag: nil))
        let controller = makeController(
            feed: feed,
            downloader: FailingDownloader(),
            verifier: StubVerifier()
        )

        await controller.check(manual: true)
        await controller.download()

        guard case let .failed(.downloadFailed, pageURL) = controller.state else {
            return XCTFail("expected a download failure, got \(controller.state)")
        }
        XCTAssertEqual(pageURL, release.pageURL)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.directory(for: "1.0.2").path
            )
        )
    }

    // MARK: - Preferences

    func testPreferencesCadenceSkipAndPersistence() throws {
        XCTAssertTrue(preferences.checksAutomatically)
        XCTAssertTrue(preferences.shouldCheck(now: fixedNow))

        preferences.recordAttempt(at: fixedNow)
        XCTAssertFalse(preferences.shouldCheck(now: fixedNow.addingTimeInterval(60)))
        XCTAssertTrue(
            preferences.shouldCheck(
                now: fixedNow.addingTimeInterval(UpdatePreferences.checkInterval + 1)
            )
        )

        preferences.recordSuccess(at: fixedNow)
        XCTAssertEqual(preferences.lastCheck, fixedNow)

        preferences.skip(try XCTUnwrap(ReleaseVersion("1.0.2")))
        XCTAssertTrue(preferences.isSkipped(try XCTUnwrap(ReleaseVersion("1.0.2"))))
        XCTAssertFalse(preferences.isSkipped(try XCTUnwrap(ReleaseVersion("1.0.3"))))

        let reloaded = UpdatePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.lastCheck, fixedNow)
        XCTAssertTrue(reloaded.isSkipped(try XCTUnwrap(ReleaseVersion("1.0.2"))))
    }

    func testTurningAutomaticChecksOffStopsTheCadence() {
        preferences.recordAttempt(at: fixedNow.addingTimeInterval(-2 * UpdatePreferences.checkInterval))
        XCTAssertTrue(preferences.shouldCheck(now: fixedNow))

        preferences.checksAutomatically = false
        XCTAssertFalse(preferences.shouldCheck(now: fixedNow))
    }

    // MARK: - Storage

    func testStorageCreatesAnOwnerOnlyDirectoryAndReplacesIt() throws {
        let directory = try storage.prepare(version: "1.0.2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )

        try Data("old".utf8).write(to: directory.appendingPathComponent("old"))
        let again = try storage.prepare(version: "1.0.2")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: again.appendingPathComponent("old").path)
        )

        storage.discard(version: "1.0.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path))
    }

    func testStorageRefusesAPathLikeVersion() {
        for version in ["../bad", "..", ".", "1..2", "1.0.1.2", "v1.0.1", ""] {
            XCTAssertThrowsError(try storage.prepare(version: version)) { error in
                XCTAssertEqual(
                    error as? UpdateError,
                    .downloadFailed,
                    "accepted \(version.debugDescription)"
                )
            }
        }
    }

    func testRequiredSpaceHasAFloor() {
        XCTAssertGreaterThanOrEqual(
            storage.requiredBytes(forDownloadBytes: 1),
            64 * 1024 * 1024
        )
        XCTAssertGreaterThan(
            storage.requiredBytes(forDownloadBytes: 10 * 1024 * 1024),
            storage.requiredBytes(forDownloadBytes: 1)
        )
    }

    // MARK: - Failure mapping

    func testFailuresMapToTheSmallVocabulary() {
        XCTAssertEqual(UpdateFailure.from(.networkUnavailable), .offline)
        XCTAssertEqual(UpdateFailure.from(.timedOut), .timedOut)
        XCTAssertEqual(UpdateFailure.from(.httpStatus(500)), .http)
        XCTAssertEqual(UpdateFailure.from(.malformedRelease), .malformedFeed)
        XCTAssertEqual(UpdateFailure.from(.downloadTooLarge), .downloadFailed)
        XCTAssertEqual(UpdateFailure.from(.insufficientSpace), .insufficientSpace)
        XCTAssertEqual(
            UpdateFailure.from(.checksumMismatch(expected: "a", actual: "b")),
            .checksumMismatch
        )
    }

    // MARK: - Fixtures

    private func makeBuild(version: String = "1.0.1") -> InstalledBuild {
        InstalledBuild(
            marketingVersion: version,
            version: ReleaseVersion(version)!,
            bundleIdentifier: "com.willydisk.app",
            architecture: .arm64,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 0,
                patchVersion: 0
            )
        )
    }

    private func makeRelease(version: String) -> UpdateRelease {
        let base = "https://example.com/releases/\(version)"
        let assets = [
            ReleaseAsset(
                name: "WillyDisk-\(version)-arm64.zip",
                url: URL(string: "\(base)/arm64.zip")!,
                byteCount: 64
            ),
            ReleaseAsset(
                name: "WillyDisk-\(version)-arm64.zip.sha256",
                url: URL(string: "\(base)/arm64.zip.sha256")!,
                byteCount: 90
            ),
            ReleaseAsset(
                name: "WillyDisk-\(version)-x86_64.zip",
                url: URL(string: "\(base)/x86_64.zip")!,
                byteCount: 64
            ),
            ReleaseAsset(
                name: "WillyDisk-\(version)-x86_64.zip.sha256",
                url: URL(string: "\(base)/x86_64.zip.sha256")!,
                byteCount: 90
            ),
        ]
        return UpdateRelease(
            tag: "v\(version)",
            marketingVersion: version,
            version: ReleaseVersion(version)!,
            name: "WillyDisk \(version)",
            notes: "Notes for \(version)",
            pageURL: URL(string: "\(base)")!,
            publishedAt: nil,
            assets: assets
        )
    }

    private func makeController(
        feed: any ReleaseFeed,
        downloader: any UpdateDownloading = StubDownloader(),
        verifier: any UpdateVerifying = StubVerifier(),
        build: InstalledBuild? = nil
    ) -> UpdateController {
        let now = fixedNow
        return UpdateController(
            feed: feed,
            downloader: downloader,
            verifier: verifier,
            preferences: preferences,
            build: build ?? makeBuild(),
            storage: storage,
            now: { now }
        )
    }
}

private final class StubFeed: ReleaseFeed, @unchecked Sendable {
    let result: ReleaseFeedResult
    let error: UpdateError?
    private(set) var lastETag: String?
    private(set) var requestCount = 0

    init(result: ReleaseFeedResult) {
        self.result = result
        self.error = nil
    }

    init(error: UpdateError) {
        self.result = .notModified(etag: nil)
        self.error = error
    }

    func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseFeedResult {
        requestCount += 1
        lastETag = etag
        if let error {
            throw error
        }
        return result
    }
}

private struct StubDownloader: UpdateDownloading {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let data = Data("asset".utf8)
        progress(
            DownloadProgress(
                receivedBytes: Int64(data.count),
                expectedBytes: Int64(data.count)
            )
        )
        try data.write(to: destination)
    }
}

private final class FlakyDownloader: UpdateDownloading, @unchecked Sendable {
    private var attempts = 0

    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        attempts += 1
        if attempts == 1 {
            throw UpdateError.downloadFailed
        }
        let data = Data("asset".utf8)
        progress(
            DownloadProgress(
                receivedBytes: Int64(data.count),
                expectedBytes: Int64(data.count)
            )
        )
        try data.write(to: destination)
    }
}

private struct HTTPFailureDownloader: UpdateDownloading {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        throw UpdateError.httpStatus(404)
    }
}

private struct FailingDownloader: UpdateDownloading {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        throw UpdateError.downloadFailed
    }
}

private struct ThrowingVerifier: UpdateVerifying {
    func verify(
        candidate: UpdateCandidate,
        archive: URL,
        checksumFile: URL,
        expandedDirectory: URL
    ) async throws -> VerifiedUpdate {
        throw UpdateError.checksumMismatch(expected: "a", actual: "b")
    }
}

private struct StubVerifier: UpdateVerifying {
    func verify(
        candidate: UpdateCandidate,
        archive: URL,
        checksumFile: URL,
        expandedDirectory: URL
    ) async throws -> VerifiedUpdate {
        VerifiedUpdate(
            digest: "test-digest",
            bundleURL: expandedDirectory.appendingPathComponent("WillyDisk.app")
        )
    }
}
