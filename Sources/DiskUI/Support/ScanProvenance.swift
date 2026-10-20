import Foundation

/// The line that says when the results on screen were gathered.
///
/// A list of sizes with no timestamp reads the same a minute or a week after the
/// scan, while the disk has moved on. The results screen states the scan's start
/// and duration, and a live scan states when it began and how long it has been
/// running, so the numbers are always read in the context that produced them.
public enum ScanProvenance {

    /// A settled scan: when it started and how long it took.
    public static func settled(startedAt: Date, finishedAt: Date) -> String {
        "Scanned \(DateFormat.short(startedAt)) in \(DateFormat.duration(finishedAt.timeIntervalSince(startedAt)))"
    }

    /// A scan still running: when it started and how long it has been going.
    public static func live(startedAt: Date, now: Date) -> String {
        "Scanning since \(DateFormat.short(startedAt)); \(DateFormat.duration(now.timeIntervalSince(startedAt))) so far"
    }

    /// The compact form that fits beside the list's counts. The full text stays
    /// available as the tooltip and the accessibility label.
    public static func compactSettled(startedAt: Date, finishedAt: Date) -> String {
        "Scanned \(DateFormat.dateOnly(startedAt)) in \(DateFormat.duration(finishedAt.timeIntervalSince(startedAt)))"
    }

    /// The compact form for a live scan; the elapsed time still moves.
    public static func compactLive(startedAt: Date, now: Date) -> String {
        "Scanning, \(DateFormat.duration(now.timeIntervalSince(startedAt))) so far"
    }
}
