import Foundation

/// The local APFS snapshots a volume reports.
///
/// Snapshots can keep deleted blocks alive, so a volume's free space can stay
/// low after files are moved to the Trash. The coverage screen reports the
/// names the system lists; it never estimates the space they hold, because
/// macOS has no public API that reports a snapshot's size.
public struct LocalSnapshots: Equatable, Sendable {
    public let volumeName: String
    public let names: [String]
    /// Why the list could not be read. `nil` means the list is the system's
    /// complete answer, including an empty one.
    public let failureMessage: String?

    public init(volumeName: String, names: [String], failureMessage: String? = nil) {
        self.volumeName = volumeName
        self.names = names
        self.failureMessage = failureMessage
    }

    public var isAvailable: Bool { failureMessage == nil }
    public var count: Int { names.count }
}

/// Asks `tmutil` for the local snapshots on the volume holding a folder.
///
/// `tmutil listlocalsnapshots` is the only supported way to enumerate them.
/// The call is bounded so a stalled volume cannot leave a sheet spinning, and
/// its output is parsed by a pure function that the tests can exercise without
/// running the tool.
public enum SnapshotProbe {
    /// How long `tmutil` is given before the process is terminated.
    static let timeout: TimeInterval = 4

    public static func list(onVolumeAt url: URL) async -> LocalSnapshots {
        let mount = MountedVolume.of(url)?.root ?? url.standardizedFileURL
        let volumeName = mount.lastPathComponent.isEmpty ? mount.path : mount.lastPathComponent

        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tmutil") else {
            return LocalSnapshots(
                volumeName: volumeName,
                names: [],
                failureMessage: "`tmutil` is not available on this Mac."
            )
        }

        return await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
            process.arguments = ["listlocalsnapshots", mount.path]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return LocalSnapshots(
                    volumeName: volumeName,
                    names: [],
                    failureMessage: "Could not run `tmutil`."
                )
            }

            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + Self.timeout,
                execute: timeout
            )
            // Drain the pipe before waiting: `tmutil`'s list is small, but a
            // full pipe would otherwise block the child and make the timeout
            // the only thing that ends the wait.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()

            guard process.terminationStatus == 0 else {
                return LocalSnapshots(
                    volumeName: volumeName,
                    names: [],
                    failureMessage: "`tmutil` could not list this volume's snapshots."
                )
            }

            let text = String(decoding: data, as: UTF8.self)
            return LocalSnapshots(
                volumeName: volumeName,
                names: parse(text)
            )
        }.value
    }

    /// Extracts the snapshot names from `tmutil listlocalsnapshots` output.
    ///
    /// The tool prints a header and one `com.apple.TimeMachine.<date>.local`
    /// name per line; anything else is ignored rather than guessed at.
    public static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let name = trimmed.split(separator: " ").last.map(String.init),
                      name.hasSuffix(".local")
                else { return nil }
                guard seen.insert(name).inserted else { return nil }
                return name
            }
    }
}
