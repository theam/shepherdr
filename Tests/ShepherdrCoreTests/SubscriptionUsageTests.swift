import Foundation
import Testing
@testable import ShepherdrCore

struct SubscriptionUsageTests {
    private let answer = Data("""
    {"five_hour":{"utilization":3.0,"resets_at":"2026-10-22T22:10:00.436446+00:00"},
     "seven_day":{"utilization":59.6,"resets_at":"2026-10-24T12:00:00+00:00"},
     "extra_usage":{"is_enabled":false,"utilization":0.0}}
    """.utf8)

    @Test func readsBothLimitsAndTheirResets() throws {
        let usage = try #require(SubscriptionUsage.parse(answer))
        #expect(usage.session?.percent == 3)
        #expect(usage.week?.percent == 60)
        #expect(usage.session?.resetsAt != nil)
        #expect(usage.week?.resetsAt == Date(timeIntervalSince1970: 1792843200))
    }

    @Test func anAnswerWithoutLimitsIsNoData() {
        #expect(SubscriptionUsage.parse(Data("{}".utf8)) == nil)
        #expect(SubscriptionUsage.parse(Data("nope".utf8)) == nil)
    }

    @Test func saysHowLongIsLeft() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(SubscriptionUsage.untilReset(now.addingTimeInterval(130 * 60), now: now) == "in 2h 10m")
        #expect(SubscriptionUsage.untilReset(now.addingTimeInterval(40 * 60), now: now) == "in 40m")
        #expect(SubscriptionUsage.untilReset(now.addingTimeInterval(27 * 3600), now: now) == "in 1d 3h")
        #expect(SubscriptionUsage.untilReset(now.addingTimeInterval(-5), now: now) == "in 1m")
    }

    @Test func countsHowMuchOfAWindowHasPassed() {
        let now = Date(timeIntervalSince1970: 0)
        let window = { (left: TimeInterval) in SubscriptionUsage.Window(utilization: 10, resetsAt: now.addingTimeInterval(left)) }
        #expect(window(3600).elapsed(of: SubscriptionUsage.sessionLength, now: now) == 0.8)
        #expect(window(-60).elapsed(of: SubscriptionUsage.sessionLength, now: now) == 1)
        #expect(window(10 * 86400).elapsed(of: SubscriptionUsage.weekLength, now: now) == 0)
        #expect(SubscriptionUsage.Window(utilization: 1, resetsAt: nil).elapsed(of: 60, now: now) == nil)
    }
}
