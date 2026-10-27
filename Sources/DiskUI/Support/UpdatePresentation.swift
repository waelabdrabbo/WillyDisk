import Foundation
import DiskUpdate

/// What the update sheet offers for one release. It carries no localized text:
/// the sheet resolves the sentences, and the controller can be tested without a
/// view.
public struct UpdateOffer: Equatable, Sendable {
    public let version: String
    public let currentVersion: String
    public let notes: String
    public let downloadBytes: Int
    public let pageURL: URL
    public let releaseTitle: String?

    public init(
        version: String,
        currentVersion: String,
        notes: String,
        downloadBytes: Int,
        pageURL: URL,
        releaseTitle: String?
    ) {
        self.version = version
        self.currentVersion = currentVersion
        self.notes = notes
        self.downloadBytes = downloadBytes
        self.pageURL = pageURL
        self.releaseTitle = releaseTitle
    }
}

/// A verified download waiting for the install transaction (which is not built
/// yet). `archiveURL` is the downloaded zip; `digest` is the checked SHA-256.
public struct ReadyUpdate: Equatable, Sendable {
    public let version: String
    public let currentVersion: String
    public let archiveURL: URL
    public let digest: String
    public let pageURL: URL

    public init(
        version: String,
        currentVersion: String,
        archiveURL: URL,
        digest: String,
        pageURL: URL
    ) {
        self.version = version
        self.currentVersion = currentVersion
        self.archiveURL = archiveURL
        self.digest = digest
        self.pageURL = pageURL
    }
}

/// Why a check, download, or verification failed, in the small vocabulary the
/// sheet words. The underlying `UpdateError` keeps the technical detail.
public enum UpdateFailure: Equatable, Sendable {
    case offline
    case timedOut
    case noRelease
    case rateLimited
    case http
    case malformedFeed
    case downloadFailed
    case checksumMismatch
    case invalidDownload
    case insufficientSpace
    case cancelled
    case installFailed
    case notWritable
    case translocated
    case notAnApplication
    case unknown

    /// Failures that happen after the release was found. Retrying one repeats
    /// the download; it does not spend another feed request and risk a `304`
    /// that would hide the release the person is trying to retry.
    public var isDownloadFailure: Bool {
        switch self {
        case .downloadFailed, .checksumMismatch, .invalidDownload, .insufficientSpace, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Failures that leave the verified download ready to try again once the
    /// destination or the system permission has been fixed.
    public var isInstallFailure: Bool {
        switch self {
        case .installFailed, .notWritable, .translocated, .notAnApplication:
            return true
        default:
            return false
        }
    }

    public static func from(_ error: UpdateInstallError) -> UpdateFailure {
        switch error {
        case .notAnApplication:
            return .notAnApplication
        case .translocated:
            return .translocated
        case .destinationNotWritable:
            return .notWritable
        case .stagedAppMissing,
             .recoveryDirectoryUnavailable,
             .couldNotWriteScript,
             .couldNotStartHelper:
            return .installFailed
        }
    }

    public static func from(_ error: UpdateError) -> UpdateFailure {
        switch error {
        case .networkUnavailable:
            return .offline
        case .timedOut:
            return .timedOut
        case .noRelease:
            return .noRelease
        case .rateLimited:
            return .rateLimited
        case .httpStatus, .invalidResponse:
            return .http
        case .malformedRelease, .insecureAsset:
            return .malformedFeed
        case .checksumMismatch:
            return .checksumMismatch
        case .checksumUnreadable,
             .checksumMalformed,
             .checksumNameMismatch,
             .sizeMismatch,
             .archiveMissing,
             .archiveUnreadable,
             .archiveNameMismatch,
             .extractionDirectoryNotEmpty,
             .extractionFailed,
             .bundleMissing,
             .bundleOutsideDestination,
             .invalidBundle,
             .toolFailed:
            return .invalidDownload
        case .insufficientSpace:
            return .insufficientSpace
        case .downloadFailed, .downloadTooLarge:
            return .downloadFailed
        case .cancelled:
            return .cancelled
        case .transport:
            return .unknown
        }
    }
}

/// The sheet's whole state. A value, so the renderer and tests can draw every
/// screen without a network, a controller, or a real release.
public enum UpdateSheetState: Equatable, Sendable {
    case checking
    case upToDate(currentVersion: String)
    case newerThanLatest(currentVersion: String, latestVersion: String)
    case unknownCurrentVersion
    case available(UpdateOffer)
    case downloading(UpdateOffer, DownloadProgress)
    case verifying(UpdateOffer)
    case ready(ReadyUpdate)
    case installing(version: String)
    case noBuildForThisMac(latestVersion: String, pageURL: URL)
    case incompleteRelease(latestVersion: String, pageURL: URL)
    case failed(UpdateFailure, pageURL: URL?, logURL: URL?)
}
