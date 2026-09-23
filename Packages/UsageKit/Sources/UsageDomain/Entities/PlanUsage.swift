import Foundation

/// Where an agent's plan stands, as the agent's own account reports it: Kiro's monthly credits.
/// The numbers come from the agent's servers, not its files on this Mac.
public struct PlanUsage: Sendable, Hashable {
    /// The plan's name as the agent writes it, such as "KIRO POWER".
    public let name: String?
    /// Credits used this period, and the plan's allowance; the allowance is nil when the agent
    /// gave only a percentage.
    public let creditsUsed: Double?
    public let creditsLimit: Double?
    public let usedPercent: Double
    public let resetsAt: Date?
    public let readAt: Date

    public init(
        name: String?, creditsUsed: Double?, creditsLimit: Double?, usedPercent: Double, resetsAt: Date?, readAt: Date
    ) {
        self.name = name
        self.creditsUsed = creditsUsed
        self.creditsLimit = creditsLimit
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.readAt = readAt
    }

    /// Credits left of the allowance, never below zero; nil without an allowance.
    public var creditsLeft: Double? {
        guard let limit = creditsLimit, let used = creditsUsed else { return nil }
        return max(limit - used, 0)
    }

    /// The credits left spread over the calendar days until the reset, today included:
    /// 3,917 left with 9 days to go is about 435 a day.
    public func creditsPerDayLeft(now: Date, calendar: Calendar) -> Double? {
        guard let left = creditsLeft, let resetsAt else { return nil }
        let days = CalendarDays.between(now, and: resetsAt, calendar: calendar)
        return left / Double(max(days, 1))
    }
}
