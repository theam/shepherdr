import Foundation

/// What Shepherdr keeps of the sessions out of sight: each one's terminal, with what it last
/// showed, and the pages in its browser. Going back to one shows it as you left it, instead of
/// connecting and loading again. A terminal costs little; a page holds a web process of tens or
/// hundreds of megabytes. So Shepherdr keeps many terminals and fewer pages, keeps those of the
/// sessions you go back to most, and lets more go when macOS runs short of memory.
public enum SessionCache {
    /// How short of memory macOS is, as it says.
    public enum Pressure: Sendable {
        case normal, warning, critical
    }

    /// How much you go back to a place: each visit adds one, and the total halves every hour. A
    /// session you open all day ranks above one you looked at once a minute ago.
    public struct Interest: Equatable, Sendable {
        public static let halfLife: TimeInterval = 60 * 60
        private var value: Double = 0
        private var at = Date.distantPast

        public init() {}

        public func score(at now: Date) -> Double {
            value * pow(0.5, max(0, now.timeIntervalSince(at)) / Self.halfLife)
        }

        public mutating func visit(at now: Date) {
            value = score(at: now) + 1
            at = now
        }
    }

    /// A terminal or a page, as the policy sees it.
    public struct Item<ID: Hashable & Sendable>: Sendable {
        public let id: ID
        /// It holds something: a terminal or a page, not one already let go.
        public let isLoaded: Bool
        /// It stays whatever happens: on screen, Compass's own, a session that needs you, or a
        /// page that can't load again as it was.
        public let isKept: Bool
        /// Its session's interest now.
        public let interest: Double
        /// When it was last on screen, to tell items of the same interest apart.
        public let lastShown: Date

        public init(id: ID, isLoaded: Bool, isKept: Bool, interest: Double, lastShown: Date) {
            self.id = id
            self.isLoaded = isLoaded
            self.isKept = isKept
            self.interest = interest
            self.lastShown = lastShown
        }
    }

    /// How many terminals stay out of sight, besides those kept.
    public static func terminalLimit(_ pressure: Pressure) -> Int {
        switch pressure {
        case .normal: 24
        case .warning: 8
        case .critical: 2
        }
    }

    /// How many pages stay loaded out of sight, besides those kept.
    public static func pageLimit(_ pressure: Pressure) -> Int {
        switch pressure {
        case .normal: 24
        case .warning: 6
        case .critical: 0
        }
    }

    /// The items to let go so that at most `limit` stay besides those kept: the least interesting
    /// first, and of the same interest, the one seen longest ago.
    public static func toRelease<ID>(_ items: [Item<ID>], limit: Int) -> [ID] {
        let ranked = items.filter { $0.isLoaded && !$0.isKept }.sorted {
            $0.interest != $1.interest ? $0.interest > $1.interest : $0.lastShown > $1.lastShown
        }
        return ranked.dropFirst(max(0, limit)).reversed().map(\.id)
    }
}
