import Foundation
import Testing
@testable import ShepherdrCore

struct SessionCacheTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(_ id: String, interest: Double, minutesAgo: Double = 0, loaded: Bool = true,
                      kept: Bool = false) -> SessionCache.Item<String> {
        SessionCache.Item(id: id, isLoaded: loaded, isKept: kept, interest: interest,
                          lastShown: now.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func sessionsYouGoBackToOutrankOneYouJustLookedAt() {
        var often = SessionCache.Interest(), once = SessionCache.Interest()
        for minutes in [0.0, 20, 40, 60, 80] { often.visit(at: now.addingTimeInterval(minutes * 60)) }
        once.visit(at: now.addingTimeInterval(99 * 60))
        let later = now.addingTimeInterval(100 * 60)
        #expect(often.score(at: later) > once.score(at: later))
        // Interest halves every hour, until a visit adds to it again.
        #expect(abs(once.score(at: now.addingTimeInterval(159 * 60)) - 0.5) < 0.001)
        #expect(SessionCache.Interest().score(at: now) == 0)
    }

    @Test func theLeastInterestingGoFirstBeyondTheLimit() {
        let items = [item("busy", interest: 3), item("seen", interest: 0.2, minutesAgo: 1), item("old", interest: 0.2, minutesAgo: 30),
                     item("top", interest: 5), item("shown", interest: 0, kept: true), item("gone", interest: 9, loaded: false)]
        // Kept items and those already let go don't count.
        #expect(SessionCache.toRelease(items, limit: 4).isEmpty)
        #expect(SessionCache.toRelease(items, limit: 2) == ["old", "seen"])
        #expect(SessionCache.toRelease(items, limit: 0) == ["old", "seen", "busy", "top"])
    }

    @Test func shortOfMemoryLessStays() {
        for limit in [SessionCache.terminalLimit, SessionCache.pageLimit] {
            #expect(limit(.normal) > limit(.warning) && limit(.warning) > limit(.critical))
        }
        #expect(SessionCache.pageLimit(.critical) == 0)
        // Terminals cost far less than pages, so more of them stay.
        #expect(SessionCache.terminalLimit(.normal) >= SessionCache.pageLimit(.normal))
    }
}
