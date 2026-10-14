import Foundation

/// Formatting helpers shared across the UI.
///
/// Byte sizes use `ByteCountFormatter` so they match Finder conventions
/// (e.g. "1.5 GB"). Dates use relative/absolute formatting via the system.
public enum ByteFormat {

    /// Short human-readable size, e.g. "1.5 GB".
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatterCache.shared.string(bytes, .short)
    }

    /// Exact, unit-always size for detail views, e.g. "1,532,341 bytes".
    public static func exact(_ bytes: Int64) -> String {
        ByteCountFormatterCache.shared.string(bytes, .exact)
    }

    /// Compact byte count for dense labels, e.g. "1.5GB".
    public static func compact(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
            .replacingOccurrences(of: " ", with: "")
    }
}

/// Reuses `ByteCountFormatter`s instead of building one per call.
///
/// A `ByteCountFormatter` is comparatively expensive to construct, and the
/// explorer formats a value for every row it draws; building one per call put
/// that allocation on the render path for a list that can hold hundreds of rows.
/// The formatters are mutable reference types that are not `Sendable`, so they
/// are kept behind a lock and only used while it is held.
private final class ByteCountFormatterCache: @unchecked Sendable {

    enum Style { case short, exact }

    static let shared = ByteCountFormatterCache()

    private let lock = NSLock()
    private var formatters: [Style: ByteCountFormatter] = [:]

    func string(_ bytes: Int64, _ style: Style) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter = formatters[style] ?? makeFormatter(style)
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func makeFormatter(_ style: Style) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        switch style {
        case .short:
            break
        case .exact:
            formatter.includesCount = true
            formatter.allowsNonnumericFormatting = false
        }
        formatters[style] = formatter
        return formatter
    }
}

public enum DateFormat {
    /// Short date + time, e.g. "Oct 13, 2026 at 2:41 PM".
    public static func short(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Duration string for elapsed time, e.g. "1m 23s".
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return String(format: "%ds", seconds)
    }
}
