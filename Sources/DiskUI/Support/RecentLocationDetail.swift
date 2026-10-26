import Foundation
import DiskCore
import DiskLocalization

/// The line under a recent location's name on source selection.
///
/// The last finished run says more than the path: how much the location measured
/// and how long ago it measured it. The path is still the answer when there is no
/// finished run, and when two rows share a display name and only the path can
/// tell them apart.
enum RecentLocationDetail {
    case lastRun(size: String, age: String)
    case path(String)

    var text: String {
        switch self {
        case .lastRun(let size, let age):
            L10n.format("Last scan %@ · %@", size, age)
        case .path(let path):
            path
        }
    }

    /// Whether the row shows a path rather than a measured summary. A path
    /// truncates in the middle, where its distinguishing folders are; a summary
    /// truncates at its end.
    var isPath: Bool {
        if case .path = self { return true }
        return false
    }

    /// The detail for `url`, given its newest finished run and whether another
    /// recent location carries the same display name.
    static func of(
        url: URL,
        record: ScanRecord?,
        nameIsRepeated: Bool,
        now: Date = Date()
    ) -> RecentLocationDetail {
        guard !nameIsRepeated, let record else {
            return .path(PathFormat.abbreviated(url.path))
        }
        return .lastRun(
            size: ByteFormat.string(record.totalLogicalSize),
            age: DateFormat.relative(record.finishedAt, relativeTo: now)
        )
    }
}
