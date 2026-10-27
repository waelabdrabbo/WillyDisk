import Foundation

/// The architecture a release archive was built for.
///
/// The release ships one thin archive per architecture, so the updater must pick
/// the slice that matches the process that is running. Under Rosetta the running
/// slice is `x86_64`, which is the archive that will run there.
public enum ReleaseArchitecture: String, CaseIterable, Sendable {
    case arm64
    case x86_64

    public static var current: ReleaseArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }
}

/// One file attached to a release.
public struct ReleaseAsset: Hashable, Sendable {
    public let name: String
    public let url: URL
    public let byteCount: Int

    public init(name: String, url: URL, byteCount: Int) {
        self.name = name
        self.url = url
        self.byteCount = byteCount
    }
}

/// A stable release, as the feed describes it.
///
/// The version has two forms on purpose: `marketingVersion` is the exact text the
/// publisher used (and therefore the text in the archive name), while `version`
/// is the comparable triple. A release whose tag and assets disagree is not a
/// release this updater can install, so asset lookup uses the marketing text.
public struct UpdateRelease: Hashable, Sendable {
    public let tag: String
    public let marketingVersion: String
    public let version: ReleaseVersion
    public let name: String?
    public let notes: String
    public let pageURL: URL
    public let publishedAt: Date?
    public let assets: [ReleaseAsset]

    public init(
        tag: String,
        marketingVersion: String,
        version: ReleaseVersion,
        name: String?,
        notes: String,
        pageURL: URL,
        publishedAt: Date?,
        assets: [ReleaseAsset]
    ) {
        self.tag = tag
        self.marketingVersion = marketingVersion
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    public func asset(named name: String) -> ReleaseAsset? {
        assets.first { $0.name == name }
    }

    public func archiveName(for architecture: ReleaseArchitecture) -> String {
        "WillyDisk-\(marketingVersion)-\(architecture.rawValue).zip"
    }

    public func checksumName(for architecture: ReleaseArchitecture) -> String {
        archiveName(for: architecture) + ".sha256"
    }

    public func archive(for architecture: ReleaseArchitecture) -> ReleaseAsset? {
        asset(named: archiveName(for: architecture))
    }

    public func checksum(for architecture: ReleaseArchitecture) -> ReleaseAsset? {
        asset(named: checksumName(for: architecture))
    }
}

/// A release that can be downloaded for this Mac, with both files already found.
public struct UpdateCandidate: Equatable, Sendable {
    public let release: UpdateRelease
    public let archive: ReleaseAsset
    public let checksum: ReleaseAsset

    public init(release: UpdateRelease, archive: ReleaseAsset, checksum: ReleaseAsset) {
        self.release = release
        self.archive = archive
        self.checksum = checksum
    }

    public var version: ReleaseVersion { release.version }
    public var marketingVersion: String { release.marketingVersion }
}

/// What comparing the installed version with the feed's latest release found.
public enum UpdateAvailability: Equatable, Sendable {
    /// The running build has no readable marketing version, so no comparison is honest.
    case unknownCurrentVersion
    case upToDate
    /// The running build is newer than the latest published release.
    case newerThanLatest
    case available(UpdateCandidate)
    /// The release exists but carries no archive for this Mac's architecture.
    case noBuildForThisMac
    /// The release is missing a file the updater needs before it can install.
    case incompleteRelease(missing: [String])
}

/// Decides whether a release is newer and which two assets belong to this Mac.
///
/// This is deliberately pure: no network, no filesystem, no preference for a
/// skipped version. Those belong to the controller, which can then be tested
/// separately from the comparison rules.
public struct UpdateEvaluator: Sendable {
    public let currentVersion: ReleaseVersion?
    public let architecture: ReleaseArchitecture

    public init(currentVersion: ReleaseVersion?, architecture: ReleaseArchitecture = .current) {
        self.currentVersion = currentVersion
        self.architecture = architecture
    }

    public func evaluate(_ release: UpdateRelease) -> UpdateAvailability {
        guard let currentVersion else {
            return .unknownCurrentVersion
        }
        if release.version < currentVersion {
            return .newerThanLatest
        }
        if release.version == currentVersion {
            return .upToDate
        }

        guard let archive = release.archive(for: architecture) else {
            return .noBuildForThisMac
        }
        guard let checksum = release.checksum(for: architecture) else {
            return .incompleteRelease(missing: [release.checksumName(for: architecture)])
        }
        return .available(
            UpdateCandidate(release: release, archive: archive, checksum: checksum)
        )
    }
}
