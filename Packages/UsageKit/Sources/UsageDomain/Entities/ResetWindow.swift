import Foundation

/// A limit whose last reading is of a period that has since ended: it reset at `resetsAt`, and
/// nothing has been read since. That says the limit is over, not that it stands at 0%, so it is
/// kept apart from `LimitStanding` and is never counted as usage, a forecast or a warning.
public struct ResetWindow: Sendable, Hashable {
    public let kind: LimitStanding.Kind
    public let resetsAt: Date
    /// When the period that reset was last read.
    public let readAt: Date

    public init(kind: LimitStanding.Kind, resetsAt: Date, readAt: Date) {
        self.kind = kind
        self.resetsAt = resetsAt
        self.readAt = readAt
    }

    /// For each window kind that has readings and none still running at `now`, its latest
    /// reading. A kind with a reading still running is a live limit, so it is not here.
    public static func lastSeen(in readings: [LimitReading], now: Date) -> [ResetWindow] {
        let kinds: [(window: LimitWindowKind, limit: LimitStanding.Kind)] = [
            (.fiveHour, .fiveHour), (.weekly, .weekly), (.monthly, .monthly),
        ]
        return kinds.compactMap { kind -> ResetWindow? in
            let seen = readings.compactMap { reading in
                reading.windows.first { $0.kind == kind.window }.map { (at: reading.timestamp, window: $0) }
            }
            guard !seen.contains(where: { $0.window.resetsAt > now }),
                  let latest = seen.max(by: { $0.at < $1.at }) else { return nil }
            return ResetWindow(kind: kind.limit, resetsAt: latest.window.resetsAt, readAt: latest.at)
        }
    }

    /// A plan that has reset, as Kiro's does at the start of the month. Nil while the plan is
    /// running, and for one that does not say when it resets.
    public static func lastSeen(plan: PlanUsage?, now: Date) -> ResetWindow? {
        guard let plan, let resetsAt = plan.resetsAt, resetsAt <= now else { return nil }
        return ResetWindow(kind: .plan, resetsAt: resetsAt, readAt: plan.readAt)
    }
}
