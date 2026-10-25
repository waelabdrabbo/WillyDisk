import Foundation
import CoreServices

/// Why a watcher could not be installed.
public enum ScanTreeWatchError: Error, Equatable {
    /// The system refused to create or start the event stream.
    case streamUnavailable
}

/// Watches one scanned root through FSEvents.
///
/// One stream covers the whole root, including nested mounts; deciding whether
/// an event belongs to what was measured is `ScanWatchScope`'s job, not the
/// stream's. The callback runs on a private serial queue, so the handler must
/// leave it quickly — the app's consumer hops to the main actor.
///
/// The stream reports items, so a batch names the files and folders that moved.
/// `ScanItemEvent` reduces each one to the folder it changes and drops the
/// metadata events that cannot change what a scan measured. Events are never
/// filtered by the process that caused them: a change this process made — moving
/// an item to the Trash — is still a change to the tree the results describe.
///
/// The watcher holds no strong reference to its consumer: the handler is called
/// with whatever the consumer retains, and stopping the watcher releases it.
public final class ScanTreeWatcher: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (ScanTreeChange) -> Void

    private static let queueKey = DispatchSpecificKey<UInt8>()

    private static let streamFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagFileEvents
    )

    private static let rootChangedFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)

    /// Events that mean the batch cannot be trusted to name every path.
    private static let coarseFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)

    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "app.willydisk.scan-tree-watch", qos: .utility)

    private var stream: FSEventStreamRef?
    private var scope: ScanWatchScope?
    private var handler: ChangeHandler?

    /// - Parameter latency: how long FSEvents may coalesce events before
    ///   delivering a batch. The consumer adds its own quiet period on top.
    public init(latency: TimeInterval = 0.5) {
        self.latency = max(0.1, latency)
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    /// Starts watching `root`. Replaces any watch already running.
    ///
    /// The root's device is read here, on the watcher's queue, so no filesystem
    /// call lands on the caller's actor.
    public func start(
        root: URL,
        excludedPaths: [URL] = [],
        stayOnVolume: Bool = true,
        onChange: @escaping ChangeHandler
    ) throws {
        try syncOnQueue {
            stopLocked()

            let rootPath = ScanWatchScope.canonicalPath(root)
            let device = stayOnVolume ? Self.device(of: rootPath) : nil
            let scope = ScanWatchScope(
                root: root,
                excludedPaths: excludedPaths,
                stayOnVolume: stayOnVolume,
                rootDevice: device
            )

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                scanTreeChangeCallback,
                &context,
                [scope.rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                Self.streamFlags
            ) else {
                throw ScanTreeWatchError.streamUnavailable
            }

            self.scope = scope
            self.handler = onChange
            self.stream = stream

            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
                self.scope = nil
                self.handler = nil
                throw ScanTreeWatchError.streamUnavailable
            }
        }
    }

    /// Stops watching and releases the stream. Safe to call when not watching.
    public func stop() {
        syncOnQueue { stopLocked() }
    }

    // MARK: - Stream ownership

    private func stopLocked() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        scope = nil
        handler = nil
    }

    private func syncOnQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    private static func device(of path: String) -> dev_t? {
        let stat = FileStat.lstat(path)
        return stat.error == 0 ? stat.dev : nil
    }

    // MARK: - Events

    fileprivate func handle(
        count: Int,
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>
    ) {
        guard let scope, let handler else { return }

        let array = unsafeBitCast(paths, to: NSArray.self)
        let usable = min(count, array.count)
        var raw: [String] = []
        raw.reserveCapacity(min(usable, ScanWatchScope.maxBatchPaths))
        var seen = Set<String>()
        var coarse = false
        var rootMissing = false

        for index in 0..<usable {
            let flag = flags[index]
            if flag & Self.rootChangedFlag != 0 { rootMissing = true }
            if flag & Self.coarseFlags != 0 { coarse = true }
            guard raw.count < ScanWatchScope.maxBatchPaths,
                  let path = array[index] as? String, !path.isEmpty,
                  ScanItemEvent.changesMeasuredContents(flag) else { continue }
            let folder = ScanItemEvent.folderPath(for: path, flags: flag)
            if seen.insert(folder).inserted {
                raw.append(folder)
            }
        }

        guard let change = scope.change(
            inBatch: raw,
            isCoarse: coarse,
            rootMissing: rootMissing
        ), !change.isEmpty else { return }

        handler(change)
    }
}

/// The C callback for every `ScanTreeWatcher`; the stream's context carries the
/// watcher unretained so the watcher's own lifetime decides when it goes away.
private let scanTreeChangeCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info else { return }
    Unmanaged<ScanTreeWatcher>
        .fromOpaque(info)
        .takeUnretainedValue()
        .handle(count: count, paths: paths, flags: flags)
}
