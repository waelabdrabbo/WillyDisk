import Foundation

/// Why a check, download, or verification could not finish.
///
/// These cases are what a screen, a log, or a diagnostic reasons about. The
/// sentences a person reads live in `DiskLocalization`; this type stays free of
/// user-facing text so the same failure can be worded differently by the app and
/// by a future command-line front end.
public enum UpdateError: Error, Equatable, Sendable {
    // MARK: - Feed

    /// The response was not an HTTP response this code can read.
    case invalidResponse
    case httpStatus(Int)
    case rateLimited
    case noRelease
    case malformedRelease
    case insecureAsset
    case networkUnavailable
    case timedOut
    case cancelled
    case transport

    // MARK: - Verification

    case checksumUnreadable
    case checksumMalformed
    case checksumMismatch(expected: String, actual: String)
    case checksumNameMismatch(expected: String, found: String)
    case sizeMismatch(expected: Int, actual: Int)
    case archiveMissing
    case archiveUnreadable
    case archiveNameMismatch(expected: String, found: String)
    case extractionDirectoryNotEmpty
    case extractionFailed
    case bundleMissing
    case bundleOutsideDestination
    case invalidBundle(BundleProblem)
    case toolFailed(tool: String, status: Int32)
}

/// The part of a staged app that disagrees with the release it came from.
public enum BundleProblem: Equatable, Sendable {
    case missingIdentifier
    case unexpectedIdentifier
    case missingVersion
    case unexpectedVersion
    case missingExecutable
    case malformedMinimumSystemVersion
    case requiresNewerMacOS
    case unsupportedArchitecture
    case signatureInvalid
}

extension UpdateError {
    /// Maps a URL loading failure onto the small set of reasons the UI words
    /// differently. The distinction matters: offline is a retry-later message,
    /// while a protocol failure is not the person's connection.
    static func transportError(from error: URLError) -> UpdateError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .internationalRoamingOff,
             .dataNotAllowed:
            return .networkUnavailable
        default:
            return .transport
        }
    }
}
