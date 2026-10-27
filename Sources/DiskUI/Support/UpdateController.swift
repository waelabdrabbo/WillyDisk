import Foundation
import Observation
import DiskUpdate

/// A download that passed the checksum, extraction, and bundle checks.
public struct VerifiedUpdate: Sendable {
    public let digest: String
    public let bundleURL: URL

    public init(digest: String, bundleURL: URL) {
        self.digest = digest
        self.bundleURL = bundleURL
    }
}

/// The verification seam. The app's implementation is synchronous filesystem work
/// run off the main actor; tests substitute a value so the controller can be
/// exercised without building a signed app bundle.
public protocol UpdateVerifying: Sendable {
    func verify(
        candidate: UpdateCandidate,
        archive: URL,
        checksumFile: URL,
        expandedDirectory: URL
    ) async throws -> VerifiedUpdate
}

/// Runs the real checks from `DiskUpdate` on a background task.
public struct AppUpdateVerifier: UpdateVerifying {
    private let build: InstalledBuild

    public init(build: InstalledBuild) {
        self.build = build
    }

    public func verify(
        candidate: UpdateCandidate,
        archive: URL,
        checksumFile: URL,
        expandedDirectory: URL
    ) async throws -> VerifiedUpdate {
        let verifier = UpdateVerifier(
            expectedBundleIdentifier: build.bundleIdentifier,
            expectedMarketingVersion: candidate.marketingVersion,
            architecture: build.architecture,
            operatingSystemVersion: build.operatingSystemVersion
        )

        return try await Task.detached(priority: .userInitiated) {
            let digest = try verifier.verify(
                archive: archive,
                checksumFile: checksumFile,
                expectedArchiveName: candidate.archive.name,
                expectedByteCount: candidate.archive.byteCount
            )
            let bundle = try verifier.extract(archive: archive, into: expandedDirectory)
            try verifier.validate(bundleAt: bundle)
            return VerifiedUpdate(digest: digest.hex, bundleURL: bundle)
        }.value
    }
}

/// Owns the update flow: the feed, the download, the verification, and the final
/// replace-and-relaunch handoff. The controller never writes into the running app
/// itself; it starts `UpdateInstaller`'s helper and asks the view to quit.
@MainActor
@Observable
public final class UpdateController {
    public private(set) var state: UpdateSheetState = .checking
    public let preferences: UpdatePreferences

    private let feed: any ReleaseFeed
    private let downloader: any UpdateDownloading
    private let verifier: (any UpdateVerifying)?
    private let installer: (any UpdateInstalling)?
    private let storage: UpdateStorage
    private let build: InstalledBuild?
    private let now: @Sendable () -> Date

    private var candidate: UpdateCandidate?
    private var lastReady: ReadyUpdate?
    private var stagedApp: URL?
    private var isChecking = false

    public init(
        feed: any ReleaseFeed,
        downloader: any UpdateDownloading,
        verifier: (any UpdateVerifying)? = nil,
        installer: (any UpdateInstalling)? = nil,
        preferences: UpdatePreferences,
        build: InstalledBuild?,
        storage: UpdateStorage = UpdateStorage(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.feed = feed
        self.downloader = downloader
        self.verifier = verifier
        self.installer = installer
        self.preferences = preferences
        self.build = build
        self.storage = storage
        self.now = now
    }

    /// The launch path: one request at most every 24 hours, and only while the
    /// preference is on.
    public func checkIfDue() async {
        guard preferences.checksAutomatically,
              preferences.shouldCheck(now: now()) else {
            return
        }
        await check(manual: false)
    }

    public func check(manual: Bool) async {
        guard !isChecking, !isBusy else { return }
        guard let build else {
            state = .unknownCurrentVersion
            return
        }

        isChecking = true
        candidate = nil
        lastReady = nil
        stagedApp = nil
        state = .checking
        defer { isChecking = false }

        do {
            // No If-None-Match: a `304` says the release list has not changed
            // since an earlier check, not that the installed app is current. A
            // process that did not keep the release cannot turn that into an
            // offer, and a small daily GET is within the unauthenticated limit.
            let result = try await feed.latestRelease(ifNoneMatch: nil)
            switch result {
            case .notModified:
                preferences.recordAttempt(at: now())
                state = .failed(.unknown, pageURL: nil, logURL: nil)

            case let .release(release, _):
                preferences.recordSuccess(at: now())
                let evaluator = UpdateEvaluator(
                    currentVersion: build.version,
                    architecture: build.architecture
                )
                switch evaluator.evaluate(release) {
                case .unknownCurrentVersion:
                    state = .unknownCurrentVersion
                case .upToDate:
                    state = .upToDate(currentVersion: build.marketingVersion)
                case .newerThanLatest:
                    state = .newerThanLatest(
                        currentVersion: build.marketingVersion,
                        latestVersion: release.marketingVersion
                    )
                case .noBuildForThisMac:
                    state = .noBuildForThisMac(
                        latestVersion: release.marketingVersion,
                        pageURL: release.pageURL
                    )
                case .incompleteRelease:
                    state = .incompleteRelease(
                        latestVersion: release.marketingVersion,
                        pageURL: release.pageURL
                    )
                case let .available(candidate):
                    if !manual, preferences.isSkipped(candidate.version) {
                        state = .upToDate(currentVersion: build.marketingVersion)
                    } else {
                        self.candidate = candidate
                        state = .available(
                            Self.offer(for: candidate, currentVersion: build.marketingVersion)
                        )
                    }
                }
            }
        } catch {
            preferences.recordAttempt(at: now())
            state = .failed(
                UpdateFailure.from(error as? UpdateError ?? .transport),
                pageURL: nil,
                logURL: nil
            )
        }
    }

    /// Downloads both assets and runs the verification. Cancelling the task the
    /// view holds calls this method's cancellation handler and returns the sheet
    /// to the offer.
    public func download() async {
        guard case let .available(offer) = state,
              let candidate,
              let build,
              let verifier else {
            return
        }

        state = .downloading(offer, .zero)
        let version = candidate.marketingVersion
        var verifying = false
        lastReady = nil
        stagedApp = nil

        let storage = self.storage
        do {
            let directory = try await Task.detached(priority: .utility) {
                try storage.prepare(version: version)
            }.value

            let free = await Task.detached(priority: .utility) {
                storage.freeSpace(at: directory)
            }.value
            if let free,
               free < storage.requiredBytes(forDownloadBytes: candidate.archive.byteCount) {
                throw UpdateError.insufficientSpace
            }

            let archiveURL = directory.appendingPathComponent(candidate.archive.name)
            let checksumURL = directory.appendingPathComponent(candidate.checksum.name)

            try await downloader.download(
                from: candidate.archive.url,
                to: archiveURL
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.report(progress, for: offer)
                }
            }

            try await downloader.download(
                from: candidate.checksum.url,
                to: checksumURL
            ) { _ in }

            try Task.checkCancellation()
            state = .verifying(offer)
            verifying = true

            let expanded = directory.appendingPathComponent("expanded", isDirectory: true)
            let verified = try await verifier.verify(
                candidate: candidate,
                archive: archiveURL,
                checksumFile: checksumURL,
                expandedDirectory: expanded
            )
            try Task.checkCancellation()

            let ready = ReadyUpdate(
                version: candidate.marketingVersion,
                currentVersion: build.marketingVersion,
                archiveURL: archiveURL,
                digest: verified.digest,
                pageURL: candidate.release.pageURL
            )
            lastReady = ready
            stagedApp = verified.bundleURL
            state = .ready(ready)
        } catch {
            await Task.detached(priority: .utility) {
                storage.discard(version: version)
            }.value

            if error is CancellationError
                || (error as? UpdateError) == .cancelled
                || Task.isCancelled {
                state = .available(offer)
            } else if verifying {
                let updateError = (error as? UpdateError)
                    ?? .invalidBundle(.signatureInvalid)
                state = .failed(
                    UpdateFailure.from(updateError),
                    pageURL: candidate.release.pageURL,
                    logURL: nil
                )
            } else {
                // A network or HTTP failure while fetching an asset is a
                // download failure, not a check failure: retrying it must reuse
                // the candidate rather than ask the feed again.
                let updateError = (error as? UpdateError) ?? .downloadFailed
                let failure: UpdateFailure
                if case .insufficientSpace = updateError {
                    failure = .insufficientSpace
                } else {
                    failure = .downloadFailed
                }
                state = .failed(
                    failure,
                    pageURL: candidate.release.pageURL,
                    logURL: nil
                )
            }
        }
    }

    /// Starts the detached helper. Returns `true` when the helper is running and
    /// the caller should quit; `false` means the sheet has a failure to show and
    /// the app must stay open.
    public func install() async -> Bool {
        guard case let .ready(ready) = state, let installer else {
            return false
        }
        lastReady = ready
        let target = Bundle.main.bundleURL

        let staging = ready.archiveURL.deletingLastPathComponent()
        let request = UpdateInstallRequest(
            targetApp: target,
            stagedApp: stagedApp
                ?? staging.appendingPathComponent("expanded/WillyDisk.app", isDirectory: true),
            recoveryDirectory: storage.recoveryDirectory(for: ready.version),
            resultURL: storage.resultURL,
            version: ready.version,
            parentPID: ProcessInfo.processInfo.processIdentifier,
            relaunch: true
        )

        state = .installing(version: ready.version)
        do {
            // Spawning the helper and the destination checks are file and process
            // work; keep them off the main actor.
            try await Task.detached(priority: .userInitiated) {
                try installer.validateDestination(for: target)
                try installer.install(request)
            }.value
            return true
        } catch let error as UpdateInstallError {
            state = .failed(
                UpdateFailure.from(error),
                pageURL: nil,
                logURL: nil
            )
            return false
        } catch {
            state = .failed(.installFailed, pageURL: nil, logURL: nil)
            return false
        }
    }

    /// Reads the helper's result on the next launch. A failure is put in the
    /// sheet and returns `true` so the app can present it before any automatic
    /// check; a success cleans the staging archive and returns `false`.
    @discardableResult
    public func consumeInstallResult() async -> Bool {
        let storage = self.storage
        guard let installer,
              let outcome = installer.consumeResult(at: storage.resultURL) else {
            return false
        }
        let recovery = storage.recoveryDirectory(for: outcome.version)

        switch outcome.status {
        case .installed:
            if outcome.version == build?.marketingVersion {
                await Task.detached(priority: .utility) {
                    storage.discard(version: outcome.version)
                }.value
            }
            lastReady = nil
            stagedApp = nil
            return false
        case .failed:
            lastReady = nil
            stagedApp = nil
            state = .failed(
                .installFailed,
                pageURL: nil,
                logURL: recovery.appendingPathComponent("install.log")
            )
            return true
        }
    }

    public func skip() {
        guard case let .available(offer) = state, let candidate else { return }
        preferences.skip(candidate.version)
        self.candidate = nil
        state = .upToDate(currentVersion: offer.currentVersion)
    }

    /// Retries whatever failed. An install failure returns to the verified
    /// download; a download or verification failure reuses the candidate already
    /// found, so a retry cannot be answered with `304 Not Modified` and strand
    /// the person on a release they were just offered. A check failure asks the
    /// feed again.
    public func retry() async {
        guard case let .failed(failure, _, _) = state else { return }
        if failure.isInstallFailure, let lastReady {
            state = .ready(lastReady)
            return
        }
        if failure.isDownloadFailure, let candidate, let build {
            state = .available(
                Self.offer(for: candidate, currentVersion: build.marketingVersion)
            )
            await download()
        } else {
            await check(manual: true)
        }
    }

    private var isBusy: Bool {
        switch state {
        case .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }

    private func report(_ progress: DownloadProgress, for offer: UpdateOffer) {
        guard case let .downloading(current, _) = state,
              current.version == offer.version else {
            return
        }
        state = .downloading(current, progress)
    }

    private static func offer(
        for candidate: UpdateCandidate,
        currentVersion: String
    ) -> UpdateOffer {
        UpdateOffer(
            version: candidate.marketingVersion,
            currentVersion: currentVersion,
            notes: candidate.release.notes,
            downloadBytes: candidate.archive.byteCount,
            pageURL: candidate.release.pageURL,
            releaseTitle: candidate.release.name
        )
    }
}
