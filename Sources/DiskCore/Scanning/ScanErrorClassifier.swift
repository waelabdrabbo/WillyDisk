import Foundation
import Darwin

/// Why a non-fatal problem occurred while scanning. `Sendable` so it can be
/// carried across the engine/UI boundary.
///
/// Classifying lets the engine treat permission denial — an *expected* outcome
/// when scanning a whole volume without Full Disk Access — differently from real
/// faults (broken links, I/O errors).
///
/// This is the classification vocabulary the shared `ScanEvent`/`ScanSummary`
/// contract is expected to carry (so the UI can distinguish a missing-access
/// summary from a hard error). It is public for that reason; the engine speaks
/// it internally today and will surface it once the frozen contract exposes a
/// classified issue case.
public enum ScanIssueKind: Sendable, Hashable {
    /// `EPERM`/`EACCES`: the process is not allowed to read the entry. Expected
    /// on protected locations (TCC) during a full-disk scan.
    case permissionDenied
    /// A symlink whose target no longer exists (or loops).
    case brokenSymlink
    /// A hardware/filesystem error (`EIO`, read-only volume, …).
    case io
    /// Anything else.
    case other
}

/// Maps POSIX `errno`s and thrown `FileManager` errors to a `ScanIssueKind`.
enum ScanErrorClassifier {

    /// Classify a POSIX `errno` reported by `lstat`/`stat`.
    static func kind(errno code: Int32) -> ScanIssueKind {
        switch code {
        case EACCES, EPERM:
            return .permissionDenied
        case EIO, ENXIO, ENODEV, EROFS, ENOTCONN, ETIMEDOUT:
            return .io
        default:
            return .other
        }
    }

    /// The POSIX `errno` behind a thrown `FileManager` error, if any.
    ///
    /// Foundation wraps the syscall failure in `NSCocoaErrorDomain` (e.g. code
    /// 257 == `NSFileReadNoPermissionError`) with an `NSPOSIXErrorDomain`
    /// underlying error — that underlying code is the `EPERM`/`EACCES` we need.
    static func posixErrno(from error: Error) -> Int32? {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return Int32(ns.code)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return EACCES
            case NSFileReadNoSuchFileError:
                return ENOENT
            default:
                break
            }
        }
        return nil
    }

    /// Classify a thrown `contentsOfDirectory` error.
    static func kind(for error: Error) -> ScanIssueKind {
        guard let code = posixErrno(from: error) else { return .other }
        return kind(errno: code)
    }

    /// Human-readable text for an `errno` (`strerror`).
    static func message(for code: Int32) -> String {
        String(cString: strerror(code))
    }
}
