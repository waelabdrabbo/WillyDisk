import Foundation
import DiskCore

/// The Categories mode's open category: the files its list shows, and the walk
/// that may replace them.
///
/// The files come from a walk over the whole live tree, and that tree is the one
/// a watched disk keeps editing: the list is refreshed as changes land, on the
/// same interval as the screen's other whole-tree walks. A home folder is
/// millions of entries while the disk keeps changing, so a refresh must never
/// empty the screen while it runs — a detail that dropped its files on every
/// change would spend its life on a spinner and never show what the last walk
/// found. The files therefore stay
/// until a newer walk lands, and a walk that was replaced can never publish:
/// only the walk this detail is waiting for may change what is on screen.
public struct CategoryDetail: Equatable, Sendable {

    /// One walk. Its generation is what tells a walk whose answer is still
    /// wanted from one the screen has moved past.
    public struct Walk: Equatable, Sendable {
        public let category: FileCategory
        let generation: Int
    }

    /// What a refresh request may do now.
    public enum Refresh: Equatable, Sendable {
        /// No category is open.
        case idle
        /// A walk is still out; its answer is newer than one started now, so the
        /// request is dropped rather than replacing it.
        case busy
        /// The last walk started too recently; the next may start at `until`.
        case wait(until: ContinuousClock.Instant)
        /// Start this walk, keeping the files already on screen.
        case start(Walk)
    }

    /// The open category, if the mode is inside one.
    public private(set) var category: FileCategory?
    /// The files the list draws. `nil` only before the first walk of a newly
    /// opened category lands, which is when the screen says it is reading them.
    public private(set) var files: CategoryFiles?
    /// Whether a walk this detail started is still out.
    public private(set) var isLoading = false
    /// When the walk showing now, or the one that is out, started.
    public private(set) var walkStartedAt: ContinuousClock.Instant?
    private var generation = 0

    public init() {}

    public var isOpen: Bool { category != nil }

    /// The walk whose answer this detail will take, while one is out.
    public var pendingWalk: Walk? {
        guard isLoading, let category else { return nil }
        return Walk(category: category, generation: generation)
    }

    /// Opens a category on an empty list: its files are new, so what was shown
    /// for another category never stands in for them.
    public mutating func open(_ category: FileCategory, at now: ContinuousClock.Instant) -> Walk {
        generation &+= 1
        self.category = category
        files = nil
        isLoading = true
        walkStartedAt = now
        return Walk(category: category, generation: generation)
    }

    /// Closes the open category and retires its walk.
    public mutating func close() {
        generation &+= 1
        category = nil
        files = nil
        isLoading = false
        walkStartedAt = nil
    }

    /// Asks for a walk that keeps the files the list already has.
    public mutating func refresh(at now: ContinuousClock.Instant, interval: Duration) -> Refresh {
        guard let category else { return .idle }
        if isLoading { return .busy }
        if let started = walkStartedAt, now < started.advanced(by: interval) {
            return .wait(until: started.advanced(by: interval))
        }
        generation &+= 1
        isLoading = true
        walkStartedAt = now
        return .start(Walk(category: category, generation: generation))
    }

    /// Publishes a walk's answer when that walk is still the newest.
    ///
    /// A replaced walk, or one that outlived the category it was started for,
    /// returns false and changes nothing, so the list keeps what the newest
    /// answer put there.
    @discardableResult
    public mutating func accept(_ result: CategoryFiles, from walk: Walk) -> Bool {
        guard walk == pendingWalk, result.category == walk.category else { return false }
        files = result
        isLoading = false
        return true
    }

    /// The walk ended without an answer — cancelled, or the tree went away — and
    /// the list keeps what it had.
    public mutating func end(_ walk: Walk) {
        guard walk == pendingWalk else { return }
        isLoading = false
    }
}
