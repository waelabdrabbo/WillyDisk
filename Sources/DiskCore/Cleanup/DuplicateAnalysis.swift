import Foundation
import Darwin
import CryptoKit

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
    /// The bytes one copy occupies on disk, read from the copy that is shown: a
    /// sparse or a compressed copy can occupy less than its logical size.
    public var localSize: Int64 { candidates.first?.allocatedSize ?? 0 }
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
    /// Files whose contents were read and compared.
    public let comparedFileCount: Int
    /// Files that could not be read, so they are not called duplicates.
    public let unreadableFileCount: Int
    /// Paths that resolve to a file already compared: the same bytes under
    /// another name. They are not copies, so they are never offered as
    /// duplicates, and moving one frees nothing while another path remains.
    public let hardLinkFileCount: Int
    /// Paths that share their blocks with another file — an APFS clone. Moving
    /// one frees nothing until the other references go, so a clone is never
    /// offered as a second copy.
    public let cloneFileCount: Int
    /// Files the check set out to read.
    public let candidateFileCount: Int

    public var isEmpty: Bool { groups.isEmpty }

    public init(
        groups: [DuplicateContentGroup],
        comparedFileCount: Int,
        unreadableFileCount: Int,
        hardLinkFileCount: Int = 0,
        cloneFileCount: Int = 0,
        candidateFileCount: Int
    ) {
        self.groups = groups
        self.comparedFileCount = comparedFileCount
        self.unreadableFileCount = unreadableFileCount
        self.hardLinkFileCount = hardLinkFileCount
        self.cloneFileCount = cloneFileCount
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
/// This runs off the main actor and never deletes anything. It reads the first
/// `prefixSize` bytes of every candidate first: a size match and a matching
/// prefix is what earns a full read, so most false pairs cost a few kilobytes
/// rather than their whole size. Files are read a few at a time, and a file that
/// cannot be read is left out of every group and counted, so a permission
/// failure or a file that moved since the scan can never be called a duplicate.
///
/// A path that resolves to a file already read is a hard link, and a path whose
/// blocks are shared with another file is a clone: neither is a copy, so neither
/// is read twice or offered as a duplicate. Cancelling returns nil: a partial
/// set of hashes confirms nothing.
public enum DuplicateHasher {
    static let chunkSize = 4 << 20
    /// How much of a file is compared before the whole read.
    static let prefixSize = 128 * 1024

    public static func check(
        groups: [DuplicateSizeGroup],
        isCancelled: @Sendable () -> Bool = { false },
        progress: @Sendable @escaping (DuplicateHashProgress) -> Void = { _ in }
    ) -> DuplicateReport? {
        let candidates = groups.flatMap(\.candidates)
        let totalBytes = candidates.reduce(Int64(0)) { $0 + max(0, $1.logicalSize) }
        let tracker = ProgressTracker(
            totalBytes: totalBytes,
            totalFiles: candidates.count,
            publish: progress
        )
        tracker.start()
        guard !candidates.isEmpty else {
            tracker.complete()
            return DuplicateReport(
                groups: [],
                comparedFileCount: 0,
                unreadableFileCount: 0,
                hardLinkFileCount: 0,
                cloneFileCount: 0,
                candidateFileCount: 0
            )
        }

        // Count references first. A path that is one of several links to the
        // same file frees nothing on its own, so none of them is offered, and a
        // path whose blocks are shared with another file is the same promise.
        var inodeCounts: [InodeKey: Int] = [:]
        var inodes: [InodeKey?] = []
        inodes.reserveCapacity(candidates.count)
        for candidate in candidates {
            if isCancelled() { return nil }
            let inode = inodeKey(fileAt: candidate.url)
            inodes.append(inode)
            if let inode { inodeCounts[inode, default: 0] += 1 }
        }

        var subjects: [CleanupCandidate] = []
        var hardLinks = 0
        var clones = 0
        for (offset, candidate) in candidates.enumerated() {
            if isCancelled() { return nil }
            if let inode = inodes[offset], inodeCounts[inode, default: 0] > 1 {
                hardLinks += 1
                tracker.finishFile(expected: candidate.logicalSize, alreadyCounted: 0)
                continue
            }
            if let references = cloneReferenceCount(fileAt: candidate.url), references > 1 {
                clones += 1
                tracker.finishFile(expected: candidate.logicalSize, alreadyCounted: 0)
                continue
            }
            subjects.append(candidate)
        }

        // Prefix pass.
        let prefixes = ParallelResults<PrefixOutcome>(count: subjects.count)
        DispatchQueue.concurrentPerform(iterations: subjects.count) { index in
            if isCancelled() {
                prefixes.set(.cancelled, at: index)
                return
            }
            let candidate = subjects[index]
            do {
                if let result = try hashPrefix(fileAt: candidate.url, size: candidate.logicalSize, isCancelled: isCancelled) {
                    prefixes.set(.digest(result.digest, complete: result.complete), at: index)
                } else {
                    prefixes.set(.cancelled, at: index)
                }
            } catch {
                prefixes.set(.unreadable, at: index)
            }
        }
        if isCancelled() { return nil }

        // Only a prefix another file shares is worth the whole read.
        var needsFull = [Bool](repeating: false, count: subjects.count)
        var buckets: [PrefixKey: [Int]] = [:]
        for index in subjects.indices {
            guard case .digest(let digest, _)? = prefixes.value(at: index) else { continue }
            let key = PrefixKey(size: subjects[index].logicalSize, prefix: digest)
            buckets[key, default: []].append(index)
        }
        for indices in buckets.values where indices.count >= 2 {
            for index in indices { needsFull[index] = true }
        }

        // Full pass.
        let fulls = ParallelResults<FullOutcome>(count: subjects.count)
        let toHash = needsFull.indices.filter { needsFull[$0] }
        DispatchQueue.concurrentPerform(iterations: toHash.count) { position in
            let index = toHash[position]
            let candidate = subjects[index]
            let expected = candidate.logicalSize
            guard case .digest(let prefix, let complete)? = prefixes.value(at: index) else {
                fulls.set(.unreadable, at: index)
                tracker.finishFile(expected: expected, alreadyCounted: 0)
                return
            }
            if complete {
                fulls.set(.digest(prefix), at: index)
                tracker.finishFile(expected: expected, alreadyCounted: 0)
                return
            }
            if isCancelled() {
                fulls.set(.cancelled, at: index)
                tracker.finishFile(expected: expected, alreadyCounted: 0)
                return
            }

            var counted: Int64 = 0
            do {
                if let digest = try hashWhole(fileAt: candidate.url, isCancelled: isCancelled, onBytes: { bytes in
                    counted += Int64(bytes)
                    tracker.add(bytes: Int64(bytes))
                }) {
                    fulls.set(.digest(digest), at: index)
                } else {
                    fulls.set(.cancelled, at: index)
                }
            } catch {
                fulls.set(.unreadable, at: index)
            }
            tracker.finishFile(expected: expected, alreadyCounted: counted)
        }
        if isCancelled() { return nil }

        var unreadable = 0
        var grouped: [String: [CleanupCandidate]] = [:]
        for index in subjects.indices {
            let candidate = subjects[index]
            if !needsFull[index] {
                tracker.finishFile(expected: candidate.logicalSize, alreadyCounted: 0)
            }

            if needsFull[index] {
                switch fulls.value(at: index) {
                case .digest(let digest):
                    grouped[digest, default: []].append(candidate)
                case .unreadable, nil:
                    unreadable += 1
                case .cancelled:
                    return nil
                }
            } else {
                switch prefixes.value(at: index) {
                case .digest(let digest, _):
                    grouped[digest, default: []].append(candidate)
                case .unreadable, nil:
                    unreadable += 1
                case .cancelled:
                    return nil
                }
            }
        }
        tracker.complete()

        let confirmed = grouped.compactMap { digest, files -> DuplicateContentGroup? in
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
            comparedFileCount: grouped.values.reduce(0) { $0 + $1.count },
            unreadableFileCount: unreadable,
            hardLinkFileCount: hardLinks,
            cloneFileCount: clones,
            candidateFileCount: candidates.count
        )
    }

    // MARK: - Reading

    /// A file's identity on its volume, which is what tells a hard link from a
    /// copy with the same bytes.
    private struct InodeKey: Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct PrefixKey: Hashable {
        let size: Int64
        let prefix: String
    }

    private enum PrefixOutcome {
        case digest(String, complete: Bool)
        case unreadable
        case cancelled
    }

    private enum FullOutcome {
        case digest(String)
        case unreadable
        case cancelled
    }

    /// The file's device and inode, or nil when it cannot be reached. `stat`
    /// follows a link, matching what the read would open.
    private static func inodeKey(fileAt url: URL) -> InodeKey? {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return stat(path, &info)
        }
        guard status == 0 else { return nil }
        return InodeKey(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// How many references share this file's blocks, or nil when the volume
    /// cannot say. `2` or more is an APFS clone.
    private static func cloneReferenceCount(fileAt url: URL) -> Int? {
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attributes.forkattr = attrgroup_t(ATTR_CMNEXT_CLONE_REFCNT)
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return getattrlist(path, &attributes, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> Int? in
            // The returned attribute set is 20 bytes; the extended attribute
            // follows as its mask and then its value.
            guard raw.count >= 28,
                  raw.load(fromByteOffset: 20, as: UInt32.self) == UInt32(ATTR_CMNEXT_CLONE_REFCNT)
            else { return nil }
            return Int(raw.load(fromByteOffset: 24, as: UInt32.self))
        }
    }

    /// Returns nil when the caller cancelled during the read.
    private static func hashPrefix(
        fileAt url: URL,
        size: Int64,
        isCancelled: @Sendable () -> Bool
    ) throws -> (digest: String, complete: Bool)? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var read = 0
        while read < prefixSize {
            if isCancelled() { return nil }
            let remaining = prefixSize - read
            let data = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
            read += data.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, Int64(read) >= size)
    }

    /// Returns nil when the caller cancelled during the read.
    private static func hashWhole(
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

/// Collects per-file results written from concurrent reads.
private final class ParallelResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value?]

    init(count: Int) {
        values = Array(repeating: nil, count: count)
    }

    func set(_ value: Value, at index: Int) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func value(at index: Int) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return values[index]
    }
}

/// Aggregates byte and file progress from the concurrent reads.
///
/// Updates are throttled: a read that reports every chunk would otherwise wake
/// the main actor hundreds of times a second for a bar nobody can read.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let totalFiles: Int
    private let publish: @Sendable (DuplicateHashProgress) -> Void
    private var processedBytes: Int64 = 0
    private var completedFiles = 0
    private var lastPublish = DispatchTime.now()

    init(
        totalBytes: Int64,
        totalFiles: Int,
        publish: @escaping @Sendable (DuplicateHashProgress) -> Void
    ) {
        self.totalBytes = max(0, totalBytes)
        self.totalFiles = max(0, totalFiles)
        self.publish = publish
    }

    func start() {
        publish(DuplicateHashProgress(
            processedBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 0,
            totalFiles: totalFiles
        ))
    }

    func add(bytes: Int64) {
        update(bytes: bytes, completed: 0, force: false)
    }

    func finishFile(expected: Int64, alreadyCounted: Int64) {
        update(bytes: max(0, expected - alreadyCounted), completed: 1, force: false)
    }

    func complete() {
        update(bytes: 0, completed: 0, force: true)
    }

    private func update(bytes: Int64, completed: Int, force: Bool) {
        lock.lock()
        processedBytes = min(totalBytes, processedBytes + max(0, bytes))
        completedFiles = min(totalFiles, completedFiles + max(0, completed))
        let now = DispatchTime.now()
        let due = force
            || completedFiles == totalFiles
            || now.uptimeNanoseconds - lastPublish.uptimeNanoseconds > 50_000_000
        var snapshot: DuplicateHashProgress?
        if due {
            lastPublish = now
            if force {
                processedBytes = totalBytes
                completedFiles = totalFiles
            }
            snapshot = DuplicateHashProgress(
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                completedFiles: completedFiles,
                totalFiles: totalFiles
            )
        }
        lock.unlock()
        if let snapshot { publish(snapshot) }
    }
}
