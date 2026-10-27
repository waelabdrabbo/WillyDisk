import Foundation

/// How far an asset download has got.
///
/// `expectedBytes` is `nil` when the server does not state a length; the UI then
/// shows an indeterminate bar and the bytes received, never a made-up percentage.
public struct DownloadProgress: Equatable, Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?

    public init(receivedBytes: Int64, expectedBytes: Int64?) {
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
    }

    public static let zero = DownloadProgress(receivedBytes: 0, expectedBytes: nil)

    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }
}

/// The download seam: tests substitute a writer, the app uses `URLSession`.
public protocol UpdateDownloading: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws
}

/// Downloads one release asset to a file, with real byte progress.
///
/// The session is ephemeral: an update download has no cookies, cache, or state
/// worth keeping. The size ceiling is a guard against a feed pointing at
/// something enormous, not a limit on a real release (the current zips are
/// about 2.6 MB).
public struct URLSessionUpdateDownloader: UpdateDownloading {
    public static let maximumBytes: Int64 = 200 * 1024 * 1024

    public init() {}

    public func download(
        from url: URL,
        to destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureAsset
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false

        let delegate = UpdateDownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: url)
        defer { session.invalidateAndCancel() }

        try await withTaskCancellationHandler {
            _ = try await delegate.run(task)
        } onCancel: {
            task.cancel()
        }
    }
}

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (DownloadProgress) -> Void
    private let stream: AsyncThrowingStream<URL, Error>
    private let continuation: AsyncThrowingStream<URL, Error>.Continuation
    private let lock = NSLock()
    private var finished = false

    init(
        destination: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.destination = destination
        self.progress = progress
        let pair = AsyncThrowingStream<URL, Error>.makeStream()
        self.stream = pair.stream
        self.continuation = pair.continuation
        super.init()
    }

    func run(_ task: URLSessionDownloadTask) async throws -> URL {
        task.resume()
        for try await file in stream {
            return file
        }
        throw UpdateError.downloadFailed
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= URLSessionUpdateDownloader.maximumBytes else {
            finish(.failure(UpdateError.downloadTooLarge))
            downloadTask.cancel()
            return
        }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        progress(
            DownloadProgress(receivedBytes: totalBytesWritten, expectedBytes: expected)
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(UpdateError.invalidResponse))
            return
        }
        guard (200...299).contains(response.statusCode) else {
            finish(.failure(UpdateError.httpStatus(response.statusCode)))
            return
        }

        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: location, to: destination)
        } catch {
            finish(.failure(UpdateError.downloadFailed))
            return
        }
        finish(.success(destination))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            finish(.failure(UpdateError.downloadFailed))
            return
        }
        if let urlError = error as? URLError {
            finish(.failure(UpdateError.transportError(from: urlError)))
        } else {
            finish(.failure(UpdateError.downloadFailed))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        switch result {
        case .success(let file):
            continuation.yield(file)
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        }
    }
}
