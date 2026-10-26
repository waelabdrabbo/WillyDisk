import Foundation
import DiskCore
import DiskLocalization

/// One `WillyDisk cleanup` invocation, after the command line has been
/// understood.
///
/// The command reads a folder with the scan engine and then lists what the
/// cleanup rules find. It never moves, trashes, or deletes anything: a move is
/// the app's job, behind its confirmation.
public struct CleanupCommand: Sendable, Equatable {
    public var root: URL
    /// Print the versioned `CleanupRecord` JSON instead of the text report.
    public var json: Bool
    /// Read the size-matched duplicates and compare their contents.
    public var checksContents: Bool
    /// The thresholds the analysis runs under. The app's standard policy unless
    /// a caller says otherwise; there is no command-line way to change it yet.
    public var policy: CleanupPolicy

    public init(
        root: URL,
        json: Bool = false,
        checksContents: Bool = false,
        policy: CleanupPolicy = .standard
    ) {
        self.root = root
        self.json = json
        self.checksContents = checksContents
        self.policy = policy
    }
}

/// Reads `WillyDisk cleanup …` into a `CleanupCommand`.
public enum CleanupCommandLine {

    public static func parse(_ arguments: [String]) throws -> ScanInvocation {
        var json = false
        var checksContents = false
        var rootPath: String?
        var index = 0

        if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
            return .cleanupHelp
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json":
                json = true
                index += 1
            case "--check-contents":
                checksContents = true
                index += 1
            default:
                if argument.hasPrefix("-") {
                    throw ScanUsageError(L10n.format("unknown option '%@'", argument))
                }
                guard rootPath == nil else {
                    throw ScanUsageError(
                        L10n.format("only one folder can be reviewed; '%@' is extra", argument)
                    )
                }
                rootPath = argument
                index += 1
            }
        }

        guard let path = rootPath, !path.isEmpty else {
            throw ScanUsageError(L10n.string("missing the folder to review"))
        }
        return .cleanup(CleanupCommand(
            root: URL(fileURLWithPath: path).standardizedFileURL,
            json: json,
            checksContents: checksContents
        ))
    }

    /// A one-line hint printed when a cleanup invocation fails to start.
    public static var usageHint: String {
        L10n.string("Run 'WillyDisk cleanup --help' for usage.")
    }

    /// The help text's catalog key, which is also its English source. The
    /// placeholders are the policy's own numbers and the record's schema
    /// version, so the help can never state a number the code does not use.
    public static let helpKey = """
    WillyDisk cleanup — list cleanup candidates inside one folder

    USAGE
      WillyDisk cleanup <folder> [--json] [--check-contents]
      WillyDisk cleanup --help

    Reads the folder with the same engine and accounting as `WillyDisk scan`,
    then applies the cleanup rules the app's Cleanup sheet uses. It only lists:
    nothing is moved, trashed, or deleted, and no window opens.

    RULES
      Caches, device support, simulators, and logs are offered as one folder
      each, with the subtree left unwalked. A large old file must take at least
      %@ on disk and be unchanged for %@; an old download must be unchanged for
      %@. Duplicate candidates are same-size files of at least %@, listed for
      the largest %lld size groups with at most %lld files each.

    OPTIONS
      --json             Print the versioned CleanupRecord JSON (schema %lld)
                         instead of the text report.
      --check-contents   Read the size-matched candidates and compare SHA-256
                         digests. Off by default: it reads every candidate.
      -h, --help         Show this help and exit.

    EXIT STATUS
      0    the analysis ran; the report states anything it could not read
      1    the folder does not exist, or the report could not be written
      2    the command line was not understood
      130  interrupted; no report was written

    Sizes are bytes on disk, not logical sizes: a cleanup finding is what moving
    it would free once the Trash is emptied, and this command never claims a
    saving.
    """

    public static var help: String {
        let policy = CleanupPolicy.standard
        return L10n.format(
            helpKey,
            ByteCountFormatter.string(fromByteCount: policy.largeFileMinimum, countStyle: .file),
            age(policy.largeFileAge),
            age(policy.downloadAge),
            ByteCountFormatter.string(fromByteCount: policy.duplicateMinimum, countStyle: .file),
            policy.maxDuplicateGroups,
            policy.maxDuplicateFilesPerGroup,
            CleanupOutput.currentSchemaVersion
        )
    }

    private static func age(_ interval: TimeInterval) -> String {
        let days = Int(interval / 86_400)
        if days >= 360 {
            return L10n.format("%lld years", max(1, days / 365))
        }
        if days >= 30 {
            return L10n.format("%lld months", max(1, days / 30))
        }
        return L10n.format("%lld days", max(1, days))
    }
}
