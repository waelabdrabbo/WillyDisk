import Foundation
import DiskCore
import DiskLocalization

/// One `WillyDisk scan` invocation, after the command line has been understood.
///
/// `depth` and `top` decide what the text report prints. They never change what
/// the engine walks: the scan measures the whole folder, and the numbers it
/// prints are that measurement's, not a differently bounded one.
public struct ScanCommand: Sendable, Equatable {

    public var root: URL
    /// Folder levels printed below the scan root. `0` prints only the root.
    public var depth: Int
    /// Rows printed per folder level and per ranked list.
    public var top: Int
    /// Print the versioned `ScanRecord` JSON instead of the text report.
    public var json: Bool

    public static let defaultDepth = 2
    public static let defaultTop = 10

    public init(
        root: URL,
        depth: Int = ScanCommand.defaultDepth,
        top: Int = ScanCommand.defaultTop,
        json: Bool = false
    ) {
        self.root = root
        self.depth = depth
        self.top = top
        self.json = json
    }
}

/// A command line the CLI will not run. The message is the whole explanation;
/// callers add the usage hint and the exit status.
public struct ScanUsageError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum ScanInvocation: Sendable, Equatable {
    case help
    case scan(ScanCommand)
}

/// Reads `WillyDisk scan …` into a `ScanCommand`.
///
/// The parser accepts `--name value` and `--name=value`, and one positional
/// folder. It does not consult the environment or the app's stored scan
/// defaults: a script's scan is the command line it wrote, not the settings a
/// person left in the app.
public enum ScanCommandLine {

    public static func parse(_ arguments: [String]) throws -> ScanInvocation {
        let args = Array(arguments.dropFirst())
        guard let first = args.first else {
            throw ScanUsageError(L10n.string("no command given"))
        }
        if first == "--help" || first == "-h" {
            return .help
        }
        guard first == "scan" else {
            throw ScanUsageError(L10n.format("unknown command '%@'; expected 'scan'", first))
        }
        if args.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            return .help
        }

        var depth = ScanCommand.defaultDepth
        var top = ScanCommand.defaultTop
        var json = false
        var rootPath: String?
        var index = 1

        while index < args.count {
            let argument = args[index]
            switch argument {
            case "--json":
                json = true
                index += 1
            case "--depth", _ where argument.hasPrefix("--depth="):
                let text = try optionValue("--depth", argument, args, &index)
                depth = try wholeNumber(text, name: "--depth", minimum: 0)
            case "--top", _ where argument.hasPrefix("--top="):
                let text = try optionValue("--top", argument, args, &index)
                top = try wholeNumber(text, name: "--top", minimum: 1)
            default:
                if argument.hasPrefix("-") {
                    throw ScanUsageError(L10n.format("unknown option '%@'", argument))
                }
                guard rootPath == nil else {
                    throw ScanUsageError(L10n.format("only one folder can be scanned; '%@' is extra", argument))
                }
                rootPath = argument
                index += 1
            }
        }

        guard let path = rootPath, !path.isEmpty else {
            throw ScanUsageError(L10n.string("missing the folder to scan"))
        }
        return .scan(ScanCommand(root: folderURL(path), depth: depth, top: top, json: json))
    }

    /// A one-line hint printed with a usage error or a failure to start.
    public static var usageHint: String { L10n.string("Run 'WillyDisk scan --help' for usage.") }

    /// The help text's catalog key, which is also its English source. The
    /// placeholders are the print defaults and the record schema version, so the
    /// help can never state a number the code does not use.
    public static let helpKey = """
    WillyDisk scan — measure one folder from the command line

    USAGE
      WillyDisk scan <folder> [--depth <levels>] [--top <rows>] [--json]
      WillyDisk scan --help

    The scan uses the same engine and accounting as the app, with the default scan
    options: hidden items included, no crossing onto another volume, and symbolic
    links not followed. No window opens and no UI is loaded.

    OPTIONS
      --depth <levels>  Folder levels printed below the scan root. 0 prints only
                        the root. Default: %lld.
      --top <rows>      Rows printed per folder level and per ranked list.
                        Default: %lld.
      --json            Print the finished run as the versioned ScanRecord JSON
                        (schema %lld) instead of the text report.
      -h, --help        Show this help and exit.

    --depth and --top change only what is printed. The scan still measures every
    entry it can reach, and the totals, counts, and record list that measurement.

    EXIT STATUS
      0    the scan finished; the report states anything it could not read
      1    the folder does not exist, or the report could not be written
      2    the command line was not understood
      130  interrupted; the engine's cancellation path ran and no report was written

    A cancelled scan writes no report: its totals cover part of the folder, and
    a comparison against them would read as space that vanished.
    """

    public static var help: String {
        L10n.format(
            helpKey,
            ScanCommand.defaultDepth,
            ScanCommand.defaultTop,
            ScanRecord.currentSchemaVersion
        )
    }

    // MARK: - Argument pieces

    private static func optionValue(
        _ name: String,
        _ argument: String,
        _ args: [String],
        _ index: inout Int
    ) throws -> String {
        if let equals = argument.firstIndex(of: "=") {
            let value = String(argument[argument.index(after: equals)...])
            guard !value.isEmpty else {
                throw ScanUsageError(L10n.format("%@ needs a number", name))
            }
            index += 1
            return value
        }
        guard index + 1 < args.count else {
            throw ScanUsageError(L10n.format("%@ needs a number", name))
        }
        index += 2
        return args[index - 1]
    }

    private static func wholeNumber(_ text: String, name: String, minimum: Int) throws -> Int {
        guard let value = Int(text), value >= minimum else {
            throw ScanUsageError(
                L10n.format(
                    "%@ expects a whole number of at least %lld, not '%@'",
                    name,
                    minimum,
                    text
                )
            )
        }
        return value
    }

    /// The path is handed to `URL` whole, which expands a leading tilde a script
    /// may have quoted. Standardizing resolves `..` and returns an absolute path,
    /// so every line the report prints names the same folder from any directory.
    private static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }
}
