import Foundation
import Darwin

/// One immediate child of a directory: the name plus the metadata the same bulk
/// enumeration call returned for it.
struct DirectoryEntry {
    var name: String
    var stat: FileStat
}

/// Enumerates the immediate children of one directory.
///
/// A reader may own scratch space, so each traversal worker uses its own
/// instance and never shares one across threads.
protocol DirectoryReading: Sendable {
    func read(path: String) throws -> [DirectoryEntry]
}

/// Reads a directory's immediate children with their metadata in bulk.
///
/// A depth-first scan needs, for every entry, the same handful of fields: the
/// object type, device and inode (duplicate-subtree and loop detection), logical
/// size, allocated size and modification time. Asking `lstat(2)` for each entry
/// costs one syscall per entry and a second directory read on top of the
/// enumeration. `getattrlistbulk(2)` returns all of it for a whole batch of
/// entries per call, which is where most of a full-disk scan's syscall time
/// goes.
///
/// The kernel packs one *group* per entry: a `uint32` group length, an
/// `attribute_set_t` describing which attributes came back, then the attribute
/// values in bitmap order. Variable-length values (the name) live at the end of
/// the group and are reached through an `attrreference`. Attributes that the
/// entry or the file system cannot provide are simply omitted, so parsing always
/// follows the returned-attributes set rather than assuming a fixed layout.
///
/// Instances hold one reusable read buffer. A scan enumerates hundreds of
/// thousands of directories; allocating and clearing a fresh buffer for each one
/// costs more than the syscalls it feeds. An instance is confined to a single
/// traversal worker, which is why it is `@unchecked Sendable`.
final class DirectoryReader: DirectoryReading, @unchecked Sendable {

    /// Bytes requested per `getattrlistbulk` call. Large enough that a typical
    /// directory is read in a single call, small enough to stay cache-friendly.
    private static let defaultBufferSize = 128 * 1024
    private static let maximumBufferSize = 4 * 1024 * 1024

    private var buffer: [UInt8]

    init(bufferSize: Int = DirectoryReader.defaultBufferSize) {
        self.buffer = [UInt8](repeating: 0, count: bufferSize)
    }

    // MARK: - Attribute bitmaps

    /// `sys/attr.h` bit values. They are written out because the SDK imports the
    /// `ATTR_*` macros as signed `Int32` while `attrlist` bitmaps are
    /// `attrgroup_t` (`UInt32`).
    private enum Attribute {
        static let returnedAttrs: attrgroup_t = 0x8000_0000
        static let name: attrgroup_t = 0x0000_0001
        static let deviceID: attrgroup_t = 0x0000_0002
        static let objectType: attrgroup_t = 0x0000_0008
        static let modificationTime: attrgroup_t = 0x0000_0400
        static let fileID: attrgroup_t = 0x0200_0000
        static let mountStatus: attrgroup_t = 0x0000_0004
        static let allocatedSize: attrgroup_t = 0x0000_0004
        static let dataLength: attrgroup_t = 0x0000_0200
        static let mountPointFlag: attrgroup_t = 0x0000_0001
    }

    private static let commonAttributes = Attribute.returnedAttrs | Attribute.name | Attribute.deviceID
        | Attribute.objectType | Attribute.modificationTime | Attribute.fileID
    private static let directoryAttributes = Attribute.mountStatus
    private static let fileAttributes = Attribute.dataLength | Attribute.allocatedSize

    // MARK: - Object types (`enum vtype`)

    private static let vdir = 2
    private static let vreg = 1
    private static let vblk = 3
    private static let vchr = 4
    private static let vlnk = 5
    private static let vsock = 6
    private static let vfifo = 7

    // MARK: - Entry point

    /// Every immediate child of `path`, with metadata. Throws a POSIX error when
    /// the directory cannot be opened or read.
    func read(path: String) throws -> [DirectoryEntry] {
        let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }

        var attributeList = attrlist()
        attributeList.bitmapcount = u_short(5)   // ATTR_BIT_MAP_COUNT
        attributeList.commonattr = Self.commonAttributes
        attributeList.dirattr = Self.directoryAttributes
        attributeList.fileattr = Self.fileAttributes

        var entries: [DirectoryEntry] = []

        while true {
            let entryCount = buffer.withUnsafeMutableBytes { raw -> Int32 in
                getattrlistbulk(descriptor, &attributeList, raw.baseAddress, raw.count, 0)
            }

            if entryCount < 0 {
                if errno == ERANGE, buffer.count < Self.maximumBufferSize {
                    buffer = [UInt8](repeating: 0, count: min(buffer.count * 4, Self.maximumBufferSize))
                    continue
                }
                throw Self.posixError()
            }
            if entryCount == 0 { break }

            buffer.withUnsafeBytes { raw in
                Self.parse(raw, path: path, entryCount: Int(entryCount), into: &entries)
            }
        }

        return entries
    }

    // MARK: - Parsing

    private static func parse(
        _ raw: UnsafeRawBufferPointer,
        path: String,
        entryCount: Int,
        into entries: inout [DirectoryEntry]
    ) {
        var offset = 0
        for _ in 0..<entryCount {
            guard offset + 4 <= raw.count else { return }
            let groupLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard groupLength >= 4, offset + groupLength <= raw.count else { return }
            let groupEnd = offset + groupLength

            // The returned-attributes set is always first and is not preceded by
            // a length, so it is the anchor for everything that follows.
            guard offset + 24 <= groupEnd else { return }
            let returned = readAttributeSet(raw, at: offset + 4)
            var cursor = offset + 24

            var stat = FileStat()
            var objectType: UInt32 = 0

            var name = ""
            if returned.commonattr & Attribute.name != 0 {
                guard cursor + 8 <= groupEnd else { return }
                let dataOffset = Int(raw.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
                let dataLength = Int(raw.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
                let nameStart = cursor + dataOffset
                // `attr_length` counts the terminating NUL.
                let nameEnd = nameStart + max(0, dataLength - 1)
                if dataOffset > 0, nameStart >= offset, nameEnd <= groupEnd {
                    name = String(decoding: raw[nameStart..<nameEnd], as: UTF8.self)
                }
                cursor += 8
            }

            if returned.commonattr & Attribute.deviceID != 0 {
                guard cursor + 4 <= groupEnd else { return }
                stat.dev = dev_t(bitPattern: raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
                cursor += 4
            }

            if returned.commonattr & Attribute.objectType != 0 {
                guard cursor + 4 <= groupEnd else { return }
                objectType = raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                stat.mode = typeBits(forObjectType: objectType)
                cursor += 4
            }

            if returned.commonattr & Attribute.modificationTime != 0 {
                guard cursor + 16 <= groupEnd else { return }
                stat.mtimeSec = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
                stat.mtimeNsec = raw.loadUnaligned(fromByteOffset: cursor + 8, as: Int64.self)
                cursor += 16
            }

            if returned.commonattr & Attribute.fileID != 0 {
                guard cursor + 8 <= groupEnd else { return }
                stat.ino = ino_t(raw.loadUnaligned(fromByteOffset: cursor, as: UInt64.self))
                cursor += 8
            }

            if returned.dirattr & Attribute.mountStatus != 0 {
                guard cursor + 4 <= groupEnd else { return }
                let status = raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                stat.isMountPoint = status & Attribute.mountPointFlag != 0
                cursor += 4
            }

            if returned.fileattr & Attribute.allocatedSize != 0 {
                guard cursor + 8 <= groupEnd else { return }
                stat.allocatedOverride = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
                cursor += 8
            }

            if returned.fileattr & Attribute.dataLength != 0 {
                guard cursor + 8 <= groupEnd else { return }
                stat.size = raw.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
                cursor += 8
            }

            if !name.isEmpty {
                if attributesAreComplete(
                    commonattr: returned.commonattr,
                    fileattr: returned.fileattr,
                    objectType: objectType
                ) {
                    entries.append(DirectoryEntry(name: name, stat: stat))
                } else {
                    // The kernel can leave attributes out for an entry it could
                    // not inspect. Reading the metadata directly is the only way
                    // to keep the entry truthful, and it is rare enough that the
                    // extra call costs nothing overall.
                    var fallback = FileStat.lstat(joinedPath(directory: path, name: name))
                    if fallback.error != 0 {
                        fallback.mode = stat.mode
                    }
                    entries.append(DirectoryEntry(name: name, stat: fallback))
                }
            }
            offset = groupEnd
        }
    }

    private struct AttributeSet {
        var commonattr: UInt32 = 0
        var volattr: UInt32 = 0
        var dirattr: UInt32 = 0
        var fileattr: UInt32 = 0
        var forkattr: UInt32 = 0
    }

    private static func readAttributeSet(_ raw: UnsafeRawBufferPointer, at offset: Int) -> AttributeSet {
        AttributeSet(
            commonattr: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self),
            volattr: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
            dirattr: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self),
            fileattr: raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self),
            forkattr: raw.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self)
        )
    }

    /// Translate `enum vtype` into the `st_mode` file-type bits the rest of the
    /// scanner already understands.
    private static func typeBits(forObjectType objectType: UInt32) -> mode_t {
        switch Int(objectType) {
        case vdir: return 0o040000
        case vreg: return 0o100000
        case vblk: return 0o060000
        case vchr: return 0o020000
        case vlnk: return 0o120000
        case vsock: return 0o140000
        case vfifo: return 0o010000
        default: return 0
        }
    }

    /// Whether the kernel returned everything the scan reads for an entry.
    ///
    /// A group that is missing the object type, the device/inode pair or a
    /// regular file's sizes cannot be used as-is: the entry would be
    /// misclassified or silently sized at zero, which is exactly the kind of
    /// fabricated number the scan must never report.
    static func attributesAreComplete(commonattr: UInt32, fileattr: UInt32, objectType: UInt32) -> Bool {
        let hasType = commonattr & Attribute.objectType != 0
        let hasDevice = commonattr & Attribute.deviceID != 0
        let hasIdentity = commonattr & Attribute.fileID != 0
        guard hasType, hasDevice, hasIdentity else { return false }

        let carriesData = Int(objectType) == vreg || Int(objectType) == vlnk
        guard carriesData else { return true }
        return fileattr & Attribute.dataLength != 0 && fileattr & Attribute.allocatedSize != 0
    }

    private static func joinedPath(directory: String, name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
