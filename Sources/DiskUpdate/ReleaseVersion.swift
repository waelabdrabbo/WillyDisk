import Foundation

/// A marketing version in the one-to-three-number form `VERSION` uses.
///
/// A release tag carries a leading `v`; the bundle's
/// `CFBundleShortVersionString` does not. Both parse here, and comparison pads
/// missing components with zero, so `1.0` and `1.0.0` are the same version.
/// Nothing in this type compares strings: `1.0.10` is newer than `1.0.9`.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// Exactly three components, with missing trailing components filled with zero.
    public let components: [Int]

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 {
            numbers.append(0)
        }
        components = numbers
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) where left != right {
            return left < right
        }
        return false
    }

    /// Three components, zero-padded. Use a release's `marketingVersion` when the
    /// version must appear exactly as the publisher wrote it.
    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
