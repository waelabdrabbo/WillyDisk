import Foundation
import CryptoKit
import Observation

/// Files that share a size and are therefore worth checking.
///
/// Same size is not a duplicate: the contents have not been read yet. Only
/// `DuplicateHasher` turns a size group into a content group, and it does so
/// after the person asks for the check.
public struct DuplicateSizeGroup: Identifiable, Equatable, Sendable {
    public let logicalSize: Int64
    public let candidates: [CleanupCandidate]
    /// Every file with this size, including any the group cap left out.
    public let matchCount: Int

    public var id: Int64 { logicalSize }
    public var isTruncated: Bool { matchCount > candidates.count }

    public init(logicalSize: Int64, candidates: [CleanupCandidate], matchCount: Int) {
        self.logicalSize = logicalSize
        self.candidates = candidates
        self.matchCount = matchCount
    }
}

/// Files whose contents matched after their bytes were read.
public struct DuplicateContentGroup: Identifiable, Equatable, Sendable {
    public let digest: String
    public let candidates: [CleanupCandidate]
    public let logicalSize: Int64

    public var id: String { digest }
    /// The bytes the copies occupy together. This is a measurement, not a
    /// promise: moving one copy frees its space only when the Trash is emptied.
    public var totalLogicalSize: Int64 { logicalSize * Int64(candidates.count) }

    public init(digest: String, candidates: [CleanupCandidate], logicalSize: Int64) {
        self.digest = digest
        self.candidates = candidates
        self.logicalSize = logicalSize
    }
}

/// The outcome of comparing the bytes of the size-filtered candidates.
public struct DuplicateReport: Equatable, Sendable {
    /// Only groups with at least two identical files.
    public let groups: [DuplicateContentGroup]
    /// Files that were read and hashed.
    public let comparedFileCount: Int
    /// Files that could not be read, so they are not called duplicates.
    public let unreadableFileCount: Int
    /// Files the check set out to read.
    public let candidateFileCount: Int

    public var isEmpty: Bool { groups.isEmpty }

    public init(
        groups: [DuplicateContentGroup],
        comparedFileCount: Int,
        unreadableFileCount: Int,
        candidateFileCount: Int
    ) {
        self.groups = groups
        self.comparedFileCount = comparedFileCount
        self.unreadableFileCount = unreadableFileCount
        self.candidateFileCount = candidateFileCount
    }
}

/// How far a content check has got. Byte progress is the honest measure here:
/// one large file can take much longer than many small ones.
public struct DuplicateHashProgress: Equatable, Sendable {
    public let processedBytes: Int64
    public let totalBytes: Int64
    public let completedFiles: Int
    public let totalFiles: Int

    public var fraction: Double {
        guard totalBytes > 0 else {
            return totalFiles > 0 && completedFiles == totalFiles ? 1 : 0
        }
        return min(max(Double(processedBytes) / Double(totalBytes), 0), 1)
    }

    public init(
        processedBytes: Int64,
        totalBytes: Int64,
        completedFiles: Int,
        totalFiles: Int
    ) {
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }
}

/// Reads candidate files and groups the ones whose SHA-256 digests match.
///
/// This runs off the main actor and never deletes anything. A file that cannot
/// be read is left out of every group and counted, so a permission failure or a
/// file that moved since the scan can never be called a duplicate. Cancelling
/// returns nil: a partial set of hashes confirms nothing.
public enum DuplicateHasher {
    static let chunkSize = 4 << 20

    public static func check(
        groups: [DuplicateSizeGroup],
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable (DuplicateHashProgress) -> Void = { _ in }
    ) -> DuplicateReport? {
        let candidates = groups.flatMap(\.candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + max(0, $1.logicalSize) }
        let totalFiles = candidates.count
        var processedBytes: Int64 = 0
        var completedFiles = 0
        var unreadable = 0
        var buckets: [String: [CleanupCandidate]] = [:]

        func publish() {
            progress(DuplicateHashProgress(
                processedBytes: min(processedBytes, max(0, totalBytes)),
                totalBytes: max(0, totalBytes),
                completedFiles: completedFiles,
                totalFiles: totalFiles
            ))
        }

        publish()

        for group in groups {
            for candidate in group.candidates {
                if isCancelled() { return nil }
                let expected = max(0, candidate.logicalSize)
                var fileBytes: Int64 = 0

                do {
                    let digest = try hash(fileAt: candidate.url, isCancelled: isCancelled) { bytes in
                        fileBytes += Int64(bytes)
                        processedBytes = min(totalBytes, processedBytes + Int64(bytes))
                        publish()
                    }
                    if let digest {
                        buckets[digest, default: []].append(candidate)
                    } else {
                        return nil
                    }
                } catch {
                    unreadable += 1
                }

                if isCancelled() { return nil }
                completedFiles += 1
                // A short or unreadable file never yields the bytes the scan
                // measured, so move the bar over the work that will not happen.
                if fileBytes < expected {
                    processedBytes = min(totalBytes, processedBytes + (expected - fileBytes))
                }
                publish()
            }
        }

        let confirmed = buckets.compactMap { digest, files -> DuplicateContentGroup? in
            guard files.count >= 2 else { return nil }
            let ordered = files.sorted { $0.url.path < $1.url.path }
            return DuplicateContentGroup(
                digest: digest,
                candidates: ordered,
                logicalSize: ordered.first?.logicalSize ?? 0
            )
        }
        .sorted { lhs, rhs in
            lhs.logicalSize == rhs.logicalSize
                ? lhs.candidates.count > rhs.candidates.count
                : lhs.logicalSize > rhs.logicalSize
        }

        return DuplicateReport(
            groups: confirmed,
            comparedFileCount: buckets.values.reduce(0) { $0 + $1.count },
            unreadableFileCount: unreadable,
            candidateFileCount: totalFiles
        )
    }

    /// Returns nil when the caller cancelled during the read.
    private static func hash(
        fileAt url: URL,
        isCancelled: @Sendable () -> Bool,
        onBytes: (Int) -> Void
    ) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            if isCancelled() { return nil }
            let data = try handle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            onBytes(data.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs one content check and keeps its progress for the sheet.
///
/// The task is cancellable and generation-guarded: a late progress update or a
/// result from a check the person cancelled cannot replace the current state.
@MainActor
@Observable
final class DuplicateCheck {
    enum State: Equatable {
        case idle
        case checking(DuplicateHashProgress)
        case checked(DuplicateReport)
    }

    private(set) var state: State
    private var work: Task<DuplicateReport?, Never>?
    private var watcher: Task<Void, Never>?
    private var generation = 0

    init(preview: DuplicateReport? = nil) {
        state = preview.map(State.checked) ?? .idle
    }

    func start(_ groups: [DuplicateSizeGroup]) {
        guard !groups.isEmpty else { return }
        cancel()

        generation += 1
        let generation = generation
        let candidates = groups.flatMap(\.candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + max(0, $1.logicalSize) }
        state = .checking(DuplicateHashProgress(
            processedBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 0,
            totalFiles: candidates.count
        ))

        // The detached task must not keep the sheet alive, so the only thing it
        // captures from here is this weak progress sink.
        let onProgress: @Sendable (DuplicateHashProgress) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                guard self.generation == generation,
                      case .checking = self.state else { return }
                self.state = .checking(progress)
            }
        }
        let work = Task.detached(priority: .userInitiated) {
            DuplicateHasher.check(
                groups: groups,
                isCancelled: { Task.isCancelled },
                progress: onProgress
            )
        }
        self.work = work
        watcher = Task { [weak self] in
            let report = await work.value
            guard let self, self.generation == generation else { return }
            // Retire this generation before publishing the result, so a late
            // progress update cannot put the view back into `.checking`.
            self.generation += 1
            self.work = nil
            self.watcher = nil
            self.state = report.map(State.checked) ?? .idle
        }
    }

    func cancel() {
        generation += 1
        work?.cancel()
        work = nil
        watcher?.cancel()
        watcher = nil
        state = .idle
    }
}
