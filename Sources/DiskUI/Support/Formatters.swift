import Foundation
import DiskLocalization

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

/// Abbreviates a path for a dense row, where the full path does not fit.
public enum PathFormat {

    /// The home directory becomes `~`, and a path longer than `maxLength` keeps
    /// its beginning and its end, which are the parts that identify it.
    public static func abbreviated(_ path: String, maxLength: Int = 56) -> String {
        let home = NSHomeDirectory()
        var text = path
        if text == home {
            text = "~"
        } else if text.hasPrefix(home + "/") {
            text = "~" + text.dropFirst(home.count)
        }
        guard text.count > maxLength, maxLength > 1 else { return text }
        let keep = (maxLength - 1) / 2
        return String(text.prefix(keep)) + "…" + String(text.suffix(keep))
    }
}

/// Counts with the right noun, so a folder of one never reads “1 folders”.
///
/// Each noun is one catalog key with plural variations, not a number glued to a
/// word here: English needs two forms, Arabic needs six, and the catalog is the
/// only place that knows the difference.
enum CountFormat {
    static func files(_ count: Int) -> String { L10n.format("%lld files", count) }
    static func folders(_ count: Int) -> String { L10n.format("%lld folders", count) }
    static func items(_ count: Int) -> String { L10n.format("%lld items", count) }
    static func matches(_ count: Int) -> String { L10n.format("%lld matches", count) }
    static func entries(_ count: Int) -> String { L10n.format("%lld entries", count) }
    static func locations(_ count: Int) -> String { L10n.format("%lld locations", count) }
    static func issues(_ count: Int) -> String { L10n.format("%lld issues", count) }
    static func runs(_ count: Int) -> String { L10n.format("%lld runs", count) }
}

/// Share-of-a-whole labels for charts and breakdowns.
public enum PercentFormat {
    /// A whole percentage, never rounding a real slice to 0% or an incomplete
    /// one to 100%: below one percent reads “<1%”, and only a true whole reads
    /// “100%”.
    public static func ofWhole(_ share: Double) -> String {
        let fraction = min(max(share, 0), 1)
        if fraction <= 0 { return L10n.string("0%") }
        if fraction >= 1 { return L10n.string("100%") }
        var percent = Int((fraction * 100).rounded())
        if percent == 0 { return L10n.string("<1%") }
        if percent == 100 { percent = 99 }
        return L10n.format("%lld%%", percent)
    }
}

public enum DateFormat {
    /// Short date + time, e.g. "Oct 13, 2026 at 2:41 PM".
    public static func short(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)
        )
    }

    /// Date without the time, e.g. "Oct 13, 2026".
    public static func dateOnly(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted, locale: L10n.locale)
        )
    }

    /// A date as an interval from `now`, e.g. "2 days ago", in the app's
    /// language. The system formatter carries the named forms — "yesterday",
    /// "now" — that the app would otherwise have to spell out in every
    /// language.
    public static func relative(_ date: Date, relativeTo now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// Duration string for elapsed time, e.g. "1m 23s". A scan that settles
    /// before the first whole second reads as under a second rather than as
    /// zero, which would look like the scan did no work.
    public static func duration(_ interval: TimeInterval) -> String {
        if interval < 1 { return L10n.string("<1s") }
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return L10n.format("%dh %02dm %02ds", hours, minutes, seconds)
        }
        if minutes > 0 {
            return L10n.format("%dm %02ds", minutes, seconds)
        }
        return L10n.format("%ds", seconds)
    }
}
