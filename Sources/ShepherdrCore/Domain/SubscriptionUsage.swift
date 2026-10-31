import Foundation

/// How much of a Claude subscription's limits is used, as `api.anthropic.com/api/oauth/usage` reports it.
public struct SubscriptionUsage: Equatable, Sendable {
    /// One limit: the share used (0...100) and when it starts again.
    public struct Window: Equatable, Sendable {
        public let utilization: Double
        public let resetsAt: Date?

        public init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }

        /// A whole percentage, as the status bar shows it.
        public var percent: Int { Int(utilization.rounded()) }

        /// How much of a window `length` long has passed (0...1), judging by when it starts again.
        public func elapsed(of length: TimeInterval, now: Date = .now) -> Double? {
            guard let resetsAt else { return nil }
            return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / length))
        }
    }

    public static let sessionLength: TimeInterval = 5 * 3600
    public static let weekLength: TimeInterval = 7 * 86400

    /// The rolling five-hour limit.
    public let session: Window?
    /// The weekly limit.
    public let week: Window?

    public init(session: Window?, week: Window?) {
        self.session = session
        self.week = week
    }

    /// Nil when the answer has neither limit.
    public static func parse(_ data: Data) -> SubscriptionUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let usage = SubscriptionUsage(session: window(root["five_hour"]), week: window(root["seven_day"]))
        return usage.session == nil && usage.week == nil ? nil : usage
    }

    private static func window(_ value: Any?) -> Window? {
        guard let object = value as? [String: Any], let used = (object["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (object["resets_at"] as? String).flatMap(date)
        return Window(utilization: used, resetsAt: reset)
    }

    private static func date(_ text: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// "in 2h 10m", "in 40m", or "in 1d 3h": the two largest units that are left.
    public static func untilReset(_ date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        let (days, hours, rest) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(rest)m" }
        return "in \(max(rest, 1))m"
    }
}
