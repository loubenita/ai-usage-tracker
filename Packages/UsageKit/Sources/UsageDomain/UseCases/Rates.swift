import Foundation

/// Tokens per hour over a stretch of active time.
public enum TokenRate {
    /// Returns nil when there is no time to measure over.
    public static func perHour(tokens: Int, over duration: TimeInterval) -> Double? {
        guard duration > 0 else { return nil }
        return Double(tokens) / (duration / 3600)
    }

    /// How a session's rate compares with the user's usual rate: 2 means twice as fast.
    public static func comparedWithUsual(_ rate: Double, usual: Double) -> Double? {
        guard usual > 0 else { return nil }
        return rate / usual
    }
}

/// The time an agent spent working: the gaps between its replies, leaving out any gap longer
/// than `maxGap`, which is the person reading, away, or the session resting.
public enum WorkingTime {
    public static let maxGap: TimeInterval = 5 * 60

    public static func of(_ timestamps: [Date], maxGap: TimeInterval = maxGap) -> TimeInterval {
        let sorted = timestamps.sorted()
        return zip(sorted, sorted.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.timeIntervalSince(pair.0)
            return gap <= maxGap ? total + gap : total
        }
    }
}

/// How fast replies use tokens, counting input, output and cache writes but not cache reads.
/// Cache reads are the whole conversation read again on every reply, so they grow with the
/// conversation's length rather than with the work: in a long session they are 99% of all tokens.
public enum TokenPace {
    /// Less working time than this says nothing about a pace yet.
    public static let minimumWorkingTime: TimeInterval = 2 * 60

    /// Tokens a working hour over the given replies, or nil with too little working time.
    public static func perWorkingHour(_ turns: [Turn]) -> Double? {
        let working = WorkingTime.of(turns.map(\.timestamp))
        guard working >= minimumWorkingTime else { return nil }
        let tokens = turns.reduce(0) { $0 + ($1.tokens?.withoutCacheReads ?? 0) }
        return TokenRate.perHour(tokens: tokens, over: working)
    }
}

/// The owner's usual pace: tokens a working hour, cache reads left out, over recent sessions.
public struct UsualRate: Sendable, Hashable {
    /// Less working time than this in total is too little to call anything usual.
    public static let minimumWorkingTime: TimeInterval = 60 * 60

    public let tokensPerHour: Double
    /// The working time the rate was measured over.
    public let workingTime: TimeInterval

    public init(tokensPerHour: Double, workingTime: TimeInterval) {
        self.tokensPerHour = tokensPerHour
        self.workingTime = workingTime
    }

    /// All the sessions' tokens over all their working time, so a long session counts for
    /// more than a short one. Each session's replies are one list; nil below the minimum.
    public static func make(sessions: [[Turn]], minimumWorkingTime: TimeInterval = minimumWorkingTime) -> UsualRate? {
        var tokens = 0
        var working: TimeInterval = 0
        for turns in sessions {
            working += WorkingTime.of(turns.map(\.timestamp))
            tokens += turns.reduce(0) { $0 + ($1.tokens?.withoutCacheReads ?? 0) }
        }
        guard working >= minimumWorkingTime, let rate = TokenRate.perHour(tokens: tokens, over: working) else {
            return nil
        }
        return UsualRate(tokensPerHour: rate, workingTime: working)
    }
}

/// When a session's context window will be full if it keeps growing as it has been.
public enum ContextForecast {
    /// A reading this much smaller than the one before means the context was compacted or
    /// cleared, and growth is measured again from there.
    static let resetShrink = 0.8

    /// The growth of the context since it was last compacted, over the working time of those
    /// replies, carried forward from `now`. Returns `now` when the window is already full, and
    /// nil when the context has not grown or there is too little working time to measure it.
    public static func timeFull(_ turns: [Turn], now: Date) -> Date? {
        let readings = turns
            .compactMap { turn in turn.context.map { (time: turn.timestamp, context: $0) } }
            .sorted { $0.time < $1.time }
        guard let latest = readings.last else { return nil }
        guard latest.context.remaining > 0 else { return now }

        var start = readings.startIndex
        for index in readings.indices.dropFirst()
        where Double(readings[index].context.used) < Double(readings[index - 1].context.used) * resetShrink {
            start = index
        }
        let since = readings[start...]
        let growth = latest.context.used - since[start].context.used
        let working = WorkingTime.of(since.map(\.time))
        guard growth > 0, working >= TokenPace.minimumWorkingTime,
              let perHour = TokenRate.perHour(tokens: growth, over: working)
        else { return nil }
        return now.addingTimeInterval(Double(latest.context.remaining) / perHour * 3600)
    }
}

/// Where today's token count will end if the day keeps going at its rate so far.
public struct DayProjection: Sendable, Hashable {
    public let tokensPerHour: Double
    public let projectedTokens: Int
    /// How far the projection is above the budget: 0.12 means 12% over. Negative means under.
    /// Nil without a budget.
    public let overBudgetFraction: Double?

    public var isOverBudget: Bool { (overBudgetFraction ?? 0) > 0 }

    /// Rate is today's tokens over the time since the day's first activity.
    /// Returns nil before any activity. A budget of zero counts as no budget.
    public static func make(
        tokensSoFar: Int,
        firstActivity: Date,
        now: Date,
        dayEnd: Date,
        budget: Int?
    ) -> DayProjection? {
        guard let rate = TokenRate.perHour(tokens: tokensSoFar, over: now.timeIntervalSince(firstActivity))
        else { return nil }
        let hoursLeft = max(dayEnd.timeIntervalSince(now), 0) / 3600
        let projected = Double(tokensSoFar) + rate * hoursLeft
        return DayProjection(
            tokensPerHour: rate,
            projectedTokens: Int(projected.rounded()),
            overBudgetFraction: budget.flatMap { $0 > 0 ? projected / Double($0) - 1 : nil }
        )
    }
}
