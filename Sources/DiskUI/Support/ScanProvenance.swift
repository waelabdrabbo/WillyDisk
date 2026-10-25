import Foundation
import DiskLocalization

/// The line that says when the run behind the results was gathered and how long
/// it took.
///
/// The coverage sheet states it, so a screen's numbers are read in the context
/// that produced them. The results header does not: the numbers there follow the
/// disk, and a timestamp beside them would describe a moment they have left.
public enum ScanProvenance {

    /// A settled scan: when it started, to the minute, and how long it took.
    public static func settled(startedAt: Date, finishedAt: Date) -> String {
        L10n.format(
            "Scanned %@ in %@",
            DateFormat.short(startedAt),
            DateFormat.duration(finishedAt.timeIntervalSince(startedAt))
        )
    }

    /// The compact form for the chart's foot: the date and the duration, with the
    /// time of day left to the tooltip.
    public static func compactSettled(startedAt: Date, finishedAt: Date) -> String {
        L10n.format(
            "Scanned %@ in %@",
            DateFormat.dateOnly(startedAt),
            DateFormat.duration(finishedAt.timeIntervalSince(startedAt))
        )
    }
}
