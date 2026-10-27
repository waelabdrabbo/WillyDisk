import Foundation

/// Why an install could not even be started.
public enum UpdateInstallError: Error, Equatable, Sendable {
    case notAnApplication
    case translocated
    case destinationNotWritable
    case stagedAppMissing
    case recoveryDirectoryUnavailable
    case couldNotWriteScript
    case couldNotStartHelper
}

/// What the detached helper reported after the app quit.
public enum UpdateInstallFailure: String, Equatable, Sendable {
    case waitTimedOut
    case backupFailed
    case installFailed
    case invalid
}

public struct UpdateInstallOutcome: Equatable, Sendable {
    public enum Status: String, Sendable {
        case installed
        case failed
    }

    public let status: Status
    public let version: String
    public let relaunched: Bool
    public let failure: UpdateInstallFailure?

    public init(
        status: Status,
        version: String,
        relaunched: Bool,
        failure: UpdateInstallFailure?
    ) {
        self.status = status
        self.version = version
        self.relaunched = relaunched
        self.failure = failure
    }
}

/// Everything the helper needs. Paths are passed as arguments, never interpolated
/// into a shell command, so a space or quote in an application or folder name is
/// just a character in an argument.
public struct UpdateInstallRequest: Sendable {
    public let targetApp: URL
    public let stagedApp: URL
    public let recoveryDirectory: URL
    public let resultURL: URL
    public let version: String
    public let parentPID: Int32
    public let relaunch: Bool

    public init(
        targetApp: URL,
        stagedApp: URL,
        recoveryDirectory: URL,
        resultURL: URL,
        version: String,
        parentPID: Int32,
        relaunch: Bool
    ) {
        self.targetApp = targetApp
        self.stagedApp = stagedApp
        self.recoveryDirectory = recoveryDirectory
        self.resultURL = resultURL
        self.version = version
        self.parentPID = parentPID
        self.relaunch = relaunch
    }
}

/// The install seam. `UpdateInstaller` is the real one; the controller takes the
/// protocol so its install states can be tested without touching the test host's
/// app bundle.
public protocol UpdateInstalling: Sendable {
    func validateDestination(for targetApp: URL) throws
    func install(_ request: UpdateInstallRequest) throws
    func consumeResult(at resultURL: URL) -> UpdateInstallOutcome?
}

/// Replaces the running app after it quits.
///
/// The swap cannot happen in the process that owns the bundle. This type writes a
/// small `/bin/sh` helper into the update folder, starts it detached, and returns;
/// the caller then quits. The helper waits for the parent to exit, moves the old
/// app to the recovery folder, copies the staged app into place, writes a result,
/// and reopens the app. A failed copy restores the previous app before reopening it.
///
/// The helper is deliberately plain shell: it has no UI, no dependencies, and no
/// state of its own beyond the paths it is given.
public struct UpdateInstaller: UpdateInstalling, Sendable {
    public init() {}

    /// Refuses a destination the app cannot safely replace.
    public func validateDestination(for targetApp: URL) throws {
        guard targetApp.pathExtension == "app" else {
            throw UpdateInstallError.notAnApplication
        }
        guard !targetApp.path.contains("/AppTranslocation/") else {
            throw UpdateInstallError.translocated
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: targetApp.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw UpdateInstallError.notAnApplication
        }
        if let values = try? targetApp.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw UpdateInstallError.notAnApplication
        }
        if let values = try? targetApp.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            throw UpdateInstallError.destinationNotWritable
        }
        guard manager.isWritableFile(
            atPath: targetApp.deletingLastPathComponent().path
        ) else {
            throw UpdateInstallError.destinationNotWritable
        }
    }

    /// Writes the helper and starts it. The caller must quit after this returns;
    /// the helper waits for this process to disappear before touching the app.
    public func install(_ request: UpdateInstallRequest) throws {
        try validateDestination(for: request.targetApp)

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: request.stagedApp.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw UpdateInstallError.stagedAppMissing
        }

        let recovery = request.recoveryDirectory
        do {
            if manager.fileExists(atPath: recovery.path) {
                try manager.createDirectory(
                    at: recovery,
                    withIntermediateDirectories: true
                )
            } else {
                try manager.createDirectory(
                    at: recovery,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        } catch {
            throw UpdateInstallError.recoveryDirectoryUnavailable
        }

        // The app already approved this installation, and the download was
        // checked. A quarantine flag on the staged copy would block the relaunch
        // after the old copy is gone, so clear it before the swap. `xattr` is
        // best-effort here: a filesystem without the attribute is not a failure.
        Self.removeQuarantine(from: request.stagedApp)

        let backup = recovery.appendingPathComponent("backup/WillyDisk.app")
        if manager.fileExists(atPath: backup.path) {
            try? manager.removeItem(at: backup)
        }
        try? manager.removeItem(at: request.resultURL)

        let scriptURL = recovery.appendingPathComponent("install.sh")
        do {
            try Self.helperScript.write(to: scriptURL, atomically: true, encoding: .utf8)
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw UpdateInstallError.couldNotWriteScript
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(request.parentPID),
            request.targetApp.path,
            request.stagedApp.path,
            backup.path,
            recovery.appendingPathComponent("install.log").path,
            request.resultURL.path,
            request.version,
            request.relaunch ? "1" : "0",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UpdateInstallError.couldNotStartHelper
        }
    }

    /// Reads and removes the helper's result. `nil` means no update ran.
    public func consumeResult(at resultURL: URL) -> UpdateInstallOutcome? {
        guard let data = try? Data(contentsOf: resultURL),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? FileManager.default.removeItem(at: resultURL)

        var values: [String: String] = [:]
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            values[key] = value
        }
        guard let status = values["status"]
            .flatMap(UpdateInstallOutcome.Status.init(rawValue:)) else {
            return nil
        }
        return UpdateInstallOutcome(
            status: status,
            version: values["version"] ?? "",
            relaunched: values["relaunched"] == "1",
            failure: values["failure"].flatMap(UpdateInstallFailure.init(rawValue:))
        )
    }

    private static func removeQuarantine(from app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    static let helperScript = """
    #!/bin/sh
    set -u
    pid="$1"
    target="$2"
    staged="$3"
    backup="$4"
    log="$5"
    result="$6"
    version="$7"
    relaunch="$8"

    mkdir -p "$(dirname "$log")" || exit 1
    exec >>"$log" 2>&1
    echo "WillyDisk update $(date)"

    write_result() {
        status="$1"
        relaunched="$2"
        failure="$3"
        mkdir -p "$(dirname "$result")" || return 0
        tmp="$result.tmp"
        printf 'status=%s\\nversion=%s\\nrelaunched=%s\\nfailure=%s\\n' \
            "$status" "$version" "$relaunched" "$failure" >"$tmp" && mv "$tmp" "$result"
    }

    reopen() {
        if [ "$relaunch" = "1" ] && [ -d "$target" ]; then
            open -n "$target" >/dev/null 2>&1 || true
        fi
    }

    i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -gt 300 ]; then
            write_result failed 0 waitTimedOut
            exit 1
        fi
        sleep 0.2
    done

    mkdir -p "$(dirname "$backup")" || {
        write_result failed 0 backupFailed
        reopen
        exit 1
    }
    if ! rm -rf "$backup"; then
        write_result failed 0 backupFailed
        reopen
        exit 1
    fi
    if ! mv "$target" "$backup"; then
        write_result failed 0 backupFailed
        reopen
        exit 1
    fi
    if ! ditto "$staged" "$target"; then
        rm -rf "$target"
        mv "$backup" "$target" >/dev/null 2>&1 || true
        write_result failed 0 installFailed
        reopen
        exit 1
    fi
    write_result installed 0 none
    reopen
    exit 0
    """
}
