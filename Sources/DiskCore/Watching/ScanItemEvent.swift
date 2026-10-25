import Foundation
import CoreServices

/// One FSEvents item event reduced to what it can change in a scan's numbers.
///
/// FSEvents reports items, never totals: a file that grew, an entry that
/// appeared, a name that moved. A scan measures bytes and entry counts, so an
/// event that carries no creation, removal, rename, or write cannot have moved a
/// byte or an entry count. Attribute, owner, extended-attribute, and clone
/// metadata arrive that way, and a busy root produces them continuously —
/// re-listing a folder for them would describe churn a person never caused.
enum ScanItemEvent {
    /// Flags naming a change a scan measures: an entry appeared, went away,
    /// moved, or its bytes were written.
    private static let contentFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)

    /// Flags naming an entry that arrived, went away, or moved, which changes
    /// the entries of the folder that holds it rather than a folder's contents.
    private static let entryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)

    private static let directoryFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)

    /// Whether the event can change a folder's bytes or entry count.
    static func changesMeasuredContents(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & contentFlags != 0
    }

    /// The folder whose measured contents the event changes.
    ///
    /// A file's event changes the bytes counted under the folder that holds it;
    /// a directory that arrived, went away, or was renamed changes the entries
    /// of the folder that holds it, while a directory whose own entries changed
    /// is the folder itself.
    static func folderPath(for path: String, flags: FSEventStreamEventFlags) -> String {
        let isDirectory = flags & directoryFlag != 0
        if isDirectory && flags & entryFlags == 0 { return path }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? path : parent
    }
}
