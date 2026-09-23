import Foundation

/// The share one part is of a whole, from 0 to 1. Nil when the whole is zero.
public enum Share {
    public static func of(_ part: Decimal, in whole: Decimal) -> Double? {
        guard whole != 0 else { return nil }
        return NSDecimalNumber(decimal: part / whole).doubleValue
    }

    public static func of(_ part: Int, in whole: Int) -> Double? {
        guard whole != 0 else { return nil }
        return Double(part) / Double(whole)
    }
}

/// Spend and tokens of one piece of work over a period.
public struct WorkSpend: Sendable, Hashable {
    public let tag: WorkTag
    public let costUSD: Decimal
    public let tokens: Int
    /// This work's share of the period's spend, from 0 to 1.
    public let shareOfSpend: Double
}

/// Tokens and spend of one model over a period.
public struct ModelUsage: Sendable, Hashable {
    public let model: ModelName
    public let tokens: Int
    /// Nil when no turn of the model had a known cost, such as a Codex model.
    public let costUSD: Decimal?
    /// Credits billed for the model, for an agent that bills in credits; nil otherwise.
    public let credits: Double?

    public init(model: ModelName, tokens: Int, costUSD: Decimal?, credits: Double? = nil) {
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
        self.credits = credits
    }
}

/// Tokens and spend of one calendar day.
public struct DayTotal: Sendable, Hashable {
    public let day: Date
    public let tokens: Int
    public let costUSD: Decimal
    /// Credits billed that day by agents that bill in credits; 0 when none did.
    public let credits: Double

    public init(day: Date, tokens: Int, costUSD: Decimal, credits: Double = 0) {
        self.day = day
        self.tokens = tokens
        self.costUSD = costUSD
        self.credits = credits
    }
}

public enum Breakdown {
    public static func totalCost(_ turns: [Turn]) -> Decimal {
        turns.reduce(Decimal(0)) { $0 + ($1.cost.usd ?? 0) }
    }

    /// Credits billed across the turns; nil when none of them reported credits.
    public static func totalCredits(_ turns: [Turn]) -> Double? {
        let billed = turns.compactMap(\.credits)
        return billed.isEmpty ? nil : billed.reduce(0, +)
    }

    public static func totalTokens(_ turns: [Turn]) -> TokenUsage? {
        turns.reduce(nil as TokenUsage?) { TokenUsage.sum($0, $1.tokens) }
    }

    /// Spend per piece of work, biggest first.
    public static func byWork(_ turns: [Turn]) -> [WorkSpend] {
        let total = totalCost(turns)
        let groups = Dictionary(grouping: turns, by: \.work.tag)
        return groups
            .map { tag, turns in
                let cost = totalCost(turns)
                return WorkSpend(
                    tag: tag,
                    costUSD: cost,
                    tokens: totalTokens(turns)?.total ?? 0,
                    shareOfSpend: Share.of(cost, in: total) ?? 0
                )
            }
            .sorted { ($0.costUSD, $0.tag.concern) > ($1.costUSD, $1.tag.concern) }
    }

    /// Tokens and spend per model, most tokens first, then most credits. Models that used no
    /// tokens and no credits, such as the `<synthetic>` messages Claude Code writes itself, are
    /// left out; a Kiro model on Auto reports no tokens but does bill credits, so it stays.
    public static func byModel(_ turns: [Turn]) -> [ModelUsage] {
        Dictionary(grouping: turns, by: \.model)
            .map { model, turns in
                ModelUsage(
                    model: model,
                    tokens: totalTokens(turns)?.total ?? 0,
                    costUSD: turns.contains { $0.cost.usd != nil } ? totalCost(turns) : nil,
                    credits: totalCredits(turns)
                )
            }
            .filter { $0.tokens > 0 || ($0.credits ?? 0) > 0 }
            .sorted { ($0.tokens, $0.credits ?? 0, $0.model.id) > ($1.tokens, $1.credits ?? 0, $1.model.id) }
    }

    /// One total per calendar day for the `count` days ending with the day of `now`, oldest first.
    /// Days with no turns are included with zero.
    public static func daily(_ turns: [Turn], days count: Int, endingAt now: Date, calendar: Calendar) -> [DayTotal] {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: turns) { calendar.startOfDay(for: $0.timestamp) }
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let turns = byDay[day] ?? []
            return DayTotal(
                day: day, tokens: totalTokens(turns)?.total ?? 0, costUSD: totalCost(turns),
                credits: totalCredits(turns) ?? 0
            )
        }
    }
}
