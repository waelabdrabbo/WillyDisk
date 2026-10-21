import Foundation
import DiskCore

/// One category's slice of a scan's logical total.
public struct CategoryShare: Identifiable, Equatable, Sendable {
    public let category: FileCategory
    public let logicalSize: Int64
    /// Fraction of the scan's total logical size, 0...1. `0` when the scan has no
    /// bytes to divide.
    public let share: Double

    public var id: FileCategory { category }

    public init(category: FileCategory, logicalSize: Int64, share: Double) {
        self.category = category
        self.logicalSize = logicalSize
        self.share = share
    }
}

/// The scan's logical bytes grouped by file category, largest first.
///
/// The source is `ScanSummary.categoryBreakdown`, which counts files by their
/// logical size: directories themselves carry no bytes, so the slice of a folder
/// is the files inside it. Hard links are counted once per link and dataless
/// files at their logical size, exactly as the totals are; the coverage sheet
/// owns that explanation rather than this chart restating it.
public struct CategoryBreakdown: Equatable, Sendable {
    public let shares: [CategoryShare]
    public let totalLogicalSize: Int64

    /// Shares of `totalLogicalSize`. Categories with no bytes are left out: a
    /// zero row would be a rank with nothing to draw.
    public init(categoryBreakdown: [FileCategory: Int64], totalLogicalSize: Int64) {
        let total = max(0, totalLogicalSize)
        self.totalLogicalSize = total
        self.shares = categoryBreakdown
            .filter { $0.value > 0 }
            .map { category, size in
                CategoryShare(
                    category: category,
                    logicalSize: size,
                    share: total > 0 ? min(1, Double(size) / Double(total)) : 0
                )
            }
            .sorted {
                $0.logicalSize == $1.logicalSize
                    ? $0.category.rawValue < $1.category.rawValue
                    : $0.logicalSize > $1.logicalSize
            }
    }

    public init(summary: ScanSummary) {
        self.init(
            categoryBreakdown: summary.categoryBreakdown,
            totalLogicalSize: summary.totalLogicalSize
        )
    }

    /// Bytes this breakdown accounts for, which is the scan total unless the
    /// engine classified fewer bytes than it counted.
    public var accountedSize: Int64 {
        shares.reduce(0) { $0 + $1.logicalSize }
    }

    public var isEmpty: Bool { shares.isEmpty }

    /// The share one category holds, for marking the active filter.
    public func share(of category: FileCategory) -> CategoryShare? {
        shares.first { $0.category == category }
    }
}
