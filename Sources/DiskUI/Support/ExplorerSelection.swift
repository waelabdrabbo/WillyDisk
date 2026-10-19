import Foundation

/// What the explorer has selected, and where the keyboard cursor is.
///
/// Selection is held as URLs rather than as nodes: the engine rebuilds every
/// node value on each progressive snapshot, and the list's own order is the only
/// ordering that matters for a range. A URL stays valid exactly as long as the
/// item it names is still in the list, so a live scan can replace the nodes
/// underneath a selection without disturbing it.
///
/// The anchor is the row a shift-click range extends from. The focused row is
/// the keyboard cursor: normally one of the selected rows, but a command-click
/// that removes a row keeps it as the cursor so the arrows can continue from
/// where the pointer left off.
struct ExplorerSelection: Equatable, Sendable {
    private(set) var urls: Set<URL> = []
    private(set) var anchor: URL?
    private(set) var focused: URL?

    init() {}

    var isEmpty: Bool { urls.isEmpty }
    var count: Int { urls.count }

    func contains(_ url: URL) -> Bool { urls.contains(url) }

    /// Applies one click to the selection.
    ///
    /// A plain click selects only the row, a command-click toggles it, and a
    /// shift-click extends from the anchor through the rows in list order. Shift
    /// wins when both modifiers are held, matching the extended selection a
    /// command-shift click draws.
    mutating func click(_ url: URL, in order: [URL], toggling: Bool = false, extending: Bool = false) {
        if extending {
            if let span = span(to: url, in: order) {
                urls = span
                focused = url
            } else {
                // An anchor that is not in the list cannot describe a range.
                selectOnly(url)
            }
            return
        }
        if toggling {
            if urls.contains(url) {
                urls.remove(url)
            } else {
                urls.insert(url)
            }
            anchor = url
            focused = url
            return
        }
        selectOnly(url)
    }

    /// Replaces the selection with one row, making it both the anchor and the
    /// keyboard cursor.
    mutating func selectOnly(_ url: URL) {
        urls = [url]
        anchor = url
        focused = url
    }

    /// Moves the cursor `offset` rows through `order` and selects the row it
    /// lands on. Extending keeps the anchor and grows a range from it.
    @discardableResult
    mutating func move(by offset: Int, in order: [URL], extending: Bool) -> URL? {
        guard !order.isEmpty else { return nil }
        let next: Int
        if let current = focused.flatMap({ order.firstIndex(of: $0) }) {
            next = min(max(current + offset, 0), order.count - 1)
        } else {
            next = offset < 0 ? order.count - 1 : 0
        }
        return select(order[next], in: order, extending: extending)
    }

    /// Moves the cursor to an absolute row — Home and End.
    @discardableResult
    mutating func jump(to index: Int, in order: [URL], extending: Bool) -> URL? {
        guard !order.isEmpty else { return nil }
        return select(order[min(max(index, 0), order.count - 1)], in: order, extending: extending)
    }

    /// Drops every selected or focused URL that is no longer in the list, which
    /// is what keeps a live scan's new snapshots from leaving a selection
    /// pointing at a row that has already gone.
    ///
    /// `available` is in list order, so the surviving cursor is the anchor when
    /// it is still there and otherwise the first surviving row in that order.
    mutating func prune(to available: [URL]) {
        let present = Set(available)
        urls.formIntersection(present)
        if let current = focused, !present.contains(current) {
            if let anchor, present.contains(anchor) {
                focused = anchor
            } else {
                focused = available.first(where: urls.contains)
            }
        }
        if let current = anchor, !present.contains(current) {
            anchor = focused
        }
        if urls.isEmpty {
            anchor = nil
        }
    }

    mutating func clear() {
        urls.removeAll()
        anchor = nil
        focused = nil
    }

    /// Selects `url`, extending from the anchor when asked. Falls back to a
    /// single selection when the anchor is not part of the list — a stale anchor
    /// must never leave a range that spans the wrong rows.
    private mutating func select(_ url: URL, in order: [URL], extending: Bool) -> URL {
        if extending, let span = span(to: url, in: order) {
            urls = span
        } else {
            urls = [url]
            anchor = url
        }
        focused = url
        return url
    }

    private func span(to url: URL, in order: [URL]) -> Set<URL>? {
        guard let start = anchor ?? focused,
              let from = order.firstIndex(of: start),
              let to = order.firstIndex(of: url) else { return nil }
        return Set(order[min(from, to)...max(from, to)])
    }
}
