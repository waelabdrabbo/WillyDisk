import Foundation
import Darwin

/// A minimal, symlink-safe wrapper around `lstat(2)` / `stat(2)`.
///
/// This is the single place the scanner reads raw `stat`
/// metadata: logical size (`st_size`), allocated size (`st_blocks * 512`),
/// device + inode (loop detection), file type, and modification time.
struct FileStat {
    var error: Int32 = 0          // errno; 0 == success
    var mode: mode_t = 0
    var size: Int64 = 0           // st_size (logical)
    var blocks: Int64 = 0         // st_blocks (512-byte units)
    var dev: dev_t = 0
    var ino: ino_t = 0
    var mtimeSec: Int64 = 0
    var mtimeNsec: Int64 = 0
    /// Allocated bytes when the source reports them directly (bulk directory
    /// reads return an allocation size); `nil` falls back to `st_blocks * 512`.
    var allocatedOverride: Int64? = nil
    /// Whether this entry is a mount point for another file system. Bulk reads
    /// report the *underlying* volume's device for a mount point, so the scanner
    /// needs this flag to keep a scan on one volume.
    var isMountPoint: Bool = false

    /// `st_mode` file-type mask (S_IFMT == 0o170000).
    private static let typeMask: mode_t = 0o170000

    var isDirectory: Bool    { (mode & Self.typeMask) == 0o040000 }
    var isSymlink: Bool      { (mode & Self.typeMask) == 0o120000 }
    var isRegularFile: Bool  { (mode & Self.typeMask) == 0o100000 }

    /// Block/character devices, FIFOs, and sockets — skipped safely.
    var isSpecial: Bool {
        let t = mode & Self.typeMask
        return t == 0o060000 || t == 0o020000 || t == 0o010000 || t == 0o140000
    }

    /// On-disk allocated bytes. Bulk reads return the allocation size directly;
    /// otherwise `st_blocks` (measured in 512-byte blocks) is used.
    var allocatedSize: Int64 { allocatedOverride ?? blocks * 512 }

    var modifiedAt: Date? {
        guard mtimeSec != 0 || mtimeNsec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(mtimeSec) + Double(mtimeNsec) / 1_000_000_000)
    }

    /// `lstat`: reports the link itself, does **not** follow a trailing symlink.
    static func lstat(_ path: String) -> FileStat {
        var st = Darwin.stat()
        let rc = path.withCString { Darwin.lstat($0, &st) }
        return FileStat(rc: rc, st: st)
    }

    /// `stat`: follows symlinks to their target.
    static func statFollowing(_ path: String) -> FileStat {
        var st = Darwin.stat()
        let rc = path.withCString { stat($0, &st) }
        return FileStat(rc: rc, st: st)
    }

    private init(rc: Int32, st: stat) {
        guard rc == 0 else {
            error = errno
            return
        }
        mode = st.st_mode
        size = Int64(st.st_size)
        blocks = Int64(st.st_blocks)
        dev = st.st_dev
        ino = st.st_ino
        mtimeSec = Int64(st.st_mtimespec.tv_sec)
        mtimeNsec = Int64(st.st_mtimespec.tv_nsec)
    }

    /// Direct initializer used when a `stat` result must be constructed without a
    /// syscall — e.g. by `FileSystemAccess` fakes that model a filesystem in
    /// tests. `error` carries an `errno` (0 == success).
    init(
        error: Int32 = 0,
        mode: mode_t = 0,
        size: Int64 = 0,
        blocks: Int64 = 0,
        dev: dev_t = 0,
        ino: ino_t = 0,
        mtimeSec: Int64 = 0,
        mtimeNsec: Int64 = 0,
        allocatedOverride: Int64? = nil,
        isMountPoint: Bool = false
    ) {
        self.error = error
        self.mode = mode
        self.size = size
        self.blocks = blocks
        self.dev = dev
        self.ino = ino
        self.mtimeSec = mtimeSec
        self.mtimeNsec = mtimeNsec
        self.allocatedOverride = allocatedOverride
        self.isMountPoint = isMountPoint
    }
}
