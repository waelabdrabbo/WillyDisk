import Foundation
import Darwin
import os

/// The filesystem operations the traversal depends on. Production uses
/// `.live`; tests can inject a model to exercise denial paths that the host
/// machine cannot reproduce with POSIX modes.
///
/// `makeDirectoryReader` returns a reader whose enumeration carries each child's
/// metadata, because a bulk directory read (`getattrlistbulk`) already has it.
/// Reading the directory and then asking `lstat` for every entry doubles the
/// syscall load for no extra information. A reader may own scratch space, so the
/// traversal asks for one per worker.
struct FileSystemAccess: Sendable {
    var lstat: @Sendable (String) -> FileStat
    var statFollowing: @Sendable (String) -> FileStat
    var makeDirectoryReader: @Sendable () -> any DirectoryReading
    var resolvedPath: @Sendable (String) -> String

    static var live: FileSystemAccess {
        FileSystemAccess(
            lstat: { FileStat.lstat($0) },
            statFollowing: { FileStat.statFollowing($0) },
            makeDirectoryReader: { DirectoryReader() },
            resolvedPath: {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
    }
}

/// Iterative-by-recursion filesystem traversal that builds the frozen `ScanNode`
/// tree and emits `ScanEvent`s.
///
/// ## Concurrency
///
/// A scan is dominated by waiting on the filesystem, so the traversal fans out
/// across a bounded pool of concurrent workers: one task per subdirectory, with
/// directory *reads* limited to `concurrency` at a time. The limit is held only
/// while a directory is being read — never while a task waits for its children —
/// so a saturated pool can always make progress and cannot deadlock.
///
/// Work is off the caller's actor: `FileScanEngine` always drives `run` from a
/// `Task.detached`. Recursion is used instead of an explicit stack because an
/// async frame lives on the heap, so hierarchy depth cannot overflow the stack.
///
/// ## Truthfulness
///
/// Totals are accumulated once per entry into a single lock-protected state, and
/// the same state produces every `.partial` snapshot and the terminal summary, so
/// a snapshot can never disagree with the final result. A directory is claimed by
/// exactly one worker before it is walked, so a subtree reachable under two paths
/// (firmlinks, directory hard links) is counted once.
enum FileScanner {

    /// Number of entries kept in `ScanSummary.largestFiles` / `.largestDirectories`.
    static let largestCapacity = 100

    /// Maximum number of issue events surfaced to a consumer. Counts in the
    /// summary stay uncapped; this bounds only the per-path detail stream so a
    /// scan of hundreds of protected locations cannot flood the UI.
    static let maxSurfacedIssues = 50

    /// How many directory reads may be in flight at once.
    ///
    /// The bound keeps a wide tree from launching thousands of concurrent reads
    /// (and the threads behind them) while still overlapping enough filesystem
    /// waits to matter.
    static var defaultConcurrency: Int {
        max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    }

    /// Throttle governing the non-terminal `.partial` snapshot stream.
    ///
    /// A full-disk scan touches hundreds of thousands of entries, so a snapshot
    /// is taken only once enough new work has accumulated: either the wall-clock
    /// `interval` has elapsed or `workThreshold` completed work units have been
    /// observed. Snapshots are value copies of the accumulators, never deep
    /// copies of the tree, so they stay cheap and never slow the traversal.
    struct SnapshotCadence {
        /// Minimum wall-clock spacing between snapshots. Zero disables the
        /// time-based trigger, leaving the work threshold as the only gate.
        var interval: TimeInterval
        /// Minimum completed work units (entries visited plus directories
        /// finalized) before another snapshot is taken.
        var workThreshold: Int

        /// Snapshot at most four times a second, or every 4096 completed units.
        static let production = SnapshotCadence(interval: 0.25, workThreshold: 4096)
        /// Snapshot after every completed work unit — deterministic, for tests.
        static let everyWorkUnit = SnapshotCadence(interval: 0, workThreshold: 1)
    }

    /// Minimum wall-clock spacing between `.progress` events.
    private static let progressInterval: TimeInterval = 0.05

    /// Completed work units between wall-clock samples. The clock only gates the
    /// time-based cadence, so sampling it per entry would add cost for nothing.
    private static let clockCheckInterval = 64

    // MARK: - Entry point

    static func run(
        request: ScanRequest,
        access: FileSystemAccess = .live,
        cadence: SnapshotCadence = .production,
        concurrency: Int = FileScanner.defaultConcurrency,
        emit: @escaping @Sendable (ScanEvent) -> Void
    ) async {
        let startDate = Date()
        let rootPath = request.root.path
        let rootName = nodeName(for: request.root, path: rootPath)

        let rootStat = access.lstat(rootPath)
        guard rootStat.error == 0 else {
            let kind = ScanErrorClassifier.kind(errno: rootStat.error)
            let denied = kind == .permissionDenied
            emit(.issue(kind: kind, path: rootPath, message: "Cannot access: \(errnoText(rootStat.error))"))
            emit(.finished(ScanSummary(
                root: request.root,
                totalLogicalSize: 0, totalAllocatedSize: 0,
                fileCount: 0, directoryCount: 0,
                inaccessibleCount: denied ? 1 : 0, errorCount: 1,
                permissionDeniedCount: denied ? 1 : 0, surfacedIssueCount: 1,
                startedAt: startDate, finishedAt: Date(),
                categoryBreakdown: [:], largestFiles: [], largestDirectories: []
            )))
            return
        }

        emit(.started(root: request.root))

        // A scan root that is itself a symbolic link: `lstat` reports the link, so
        // decide explicitly whether to follow it, and surface a broken target
        // instead of dropping the entry. A broken link is a non-fatal issue even
        // when links are not followed — there is no target to follow.
        var scanStat = rootStat
        let rootIsSymlink = rootStat.isSymlink
        if rootIsSymlink {
            let target = access.statFollowing(rootPath)
            guard target.error == 0 else {
                emit(.issue(
                    kind: .brokenSymlink,
                    path: rootPath,
                    message: "Broken symlink: \(errnoText(target.error))"
                ))
                emit(.finished(ScanSummary(
                    root: request.root,
                    totalLogicalSize: 0, totalAllocatedSize: 0,
                    fileCount: 0, directoryCount: 0,
                    inaccessibleCount: 0, errorCount: 1,
                    permissionDeniedCount: 0, surfacedIssueCount: 1,
                    startedAt: startDate, finishedAt: Date(),
                    categoryBreakdown: [:],
                    largestFiles: [rootSymlinkNode(name: rootName, path: rootPath, stat: rootStat, broken: true)],
                    largestDirectories: []
                )))
                return
            }
            guard request.followSymlinks else {
                // Default safe behavior: represent the link as a zero-sized leaf,
                // never follow it into the target.
                emit(.finished(ScanSummary(
                    root: request.root,
                    totalLogicalSize: 0, totalAllocatedSize: 0,
                    fileCount: 0, directoryCount: 0, inaccessibleCount: 0, errorCount: 0,
                    permissionDeniedCount: 0, surfacedIssueCount: 0,
                    startedAt: startDate, finishedAt: Date(),
                    categoryBreakdown: [:],
                    largestFiles: [rootSymlinkNode(name: rootName, path: rootPath, stat: rootStat, broken: false)],
                    largestDirectories: []
                )))
                return
            }
            scanStat = target
        }

        // A file (or a followed symlink to one) was selected rather than a folder.
        guard scanStat.isDirectory else {
            if scanStat.isRegularFile {
                let category = FileCategorizer.category(name: rootName, isDirectory: false)
                let node = ScanNode(
                    id: UUID(), url: request.root, name: rootName,
                    isDirectory: false, isSymlink: rootIsSymlink, category: category,
                    logicalSize: scanStat.size, allocatedSize: scanStat.allocatedSize,
                    fileCount: 1, directoryCount: 0,
                    modifiedAt: scanStat.modifiedAt, isAccessible: true, errorMessage: nil, children: []
                )
                emit(.finished(ScanSummary(
                    root: request.root,
                    totalLogicalSize: scanStat.size, totalAllocatedSize: scanStat.allocatedSize,
                    fileCount: 1, directoryCount: 0, inaccessibleCount: 0, errorCount: 0,
                    permissionDeniedCount: 0, surfacedIssueCount: 0,
                    startedAt: startDate, finishedAt: Date(),
                    categoryBreakdown: [category: scanStat.size],
                    largestFiles: [node], largestDirectories: []
                )))
            } else {
                // A special entry (device, FIFO, socket) is skipped safely.
                emit(.finished(ScanSummary(
                    root: request.root,
                    totalLogicalSize: 0, totalAllocatedSize: 0,
                    fileCount: 0, directoryCount: 0, inaccessibleCount: 0, errorCount: 0,
                    permissionDeniedCount: 0, surfacedIssueCount: 0,
                    startedAt: startDate, finishedAt: Date(),
                    categoryBreakdown: [:], largestFiles: [], largestDirectories: []
                )))
            }
            return
        }

        let context = ScanContext(
            request: request,
            access: access,
            cadence: cadence,
            concurrency: concurrency,
            rootStat: scanStat,
            rootResolvedPath: access.resolvedPath(rootPath),
            startDate: startDate,
            emit: emit
        )

        _ = await context.scanDirectory(path: rootPath, name: rootName, isSymlink: rootIsSymlink, stat: scanStat)

        if context.isCancelled {
            emit(.cancelled(partial: context.summary(finishedAt: Date())))
            return
        }
        if context.workUnits > 0 {
            emit(.progress(context.progress(finishedAt: Date())))
        }
        emit(.finished(context.summary(finishedAt: Date())))
    }

    // MARK: - Small helpers

    private static func nodeName(for url: URL, path: String) -> String {
        let last = url.lastPathComponent
        return last.isEmpty ? path : last
    }

    private static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func joinedPath(dir: String, name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// Builds a node URL without touching the filesystem.
    ///
    /// `URL(fileURLWithPath:)` asks `lstat` whether the path is a directory, so
    /// using it for every entry re-adds exactly the per-entry syscall that bulk
    /// enumeration removed. The caller already knows the kind of the entry, so it
    /// passes the answer instead of paying for the probe.
    private static func nodeURL(_ path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    /// A leaf node for a scan root that is a symbolic link. A broken link carries
    /// its `errorMessage`; otherwise the node is the same zero-sized leaf used for
    /// symlinks that are not followed.
    private static func rootSymlinkNode(name: String, path: String, stat: FileStat, broken: Bool) -> ScanNode {
        ScanNode(
            id: UUID(), url: nodeURL(path, isDirectory: false), name: name,
            isDirectory: false, isSymlink: true, category: .other,
            logicalSize: 0, allocatedSize: 0, fileCount: 0, directoryCount: 0,
            modifiedAt: stat.modifiedAt, isAccessible: true,
            errorMessage: broken ? "Broken symlink" : nil, children: []
        )
    }

    // MARK: - Directory identity

    private struct DirKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    // MARK: - Bounded-size ranking

    private struct TopN {
        let capacity: Int
        private var items: [ScanNode] = []
        /// Smallest size currently held. A candidate at or below it cannot make
        /// the list, so the overwhelmingly common case costs one comparison
        /// instead of a scan of the whole list.
        private var smallest = Int64.min

        init(capacity: Int) {
            self.capacity = max(capacity, 1)
        }

        mutating func add(_ node: ScanNode) {
            if items.count < capacity {
                items.append(node)
                if items.count == capacity { recomputeSmallest() }
                return
            }
            guard node.logicalSize > smallest else { return }
            var minIndex = 0
            for i in 1..<items.count where items[i].logicalSize < items[minIndex].logicalSize {
                minIndex = i
            }
            items[minIndex] = node
            recomputeSmallest()
        }

        private mutating func recomputeSmallest() {
            var value = items[0].logicalSize
            for item in items where item.logicalSize < value { value = item.logicalSize }
            smallest = value
        }

        func sortedDescending() -> [ScanNode] {
            items.sorted { $0.logicalSize > $1.logicalSize }
        }
    }

    // MARK: - Shared accumulator

    /// Everything the scan accumulates, guarded by one lock.
    ///
    /// Emission happens inside the lock so snapshots reach the consumer in the
    /// same order the state was produced — a snapshot can then never appear to
    /// shrink because two workers raced to report it.
    private struct WalkState {
        var visitedDirs: Set<DirKey> = []
        var totalFiles = 0
        var totalDirs = 0
        var totalLogical: Int64 = 0
        var totalAllocated: Int64 = 0
        var inaccessibleCount = 0
        var errorCount = 0
        var permissionDeniedCount = 0
        var surfacedIssueCount = 0
        var categoryBreakdown: [FileCategory: Int64] = [:]
        var largestFiles = TopN(capacity: FileScanner.largestCapacity)
        var largestDirectories = TopN(capacity: FileScanner.largestCapacity)
        var currentPath = ""
        var workSinceSnapshot = 0
        var cancelled = false
        var lastProgressAt: Date
        var lastSnapshotAt: Date
    }

    /// A subdirectory handed to a worker: its path, the name to report, and the
    /// metadata the bulk read already produced.
    private struct PendingDirectory {
        let path: String
        let name: String
        let isSymlink: Bool
        let stat: FileStat
    }

    /// What a followed symlink turned into.
    private enum SymlinkOutcome {
        case child(ScanNode)
        case directory(PendingDirectory)
    }

    // MARK: - Scan context

    private final class ScanContext: @unchecked Sendable {
        let request: ScanRequest
        let access: FileSystemAccess
        let cadence: SnapshotCadence
        let rootDev: dev_t
        let rootResolvedPath: String
        let startDate: Date
        let emit: @Sendable (ScanEvent) -> Void

        private let lock: OSAllocatedUnfairLock<WalkState>
        private let pool: ResourcePool
        private let readers: [any DirectoryReading]
        private let workerCount: Int

        init(
            request: ScanRequest,
            access: FileSystemAccess,
            cadence: SnapshotCadence,
            concurrency: Int,
            rootStat: FileStat,
            rootResolvedPath: String,
            startDate: Date,
            emit: @escaping @Sendable (ScanEvent) -> Void
        ) {
            self.request = request
            self.access = access
            self.cadence = cadence
            self.rootDev = rootStat.dev
            self.rootResolvedPath = rootResolvedPath
            self.startDate = startDate
            self.emit = emit

            let workerCount = max(1, concurrency)
            self.workerCount = workerCount
            // One reader per worker: a reader owns a reusable read buffer, so it
            // must never be shared between concurrent reads.
            self.readers = (0..<workerCount).map { _ in access.makeDirectoryReader() }
            self.pool = ResourcePool(count: workerCount)
            self.lock = OSAllocatedUnfairLock(initialState: WalkState(
                lastProgressAt: startDate,
                lastSnapshotAt: startDate
            ))
            // The root is its own subtree; claim it so a firmlink pointing back
            // at it cannot be walked a second time.
            lock.withLock { $0.visitedDirs.insert(DirKey(dev: rootStat.dev, ino: rootStat.ino)) }
        }

        // MARK: Cancellation

        var isCancelled: Bool { lock.withLock { $0.cancelled } }

        func markCancelled() {
            lock.withLock { $0.cancelled = true }
        }

        var workUnits: Int {
            lock.withLock { $0.totalFiles + $0.totalDirs }
        }

        // MARK: Accounting

        /// Records one visited entry under a single lock acquisition.
        ///
        /// A full-disk scan visits millions of entries, so the path update, the
        /// work counter and the entry's own accounting all share one acquisition:
        /// taking the lock again per concern turns short critical sections into
        /// measurable contention.
        func noteEntry(path: String, file: ScanNode?, checkClock: Bool) {
            lock.withLock { state in
                recordEntry(&state, path: path, file: file, checkClock: checkClock)
            }
        }

        /// Records a finalized directory and the work it completed.
        func recordDirectory(_ node: ScanNode, path: String, checkClock: Bool) {
            lock.withLock { state in
                state.totalDirs += 1
                state.largestDirectories.add(node)
                recordEntry(&state, path: path, file: nil, checkClock: checkClock)
            }
        }

        private func recordEntry(
            _ state: inout WalkState,
            path: String,
            file: ScanNode?,
            checkClock: Bool
        ) {
            state.currentPath = path
            state.workSinceSnapshot += 1

            if let file, file.fileCount > 0 {
                // A symlink leaf carries no data and is not a counted file; a
                // followed symlink to a file is.
                state.totalFiles += file.fileCount
                state.totalLogical += file.logicalSize
                state.totalAllocated += file.allocatedSize
                state.categoryBreakdown[file.category, default: 0] += file.logicalSize
                state.largestFiles.add(file)
            }

            emitCadence(&state, checkClock: checkClock)
        }

        /// Count a non-fatal issue and surface its detail while under the cap.
        ///
        /// `errorCount` always reflects the true number of distinct issues; only
        /// the per-path detail stream is bounded, which is why
        /// `surfacedIssueCount` may be smaller.
        func recordIssue(kind: ScanIssueKind, path: String, message: String) {
            lock.withLock { state in
                state.errorCount += 1
                guard state.surfacedIssueCount < FileScanner.maxSurfacedIssues else { return }
                state.surfacedIssueCount += 1
                emit(.issue(kind: kind, path: path, message: message))
            }
        }

        /// Record a directory that could not be enumerated, or one whose entries
        /// were denied. Counts every distinct directory once.
        func recordInaccessibleDirectory(path: String, error: Error) {
            let kind = ScanErrorClassifier.kind(for: error)
            let message = kind == .permissionDenied
                ? "Permission denied — this folder could not be read"
                : "Could not read folder: \(error.localizedDescription)"
            recordInaccessibleDirectory(path: path, kind: kind, message: message)
        }

        func recordInaccessibleDirectory(path: String, kind: ScanIssueKind, message: String) {
            lock.withLock { state in
                state.inaccessibleCount += 1
                if kind == .permissionDenied { state.permissionDeniedCount += 1 }
                state.errorCount += 1
                guard state.surfacedIssueCount < FileScanner.maxSurfacedIssues else { return }
                state.surfacedIssueCount += 1
                emit(.issue(kind: kind, path: path, message: message))
            }
        }

        // MARK: Progress and snapshots

        /// Emits `.progress` / `.partial` once the cadence allows.
        ///
        /// The snapshot is the accumulators exactly as they stand, so it reports
        /// completed work only — never projected counts, sizes or breakdowns.
        /// The clock is read only on the work units where `checkClock` is set,
        /// and always inside the lock: two workers can otherwise sample times in
        /// one order and emit in the other, presenting snapshots out of order.
        private func emitCadence(_ state: inout WalkState, checkClock: Bool) {
            var sampled: Date?
            if checkClock {
                let now = Date()
                sampled = now
                if now.timeIntervalSince(state.lastProgressAt) >= FileScanner.progressInterval {
                    state.lastProgressAt = now
                    emit(.progress(progress(from: state, finishedAt: now)))
                }
            }

            let byWork = state.workSinceSnapshot >= cadence.workThreshold
            let byTime = cadence.interval > 0 && sampled.map {
                $0.timeIntervalSince(state.lastSnapshotAt) >= cadence.interval
            } ?? false
            guard byWork || byTime else { return }

            let stamp = sampled ?? Date()
            state.lastSnapshotAt = stamp
            state.workSinceSnapshot = 0
            emit(.partial(summary(from: state, finishedAt: stamp)))
        }

        func summary(finishedAt: Date) -> ScanSummary {
            lock.withLock { summary(from: $0, finishedAt: finishedAt) }
        }

        func progress(finishedAt: Date) -> ScanProgress {
            lock.withLock { progress(from: $0, finishedAt: finishedAt) }
        }

        private func summary(from state: WalkState, finishedAt: Date) -> ScanSummary {
            ScanSummary(
                root: request.root,
                totalLogicalSize: state.totalLogical,
                totalAllocatedSize: state.totalAllocated,
                fileCount: state.totalFiles,
                directoryCount: state.totalDirs,
                inaccessibleCount: state.inaccessibleCount,
                errorCount: state.errorCount,
                permissionDeniedCount: state.permissionDeniedCount,
                surfacedIssueCount: state.surfacedIssueCount,
                startedAt: startDate,
                finishedAt: finishedAt,
                categoryBreakdown: state.categoryBreakdown,
                largestFiles: state.largestFiles.sortedDescending(),
                largestDirectories: state.largestDirectories.sortedDescending()
            )
        }

        private func progress(from state: WalkState, finishedAt: Date) -> ScanProgress {
            ScanProgress(
                currentPath: state.currentPath,
                filesScanned: state.totalFiles,
                directoriesScanned: state.totalDirs,
                bytesScanned: state.totalLogical,
                // Never fabricate: a reliable total is not known without a
                // separate pre-pass, so fraction stays nil.
                fractionCompleted: nil,
                elapsed: finishedAt.timeIntervalSince(startDate)
            )
        }

        // MARK: Enumeration

        /// Read one directory under the concurrency bound, using the reader that
        /// belongs to the acquired slot.
        private func enumerate(path: String) async throws -> [DirectoryEntry] {
            let slot = await pool.acquire()
            defer { pool.release(slot) }
            if Task.isCancelled {
                markCancelled()
                throw CancellationError()
            }
            return try readers[slot].read(path: path)
        }

        // MARK: Traversal

        /// Enumerates `path`, builds its `ScanNode` bottom-up, and returns it.
        /// Returns `nil` when the scan was cancelled before the subtree finished.
        func scanDirectory(path: String, name: String, isSymlink: Bool, stat: FileStat) async -> ScanNode? {
            if Task.isCancelled {
                markCancelled()
                return nil
            }

            var entries: [DirectoryEntry] = []
            var isAccessible = true
            var errorMessage: String?
            do {
                entries = try await enumerate(path: path)
            } catch is CancellationError {
                markCancelled()
                return nil
            } catch {
                isAccessible = false
                errorMessage = error.localizedDescription
                recordInaccessibleDirectory(path: path, error: error)
            }

            var children: [ScanNode] = []
            var fileCount = 0
            var directoryCount = 0
            var logical: Int64 = 0
            var allocated: Int64 = 0
            var subdirectories: [PendingDirectory] = []
            var reportedDeniedChild = false
            // The wall clock is only needed for the time-based cadence, so it is
            // sampled once every `clockCheckInterval` units rather than per entry.
            var unitsSinceClockCheck = 0

            for entry in entries {
                if Task.isCancelled {
                    markCancelled()
                    return nil
                }
                if !request.includeHidden && entry.name.hasPrefix(".") {
                    continue
                }

                let childPath = FileScanner.joinedPath(dir: path, name: entry.name)
                let childStat = entry.stat
                unitsSinceClockCheck += 1
                let checkClock = unitsSinceClockCheck >= FileScanner.clockCheckInterval
                if checkClock { unitsSinceClockCheck = 0 }

                if childStat.error != 0 {
                    // Permission denial is aggregated per directory: the first
                    // denied child marks the containing directory inaccessible
                    // and surfaces a single issue; later denials in the same
                    // directory are silent. Non-permission failures are reported
                    // individually (bounded by the surfacing cap).
                    let kind = ScanErrorClassifier.kind(errno: childStat.error)
                    if kind == .permissionDenied {
                        if !reportedDeniedChild {
                            reportedDeniedChild = true
                            isAccessible = false
                            errorMessage = "Permission denied"
                            recordInaccessibleDirectory(
                                path: path,
                                kind: .permissionDenied,
                                message: "Permission denied — some items in this folder could not be read"
                            )
                        }
                    } else {
                        recordIssue(
                            kind: kind,
                            path: childPath,
                            message: ScanErrorClassifier.message(for: childStat.error)
                        )
                    }
                    noteEntry(path: childPath, file: nil, checkClock: checkClock)
                    continue
                }

                if childStat.isDirectory {
                    if let pending = claimChildDirectory(
                        path: childPath,
                        name: entry.name,
                        stat: childStat,
                        isSymlink: false,
                        checkClock: checkClock
                    ) {
                        subdirectories.append(pending)
                    }
                } else if childStat.isRegularFile {
                    let node = makeFileNode(name: entry.name, path: childPath, stat: childStat)
                    noteEntry(path: childPath, file: node, checkClock: checkClock)
                    children.append(node)
                    fileCount += 1
                    logical += node.logicalSize
                    allocated += node.allocatedSize
                } else if childStat.isSymlink {
                    switch resolveSymlink(name: entry.name, path: childPath, stat: childStat) {
                    case .child(let node):
                        noteEntry(path: childPath, file: node, checkClock: checkClock)
                        children.append(node)
                        fileCount += node.fileCount
                        directoryCount += node.directoryCount
                        logical += node.logicalSize
                        allocated += node.allocatedSize
                    case .directory(let pending):
                        noteEntry(path: childPath, file: nil, checkClock: checkClock)
                        subdirectories.append(pending)
                    case .none:
                        noteEntry(path: childPath, file: nil, checkClock: checkClock)
                    }
                } else {
                    // Special entry (block/char/fifo/socket) — skipped safely.
                    noteEntry(path: childPath, file: nil, checkClock: checkClock)
                }
            }

            if !subdirectories.isEmpty {
                // Release the enumeration buffer before waiting on children. This
                // frame stays alive until the whole subtree finishes, so holding
                // the entries would pin one array per open directory.
                entries = []

                // Spawn at most `workerCount` children at a time, each walking a
                // slice of them in turn. One task per subdirectory would queue a
                // task for every directory on the frontier at once — thousands of
                // live frames for a wide directory — which costs far more memory
                // than it buys in parallelism. Bounded chunks keep the frontier
                // depth-first.
                let chunkCount = min(workerCount, subdirectories.count)
                let chunkSize = (subdirectories.count + chunkCount - 1) / chunkCount
                var chunks: [[PendingDirectory]] = []
                chunks.reserveCapacity(chunkCount)
                var start = 0
                while start < subdirectories.count {
                    let end = min(start + chunkSize, subdirectories.count)
                    chunks.append(Array(subdirectories[start..<end]))
                    start = end
                }
                subdirectories = []

                await withTaskGroup(of: [ScanNode].self) { group in
                    for chunk in chunks {
                        group.addTask {
                            var produced: [ScanNode] = []
                            produced.reserveCapacity(chunk.count)
                            for pending in chunk {
                                if let node = await self.scanDirectory(
                                    path: pending.path,
                                    name: pending.name,
                                    isSymlink: pending.isSymlink,
                                    stat: pending.stat
                                ) {
                                    produced.append(node)
                                }
                            }
                            return produced
                        }
                    }

                    for await produced in group {
                        for node in produced {
                            children.append(node)
                            fileCount += node.fileCount
                            directoryCount += node.directoryCount
                            logical += node.logicalSize
                            allocated += node.allocatedSize
                        }
                    }
                }
            }

            directoryCount += 1   // count this directory itself
            let node = ScanNode(
                id: UUID(),
                url: FileScanner.nodeURL(path, isDirectory: true),
                name: name,
                isDirectory: true,
                isSymlink: isSymlink,
                category: FileCategorizer.category(name: name, isDirectory: true),
                logicalSize: logical,
                allocatedSize: allocated,
                fileCount: fileCount,
                directoryCount: directoryCount,
                modifiedAt: stat.modifiedAt,
                isAccessible: isAccessible,
                errorMessage: errorMessage,
                children: children.sorted { $0.logicalSize > $1.logicalSize }
            )
            recordDirectory(node, path: path, checkClock: true)
            return node
        }

        /// Applies `stayOnVolume`, the duplicate-subtree guard and the entry's
        /// accounting in one acquisition, returning the directory only when this
        /// worker may walk it.
        private func claimChildDirectory(
            path: String,
            name: String,
            stat: FileStat,
            isSymlink: Bool,
            checkClock: Bool
        ) -> PendingDirectory? {
            // A bulk read reports the *underlying* volume's device for a mount
            // point, so a mount point's real device has to be read directly —
            // there are only a handful of them.
            let mounted = stat.isMountPoint ? access.lstat(path) : stat
            if request.stayOnVolume && mounted.dev != rootDev {
                noteEntry(path: path, file: nil, checkClock: checkClock)
                return nil
            }

            let key = DirKey(dev: mounted.dev, ino: mounted.ino)
            let claimed = lock.withLock { state -> Bool in
                recordEntry(&state, path: path, file: nil, checkClock: checkClock)
                if state.visitedDirs.contains(key) { return false }
                state.visitedDirs.insert(key)
                return true
            }
            guard claimed else { return nil }
            return PendingDirectory(path: path, name: name, isSymlink: isSymlink, stat: stat)
        }

        /// Claims a directory reached through a followed symlink.
        private func claimDirectory(dev: dev_t, ino: ino_t) -> Bool {
            lock.withLock { state in
                let key = DirKey(dev: dev, ino: ino)
                if state.visitedDirs.contains(key) { return false }
                state.visitedDirs.insert(key)
                return true
            }
        }

        private func resolveSymlink(name: String, path: String, stat: FileStat) -> SymlinkOutcome? {
            guard request.followSymlinks else {
                // Default safe behavior: represent the link as a zero-sized leaf, never follow.
                return .child(makeSymlinkLeaf(name: name, path: path, stat: stat))
            }

            let target = access.statFollowing(path)
            guard target.error == 0 else {
                // Broken symlink: non-fatal, still represented.
                recordIssue(
                    kind: .brokenSymlink,
                    path: path,
                    message: "Broken symlink: \(FileScanner.errnoText(target.error))"
                )
                return .child(brokenSymlinkNode(name: name, path: path, stat: stat))
            }

            if target.isDirectory {
                if request.stayOnVolume && target.dev != rootDev { return nil }
                if !isWithinRoot(path) { return nil }            // never escape the root
                guard claimDirectory(dev: target.dev, ino: target.ino) else { return nil }
                return .directory(PendingDirectory(path: path, name: name, isSymlink: true, stat: target))
            }

            if target.isRegularFile {
                // Symlink to a file: follow and count the target's size.
                let node = ScanNode(
                    id: UUID(), url: FileScanner.nodeURL(path, isDirectory: false), name: name,
                    isDirectory: false, isSymlink: true,
                    category: FileCategorizer.category(name: name, isDirectory: false),
                    logicalSize: target.size, allocatedSize: target.allocatedSize,
                    fileCount: 1, directoryCount: 0,
                    modifiedAt: target.modifiedAt, isAccessible: true, errorMessage: nil, children: []
                )
                return .child(node)
            }

            // Symlink to a special entry — skipped safely.
            return nil
        }

        private func isWithinRoot(_ path: String) -> Bool {
            let resolved = access.resolvedPath(path)
            return resolved == rootResolvedPath || resolved.hasPrefix(rootResolvedPath + "/")
        }

        // MARK: Node factories

        private func makeFileNode(name: String, path: String, stat: FileStat) -> ScanNode {
            ScanNode(
                id: UUID(), url: FileScanner.nodeURL(path, isDirectory: false), name: name,
                isDirectory: false, isSymlink: false,
                category: FileCategorizer.category(name: name, isDirectory: false),
                logicalSize: stat.size, allocatedSize: stat.allocatedSize,
                fileCount: 1, directoryCount: 0,
                modifiedAt: stat.modifiedAt, isAccessible: true, errorMessage: nil, children: []
            )
        }

        private func makeSymlinkLeaf(name: String, path: String, stat: FileStat) -> ScanNode {
            ScanNode(
                id: UUID(), url: FileScanner.nodeURL(path, isDirectory: false), name: name,
                isDirectory: false, isSymlink: true, category: .other,
                logicalSize: 0, allocatedSize: 0, fileCount: 0, directoryCount: 0,
                modifiedAt: stat.modifiedAt, isAccessible: true, errorMessage: nil, children: []
            )
        }

        private func brokenSymlinkNode(name: String, path: String, stat: FileStat) -> ScanNode {
            ScanNode(
                id: UUID(), url: FileScanner.nodeURL(path, isDirectory: false), name: name,
                isDirectory: false, isSymlink: true, category: .other,
                logicalSize: 0, allocatedSize: 0, fileCount: 0, directoryCount: 0,
                modifiedAt: stat.modifiedAt, isAccessible: true,
                errorMessage: "Broken symlink", children: []
            )
        }
    }
}

// MARK: - Resource pool

/// Hands out a fixed set of reusable resources, one at a time.
///
/// Each directory read takes a slot; the slot's index also selects the reader
/// that performs the read, so a reader's reusable buffer is never used by two
/// reads at once. Waiting on a slot suspends rather than blocks, so a saturated
/// pool never occupies a thread.
private final class ResourcePool: @unchecked Sendable {
    private struct State {
        var available: [Int]
        var waiters: [CheckedContinuation<Int, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(count: Int) {
        let slots = Array(0..<max(1, count))
        state = OSAllocatedUnfairLock(initialState: State(available: slots))
    }

    func acquire() async -> Int {
        let immediate: Int? = state.withLock { state in
            state.available.popLast()
        }
        if let immediate { return immediate }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let released: Int? = state.withLock { state in
                if let slot = state.available.popLast() { return slot }
                state.waiters.append(continuation)
                return nil
            }
            if let released { continuation.resume(returning: released) }
        }
    }

    func release(_ slot: Int) {
        let waiter: CheckedContinuation<Int, Never>? = state.withLock { state in
            if !state.waiters.isEmpty { return state.waiters.removeFirst() }
            state.available.append(slot)
            return nil
        }
        waiter?.resume(returning: slot)
    }
}
