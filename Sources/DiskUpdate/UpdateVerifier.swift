import Foundation

/// Checks that a downloaded archive is the release it claims to be before it is
/// allowed anywhere near the installed app.
///
/// The order is deliberate. The checksum proves the bytes are the ones the
/// publisher attached to the release. Only then is the archive expanded, and only
/// then is the expanded bundle's identity checked: bundle identifier, marketing
/// version, executable, minimum macOS, architecture, and code signature. A failure
/// at any step leaves the installed copy untouched.
///
/// Every method is synchronous and touches the filesystem or spawns a system tool,
/// so callers run them off the main actor. Nothing here launches the downloaded app.
public struct UpdateVerifier: Sendable {
    public let expectedBundleIdentifier: String
    public let expectedMarketingVersion: String
    public let expectedAppName: String
    public let architecture: ReleaseArchitecture
    public let operatingSystemVersion: OperatingSystemVersion

    public init(
        expectedBundleIdentifier: String,
        expectedMarketingVersion: String,
        expectedAppName: String = "WillyDisk.app",
        architecture: ReleaseArchitecture = .current,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedMarketingVersion = expectedMarketingVersion
        self.expectedAppName = expectedAppName
        self.architecture = architecture
        self.operatingSystemVersion = operatingSystemVersion
    }

    /// Verifies the archive against the release's `.sha256` and returns the digest.
    public func verify(
        archive: URL,
        checksumFile: URL,
        expectedArchiveName: String? = nil,
        expectedByteCount: Int? = nil
    ) throws -> SHA256Digest {
        let expectedName = expectedArchiveName ?? archive.lastPathComponent
        guard archive.lastPathComponent == expectedName else {
            throw UpdateError.archiveNameMismatch(
                expected: expectedName,
                found: archive.lastPathComponent
            )
        }
        if let expectedByteCount {
            guard FileManager.default.fileExists(atPath: archive.path) else {
                throw UpdateError.archiveMissing
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path)
            guard let actual = (attributes?[.size] as? NSNumber)?.intValue else {
                throw UpdateError.archiveUnreadable
            }
            guard actual == expectedByteCount else {
                throw UpdateError.sizeMismatch(expected: expectedByteCount, actual: actual)
            }
        }

        let text = try Self.readChecksumFile(at: checksumFile)
        let published = try ChecksumFile.parse(text, expecting: expectedName)
        let actual = try ChecksumFile.digestOfFile(at: archive)
        guard actual == published else {
            throw UpdateError.checksumMismatch(expected: published.hex, actual: actual.hex)
        }
        return actual
    }

    /// Expands the archive into an empty directory and returns the app inside it.
    ///
    /// `ditto` is the extractor because the release is built with `ditto`: it
    /// preserves the extended attributes and resource forks the ad-hoc signature
    /// seals over, which a plain `unzip` can drop.
    public func extract(archive: URL, into directory: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let contents: [String]
            do {
                contents = try manager.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw UpdateError.extractionFailed
            }
            guard contents.isEmpty else {
                throw UpdateError.extractionDirectoryNotEmpty
            }
        } else {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw UpdateError.extractionFailed
            }
        }

        let result = try Self.run(
            "/usr/bin/ditto",
            ["-x", "-k", archive.path, directory.path]
        )
        guard result.status == 0 else {
            throw UpdateError.extractionFailed
        }

        let bundle = directory.appendingPathComponent(expectedAppName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: bundle.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw UpdateError.bundleMissing
        }

        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBundle = bundle.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedBundle.lastPathComponent == expectedAppName,
              resolvedBundle.deletingLastPathComponent() == resolvedDirectory else {
            throw UpdateError.bundleOutsideDestination
        }
        return bundle
    }

    /// Reads the expanded bundle's own metadata and signature.
    public func validate(bundleAt bundleURL: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: bundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw UpdateError.bundleMissing
        }
        guard let bundle = Bundle(url: bundleURL) else {
            throw UpdateError.invalidBundle(.missingIdentifier)
        }
        guard let identifier = bundle.bundleIdentifier else {
            throw UpdateError.invalidBundle(.missingIdentifier)
        }
        guard identifier == expectedBundleIdentifier else {
            throw UpdateError.invalidBundle(.unexpectedIdentifier)
        }
        guard let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            throw UpdateError.invalidBundle(.missingVersion)
        }
        guard version == expectedMarketingVersion else {
            throw UpdateError.invalidBundle(.unexpectedVersion)
        }
        guard let executable = bundle.executableURL,
              manager.isExecutableFile(atPath: executable.path) else {
            throw UpdateError.invalidBundle(.missingExecutable)
        }

        if let minimum = bundle.object(
            forInfoDictionaryKey: "LSMinimumSystemVersion"
        ) as? String {
            let required = try Self.operatingSystemVersion(from: minimum)
            guard isAtLeast(required) else {
                throw UpdateError.invalidBundle(.requiresNewerMacOS)
            }
        }

        try Self.verifyArchitecture(of: executable, expected: architecture)
        try Self.verifySignature(of: bundleURL)
    }

    // MARK: - Helpers

    private func isAtLeast(_ required: OperatingSystemVersion) -> Bool {
        let current = operatingSystemVersion
        if current.majorVersion != required.majorVersion {
            return current.majorVersion > required.majorVersion
        }
        if current.minorVersion != required.minorVersion {
            return current.minorVersion > required.minorVersion
        }
        return current.patchVersion >= required.patchVersion
    }

    private static func readChecksumFile(at url: URL) throws -> String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw UpdateError.checksumUnreadable
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ChecksumFile.maximumSize else {
            throw UpdateError.checksumMalformed
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.checksumUnreadable
        }
        return text
    }

    private static func operatingSystemVersion(from raw: String) throws -> OperatingSystemVersion {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ part in
                  !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
              }),
              let major = Int(parts[0]) else {
            throw UpdateError.invalidBundle(.malformedMinimumSystemVersion)
        }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch else {
            throw UpdateError.invalidBundle(.malformedMinimumSystemVersion)
        }
        return OperatingSystemVersion(
            majorVersion: major,
            minorVersion: minor,
            patchVersion: patch
        )
    }

    private static func verifyArchitecture(
        of executable: URL,
        expected: ReleaseArchitecture
    ) throws {
        let result = try run("/usr/bin/lipo", ["-archs", executable.path])
        guard result.status == 0 else {
            throw UpdateError.invalidBundle(.unsupportedArchitecture)
        }
        let architectures = result.output
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard architectures.contains(expected.rawValue) else {
            throw UpdateError.invalidBundle(.unsupportedArchitecture)
        }
    }

    private static func verifySignature(of bundleURL: URL) throws {
        let result = try run("/usr/bin/codesign", ["--verify", "--strict", bundleURL.path])
        guard result.status == 0 else {
            throw UpdateError.invalidBundle(.signatureInvalid)
        }
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw UpdateError.toolFailed(
                tool: (executable as NSString).lastPathComponent,
                status: -1
            )
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
