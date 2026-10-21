import Foundation
import DiskCore

/// The command-line front end for a scan.
///
/// It is a consumer of `ScanEngine` and nothing else: the walk, the accounting,
/// the exclusion rules and the cancellation path are the engine's, so a script
/// measures exactly what the app measures. Only the presentation lives here.
public enum ScanCLI {

    /// Whether this process was asked for the command line rather than the app.
    ///
    /// The first argument must be `scan`, or an option such as `--help`. A bare
    /// launch has no arguments and opens the app. Returning true for any leading
    /// option means a typo in a script reports a usage error instead of quietly
    /// opening a window and waiting.
    public static func handles(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return first == "scan" || first.hasPrefix("-")
    }

    /// Runs one command-line invocation and returns the process exit status.
    ///
    /// This is the entry the executable calls. The caller supplies the process's
    /// arguments; this method owns the process-level signal handling, so
    /// `execute` can stay a plain consumer of the engine's event stream.
    public static func run(arguments: [String]) -> Int32 {
        run(arguments: arguments, output: .standard, installsSignalHandling: true)
    }

    /// The body of `run`, with the process-level pieces optional so a test can
    /// supply its own output and skip signal installation.
    static func run(
        arguments: [String],
        output: ScanOutput,
        installsSignalHandling: Bool
    ) -> Int32 {
        let invocation: ScanInvocation
        do {
            invocation = try ScanCommandLine.parse(arguments)
        } catch {
            let message = (error as? ScanUsageError)?.message ?? String(describing: error)
            output.standardError("error: \(message)\n\(ScanCommandLine.usageHint)\n")
            return 2
        }

        switch invocation {
        case .help:
            return write(ScanCommandLine.help + "\n", to: output)

        case .scan(let command):
            guard FileManager.default.fileExists(atPath: command.root.path) else {
                output.standardError("error: no such folder: \(command.root.path)\n")
                return 1
            }
            let engine = FileScanEngine()
            let cancellation = installsSignalHandling ? ScanCancellation(engine: engine) : nil
            defer { cancellation?.stop() }
            return blocking { await execute(command, engine: engine, output: output) }
        }
    }

    /// Drives one scan to its terminal event and prints the result.
    ///
    /// A cancelled run prints no report: its totals cover only the part of the
    /// folder the walk reached, and a report of them would read as a measurement
    /// of the whole location.
    public static func execute(
        _ command: ScanCommand,
        engine: any ScanEngine,
        output: ScanOutput = .standard
    ) async -> Int32 {
        let request = ScanRequest(root: command.root)
        var finished: ScanSummary?
        var cancelled = false

        for await event in engine.scan(request) {
            switch event {
            case .finished(let summary):
                finished = summary
            case .cancelled:
                cancelled = true
            case .started, .progress, .partial, .issue:
                // Issues are counted in the summary; partial snapshots are
                // advisory. Neither is the terminal answer this command prints.
                break
            }
        }

        if cancelled {
            output.standardError("Scan cancelled.\n")
            return 130
        }
        guard let summary = finished else {
            output.standardError("error: the scan ended without a result.\n")
            return 1
        }

        if command.json {
            // No volume figures: they describe the whole disk, not this
            // measurement, and they change while the command runs. The record
            // stays a stable statement about the folder that was walked.
            let record = ScanReport.record(for: summary, command: command)
            let text: String
            do {
                text = try ScanReport.json(record)
            } catch {
                output.standardError("error: the record could not be encoded: \(error.localizedDescription)\n")
                return 1
            }
            return write(text, to: output)
        }
        return write(ScanReport.text(for: summary, command: command), to: output)
    }

    // MARK: - Output

    private static func write(_ text: String, to output: ScanOutput) -> Int32 {
        do {
            try output.standardOutput(text)
            return 0
        } catch {
            output.standardError("error: the report could not be written: \(error.localizedDescription)\n")
            return 1
        }
    }

    // MARK: - Process plumbing

    /// Waits for the async scan on a command-line process's main thread.
    private static func blocking(_ work: @escaping @Sendable () async -> Int32) -> Int32 {
        let box = ExitCodeBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let code = await work()
            box.store(code)
            done.signal()
        }
        done.wait()
        return box.value
    }
}

/// Where the command writes. Injecting it keeps the report testable without a
/// subprocess, and keeps machine-readable output and diagnostics apart: stdout
/// carries the report, stderr carries what went wrong.
public struct ScanOutput: Sendable {
    public let standardOutput: @Sendable (String) throws -> Void
    public let standardError: @Sendable (String) -> Void

    public init(
        standardOutput: @escaping @Sendable (String) throws -> Void,
        standardError: @escaping @Sendable (String) -> Void
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static let standard = ScanOutput(
        standardOutput: { text in
            guard let data = text.data(using: .utf8) else { return }
            try FileHandle.standardOutput.write(contentsOf: data)
        },
        standardError: { text in
            guard let data = text.data(using: .utf8) else { return }
            try? FileHandle.standardError.write(contentsOf: data)
        }
    )
}

/// Turns a signal into the engine's own cancellation.
///
/// A dispatch source only sees a signal whose default disposition has been
/// replaced, so SIGINT and SIGTERM are ignored first. The scan then ends through
/// `.cancelled` like any other cancellation: no second stopping mechanism, and
/// the engine still decides when it is safe to stop.
private final class ScanCancellation: @unchecked Sendable {
    private let sources: [any DispatchSourceSignal]

    init(engine: any ScanEngine) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let queue = DispatchQueue(label: "com.willydisk.scan.signals")
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                Task { await engine.cancel() }
            }
            source.resume()
            return source
        }
    }

    func stop() {
        for source in sources { source.cancel() }
    }
}

private final class ExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = 1

    func store(_ code: Int32) {
        lock.lock()
        stored = code
        lock.unlock()
    }

    var value: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
