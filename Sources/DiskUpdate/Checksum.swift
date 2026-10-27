import CryptoKit
import Foundation

/// A lowercase SHA-256 digest.
public struct SHA256Digest: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = Set("0123456789abcdef")
        guard trimmed.count == 64, trimmed.allSatisfy({ digits.contains($0) }) else {
            return nil
        }
        hex = trimmed
    }

    public var description: String { hex }
}

/// The checksum file a release publishes, and the hash of the archive it names.
public enum ChecksumFile {
    /// A `.sha256` is one line. This is generous by three orders of magnitude and
    /// still refuses to read an arbitrary file from a download directory into memory.
    public static let maximumSize = 1 << 20

    /// Parses `shasum -a 256` output and requires it to name the archive we asked for.
    ///
    /// The name check is what catches a checksum file that belongs to another
    /// architecture: a valid digest for the wrong zip would otherwise verify.
    public static func parse(_ text: String, expecting fileName: String) throws -> SHA256Digest {
        let lines = text.split(whereSeparator: { $0.isNewline }).filter {
            !String($0).trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard lines.count == 1, let line = lines.first else {
            throw UpdateError.checksumMalformed
        }
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 2,
              let digest = SHA256Digest(String(fields[0])) else {
            throw UpdateError.checksumMalformed
        }
        var publishedName = String(fields[1])
        if publishedName.hasPrefix("*") {
            publishedName.removeFirst()
        }
        guard publishedName == fileName else {
            throw UpdateError.checksumNameMismatch(expected: fileName, found: publishedName)
        }
        return digest
    }

    /// Hashes a file without loading it whole.
    public static func digestOfFile(at url: URL) throws -> SHA256Digest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UpdateError.archiveMissing
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw UpdateError.archiveUnreadable
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw UpdateError.archiveUnreadable
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let digest = SHA256Digest(hex) else {
            throw UpdateError.checksumMalformed
        }
        return digest
    }
}
