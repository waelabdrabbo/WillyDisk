import Foundation

/// The bytes and status one HTTP response produced.
///
/// Header names are lowercased on the way in, so a caller never has to remember
/// whether GitHub spelled it `ETag` or `etag`.
public struct FeedResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// The one piece of networking the feed needs, separated so tests can answer
/// without a server or a URL protocol.
public protocol FeedTransport: Sendable {
    func data(for request: URLRequest) async throws -> FeedResponse
}

/// A transport backed by `URLSession`.
public struct URLSessionFeedTransport: FeedTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> FeedResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = value as? String ?? String(describing: value)
        }
        return FeedResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// What one conditional request found.
public enum ReleaseFeedResult: Sendable {
    case notModified(etag: String?)
    case release(UpdateRelease, etag: String?)
}

/// The feed seam. A controller can be tested against a fixture without opening a
/// socket, and a future front end can supply a different release host.
public protocol ReleaseFeed: Sendable {
    func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseFeedResult
}

/// Reads the latest stable release from GitHub's REST API.
///
/// The endpoint is unauthenticated by design: the repository is public, the
/// request carries no account or scan data, and the entire exchange is one GET.
/// GitHub's rate limit is generous for a check that runs at most once a day. The
/// client can send an ETag, but the app does not: a `304` says the release list has
/// not changed, not that the installed app is current, and without the release body
/// it cannot be turned into an offer.
public struct GitHubReleaseFeed: ReleaseFeed {
    public static let defaultEndpoint = URL(
        string: "https://api.github.com/repos/waelabdrabbo/WillyDisk/releases/latest"
    )!

    private let transport: any FeedTransport
    private let endpoint: URL
    private let userAgent: String

    public init(
        transport: any FeedTransport = URLSessionFeedTransport(),
        endpoint: URL = GitHubReleaseFeed.defaultEndpoint,
        userAgent: String = "WillyDisk"
    ) {
        self.transport = transport
        self.endpoint = endpoint
        self.userAgent = userAgent
    }

    public func latestRelease(ifNoneMatch etag: String?) async throws -> ReleaseFeedResult {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let response: FeedResponse
        do {
            response = try await transport.data(for: request)
        } catch let error as UpdateError {
            throw error
        } catch let error as URLError {
            throw UpdateError.transportError(from: error)
        } catch {
            throw UpdateError.transport
        }

        switch response.statusCode {
        case 304:
            return .notModified(etag: response.header("etag") ?? etag)
        case 200:
            let release = try Self.decodeRelease(from: response.body)
            return .release(release, etag: response.header("etag"))
        case 403, 429:
            if response.statusCode == 429 || response.header("x-ratelimit-remaining") == "0" {
                throw UpdateError.rateLimited
            }
            throw UpdateError.httpStatus(response.statusCode)
        case 404:
            throw UpdateError.noRelease
        default:
            throw UpdateError.httpStatus(response.statusCode)
        }
    }

    /// Turns one release payload into the value the rest of the updater reads.
    ///
    /// A release is rejected as a whole when its tag or page is not something the
    /// updater can trust. A release with no archive for this Mac is still a valid
    /// release: the evaluator reports that as `noBuildForThisMac` rather than
    /// pretending a download failed.
    static func decodeRelease(from data: Data) throws -> UpdateRelease {
        let payload: GitHubReleasePayload
        do {
            payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            throw UpdateError.malformedRelease
        }

        guard payload.draft != true, payload.prerelease != true else {
            throw UpdateError.noRelease
        }
        guard payload.tagName.hasPrefix("v") else {
            throw UpdateError.malformedRelease
        }
        let marketingVersion = String(payload.tagName.dropFirst())
        guard !marketingVersion.isEmpty,
              marketingVersion == marketingVersion.trimmingCharacters(in: .whitespacesAndNewlines),
              !marketingVersion.lowercased().hasPrefix("v"),
              let version = ReleaseVersion(marketingVersion) else {
            throw UpdateError.malformedRelease
        }
        guard payload.htmlURL.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureAsset
        }

        let assets = try payload.assets.map { asset -> ReleaseAsset in
            guard asset.browserDownloadURL.scheme?.lowercased() == "https" else {
                throw UpdateError.insecureAsset
            }
            return ReleaseAsset(
                name: asset.name,
                url: asset.browserDownloadURL,
                byteCount: asset.size
            )
        }

        return UpdateRelease(
            tag: payload.tagName,
            marketingVersion: marketingVersion,
            version: version,
            name: payload.name,
            notes: payload.body ?? "",
            pageURL: payload.htmlURL,
            publishedAt: date(from: payload.publishedAt),
            assets: assets
        )
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

private struct GitHubReleasePayload: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool?
    let prerelease: Bool?
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}
