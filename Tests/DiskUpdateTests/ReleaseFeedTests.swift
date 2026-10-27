import XCTest
@testable import DiskUpdate

/// The GitHub payload, its rejections, and the one request the app makes.
final class ReleaseFeedTests: XCTestCase {

    // MARK: - Decoding

    func testDecodesThePublishedPayload() throws {
        let release = try GitHubReleaseFeed.decodeRelease(from: payloadData())

        XCTAssertEqual(release.tag, "v1.0.1")
        XCTAssertEqual(release.marketingVersion, "1.0.1")
        XCTAssertEqual(release.version, ReleaseVersion("1.0.1"))
        XCTAssertEqual(release.name, "WillyDisk 1.0.1")
        XCTAssertEqual(release.notes, "Notes for 1.0.1")
        XCTAssertEqual(
            release.pageURL.absoluteString,
            "https://github.com/waelabdrabbo/WillyDisk/releases/tag/v1.0.1"
        )
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.assets.count, 4)
        XCTAssertEqual(release.archive(for: .arm64)?.name, "WillyDisk-1.0.1-arm64.zip")
        XCTAssertEqual(release.checksum(for: .x86_64)?.name, "WillyDisk-1.0.1-x86_64.zip.sha256")
    }

    func testMissingBodyIsAnEmptyNote() throws {
        let release = try GitHubReleaseFeed.decodeRelease(from: payloadData(body: nil))
        XCTAssertEqual(release.notes, "")
    }

    func testUnparseablePublishedDateIsNilRatherThanAFailure() throws {
        let release = try GitHubReleaseFeed.decodeRelease(
            from: payloadData(publishedAt: "not a date")
        )
        XCTAssertNil(release.publishedAt)
    }

    func testMissingDraftFlagsAreTreatedAsStable() throws {
        let release = try GitHubReleaseFeed.decodeRelease(
            from: payloadData(draft: nil, prerelease: nil)
        )
        XCTAssertEqual(release.tag, "v1.0.1")
    }

    func testEmptyAssetListDecodesButIsNotInstallable() throws {
        let release = try GitHubReleaseFeed.decodeRelease(from: payloadData(assets: []))
        XCTAssertTrue(release.assets.isEmpty)
        let evaluator = UpdateEvaluator(currentVersion: ReleaseVersion("1.0.0"), architecture: .arm64)
        XCTAssertEqual(evaluator.evaluate(release), .noBuildForThisMac)
    }

    func testRejectsATagWithoutTheV() {
        expect(.malformedRelease, payloadData(tag: "1.0.1"))
    }

    func testRejectsATagWithMoreThanThreeComponents() {
        expect(.malformedRelease, payloadData(tag: "v1.0.1.2"))
        expect(.malformedRelease, payloadData(tag: "vv1.0.1"))
    }

    func testRejectsDraftAndPrerelease() {
        expect(.noRelease, payloadData(draft: true))
        expect(.noRelease, payloadData(prerelease: true))
    }

    func testRejectsAnInsecurePage() {
        expect(
            .insecureAsset,
            payloadData(htmlURL: "http://github.com/waelabdrabbo/WillyDisk/releases/tag/v1.0.1")
        )
    }

    func testRejectsAnInsecureAsset() {
        expect(
            .insecureAsset,
            payloadData(assetURL: "http://github.com/example/WillyDisk-1.0.1-arm64.zip")
        )
    }

    func testRejectsMalformedJSON() {
        expect(.malformedRelease, Data("not json".utf8))
    }

    func testRejectsAPayloadWithoutHTMLURL() throws {
        var object = payloadObject()
        object.removeValue(forKey: "html_url")
        expect(.malformedRelease, try! JSONSerialization.data(withJSONObject: object))
    }

    // MARK: - Requests and statuses

    func testSendsConditionalHeadersAndReturnsTheRelease() async throws {
        let recorder = RequestRecorder()
        let feed = makeFeed(
            response: FeedResponse(
                statusCode: 200,
                headers: ["ETag": "\"release-etag\""],
                body: payloadData()
            ),
            recorder: recorder
        )

        let result = try await feed.latestRelease(ifNoneMatch: "\"old-etag\"")
        guard case let .release(release, etag) = result else {
            return XCTFail("expected a release")
        }
        XCTAssertEqual(release.tag, "v1.0.1")
        XCTAssertEqual(etag, "\"release-etag\"")

        let request = await recorder.lastRequest()
        XCTAssertEqual(request?.url?.absoluteString, "https://example.com/releases/latest")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "WillyDisk/1.0.1")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "If-None-Match"), "\"old-etag\"")
    }

    func testOmitsIfNoneMatchWithoutAnETag() async throws {
        let recorder = RequestRecorder()
        let feed = makeFeed(
            response: FeedResponse(statusCode: 200, body: payloadData()),
            recorder: recorder
        )
        _ = try await feed.latestRelease(ifNoneMatch: nil)
        let request = await recorder.lastRequest()
        XCTAssertNil(request?.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testNotModifiedKeepsTheETag() async throws {
        let feed = makeFeed(
            response: FeedResponse(statusCode: 304, headers: ["ETag": "\"same\""])
        )
        let result = try await feed.latestRelease(ifNoneMatch: "\"same\"")
        guard case let .notModified(etag) = result else {
            return XCTFail("expected not modified")
        }
        XCTAssertEqual(etag, "\"same\"")
    }

    func testNotFoundMeansNoRelease() async {
        await expectFeedError(.noRelease, statusCode: 404)
    }

    func testRateLimitIsNamedRatherThanAGeneric403() async {
        await expectFeedError(
            .rateLimited,
            response: FeedResponse(
                statusCode: 403,
                headers: ["X-RateLimit-Remaining": "0"]
            )
        )
    }

    func testA429IsAlsoARateLimit() async {
        await expectFeedError(.rateLimited, statusCode: 429)
    }

    func testAPlain403StaysAnHTTPStatus() async {
        await expectFeedError(.httpStatus(403), statusCode: 403)
    }

    func testServerErrorStaysAnHTTPStatus() async {
        await expectFeedError(.httpStatus(500), statusCode: 500)
    }

    func testOfflineIsDistinctFromATimedOutRequest() async {
        await expectTransportError(.networkUnavailable, code: .notConnectedToInternet)
        await expectTransportError(.networkUnavailable, code: .cannotFindHost)
        await expectTransportError(.timedOut, code: .timedOut)
        await expectTransportError(.cancelled, code: .cancelled)
        await expectTransportError(.transport, code: .badServerResponse)
    }

    func testHeaderLookupIsCaseInsensitive() {
        let response = FeedResponse(statusCode: 200, headers: ["ETag": "\"x\""])
        XCTAssertEqual(response.header("etag"), "\"x\"")
        XCTAssertEqual(response.header("ETag"), "\"x\"")
    }

    // MARK: - Fixtures

    private func makeFeed(
        response: FeedResponse,
        recorder: RequestRecorder? = nil
    ) -> GitHubReleaseFeed {
        GitHubReleaseFeed(
            transport: StubTransport(response: response, recorder: recorder),
            endpoint: URL(string: "https://example.com/releases/latest")!,
            userAgent: "WillyDisk/1.0.1"
        )
    }

    private func expectFeedError(_ expected: UpdateError, statusCode: Int) async {
        await expectFeedError(expected, response: FeedResponse(statusCode: statusCode))
    }

    private func expectFeedError(_ expected: UpdateError, response: FeedResponse) async {
        let feed = makeFeed(response: response)
        do {
            _ = try await feed.latestRelease(ifNoneMatch: nil)
            XCTFail("expected \(expected)")
        } catch let error as UpdateError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private func expectTransportError(_ expected: UpdateError, code: URLError.Code) async {
        let feed = GitHubReleaseFeed(
            transport: ThrowingTransport(error: URLError(code)),
            endpoint: URL(string: "https://example.com/releases/latest")!
        )
        do {
            _ = try await feed.latestRelease(ifNoneMatch: nil)
            XCTFail("expected \(expected)")
        } catch let error as UpdateError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    private func expect(_ expected: UpdateError, _ data: Data) {
        XCTAssertThrowsError(try GitHubReleaseFeed.decodeRelease(from: data)) { error in
            XCTAssertEqual(error as? UpdateError, expected)
        }
    }

    private func payloadObject(
        tag: String = "v1.0.1",
        draft: Bool? = false,
        prerelease: Bool? = false,
        htmlURL: String = "https://github.com/waelabdrabbo/WillyDisk/releases/tag/v1.0.1",
        body: String? = "Notes for 1.0.1",
        publishedAt: String? = "2026-10-26T19:18:46Z",
        assetURL: String = "https://github.com/waelabdrabbo/WillyDisk/releases/download/v1.0.1/WillyDisk-1.0.1-arm64.zip",
        assets: [[String: Any]]? = nil
    ) -> [String: Any] {
        let defaultAssets: [[String: Any]] = [
            [
                "name": "WillyDisk-1.0.1-arm64.zip",
                "browser_download_url": assetURL,
                "size": 2_557_297,
            ],
            [
                "name": "WillyDisk-1.0.1-arm64.zip.sha256",
                "browser_download_url": assetURL + ".sha256",
                "size": 92,
            ],
            [
                "name": "WillyDisk-1.0.1-x86_64.zip",
                "browser_download_url": assetURL.replacingOccurrences(of: "arm64", with: "x86_64"),
                "size": 2_692_619,
            ],
            [
                "name": "WillyDisk-1.0.1-x86_64.zip.sha256",
                "browser_download_url": assetURL.replacingOccurrences(of: "arm64", with: "x86_64") + ".sha256",
                "size": 93,
            ],
        ]

        var object: [String: Any] = [
            "tag_name": tag,
            "name": "WillyDisk 1.0.1",
            "html_url": htmlURL,
            "assets": assets ?? defaultAssets,
        ]
        if let body { object["body"] = body }
        if let draft { object["draft"] = draft }
        if let prerelease { object["prerelease"] = prerelease }
        if let publishedAt { object["published_at"] = publishedAt }
        return object
    }

    private func payloadData(
        tag: String = "v1.0.1",
        draft: Bool? = false,
        prerelease: Bool? = false,
        htmlURL: String = "https://github.com/waelabdrabbo/WillyDisk/releases/tag/v1.0.1",
        body: String? = "Notes for 1.0.1",
        publishedAt: String? = "2026-10-26T19:18:46Z",
        assetURL: String = "https://github.com/waelabdrabbo/WillyDisk/releases/download/v1.0.1/WillyDisk-1.0.1-arm64.zip",
        assets: [[String: Any]]? = nil
    ) -> Data {
        try! JSONSerialization.data(
            withJSONObject: payloadObject(
                tag: tag,
                draft: draft,
                prerelease: prerelease,
                htmlURL: htmlURL,
                body: body,
                publishedAt: publishedAt,
                assetURL: assetURL,
                assets: assets
            )
        )
    }
}

private struct StubTransport: FeedTransport {
    let response: FeedResponse
    let recorder: RequestRecorder?

    init(response: FeedResponse, recorder: RequestRecorder? = nil) {
        self.response = response
        self.recorder = recorder
    }

    func data(for request: URLRequest) async throws -> FeedResponse {
        if let recorder {
            await recorder.record(request)
        }
        return response
    }
}

private struct ThrowingTransport: FeedTransport {
    let error: URLError

    func data(for request: URLRequest) async throws -> FeedResponse {
        throw error
    }
}

private actor RequestRecorder {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
