import Foundation

/// One of an agent's limits, however the agent counts it: a 5-hour, weekly or monthly window
/// as a percentage (Claude, Codex), or a monthly plan in credits (Kiro).
public struct LimitStanding: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case fiveHour, weekly, monthly, plan
    }

    public let kind: Kind
    public let usedPercent: Double
    public let resetsAt: Date?
    /// When it reaches 100% at the recent pace, if before the reset.
    public let runsOutAt: Date?
    /// What is left at the reset at the recent pace.
    public let projectedLeftAtReset: Double?
    /// For a plan in credits: used, and the allowance.
    public let creditsUsed: Double?
    public let creditsLimit: Double?

    public var leftPercent: Double { max(100 - usedPercent, 0) }
    /// At or past this share used, the overview shows the limit in amber.
    public static let warningPercent: Double = 85
    public var isNearlyUsed: Bool { usedPercent >= Self.warningPercent }
}

extension AgentLimits {
    /// Every limit the agent reports.
    public var standings: [LimitStanding] {
        func window(_ kind: LimitStanding.Kind, _ report: LimitReport?) -> LimitStanding? {
            report.map {
                LimitStanding(
                    kind: kind, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, runsOutAt: $0.runsOutAt,
                    projectedLeftAtReset: $0.projectedLeftAtReset, creditsUsed: nil, creditsLimit: nil
                )
            }
        }
        return [
            window(.fiveHour, fiveHour),
            window(.weekly, weekly),
            window(.monthly, monthly),
            plan.map {
                LimitStanding(
                    kind: .plan, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt, runsOutAt: nil,
                    projectedLeftAtReset: nil, creditsUsed: $0.creditsUsed, creditsLimit: $0.creditsLimit
                )
            },
        ].compactMap { $0 }
    }

    private func standing(_ kind: LimitStanding.Kind) -> LimitStanding? {
        standings.first { $0.kind == kind }
    }

    /// The limit an agent's row leads with. Today it is whichever of the 5-hour and weekly
    /// windows is used more; a week or a month is measured against the weekly window. An agent
    /// with neither leads with its monthly window or plan.
    public func headline(for period: UsagePeriod) -> LimitStanding? {
        let monthly = standing(.plan) ?? standing(.monthly)
        switch period {
        case .today:
            let short = [standing(.fiveHour), standing(.weekly)].compactMap { $0 }
            return short.max { $0.usedPercent < $1.usedPercent } ?? monthly
        case .week, .month:
            return standing(.weekly) ?? monthly ?? standing(.fiveHour)
        }
    }

    /// Today's other short window, mentioned under the row: "week 48%" beside the 5-hour limit.
    public func secondary(for period: UsagePeriod) -> LimitStanding? {
        guard period == .today, let headline = headline(for: period) else { return nil }
        return [standing(.fiveHour), standing(.weekly)].compactMap { $0 }.first { $0.kind != headline.kind }
    }
}

/// What the overview's opening sentence says, before it is worded: the limit closest to
/// running out, across every window of every agent, then when another agent's tightest limit
/// frees up. "Codex runs out first: 5% of its week is left until Thu 06:57. Claude's 5-hour
/// limit frees up at 16:40."
public struct LimitHeadline: Sendable, Hashable {
    public let agent: Agent
    public let standing: LimitStanding
    /// Another agent's tightest limit, with when it frees up; nil when no other agent has one.
    public let other: (agent: Agent, standing: LimitStanding)?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.agent == rhs.agent && lhs.standing == rhs.standing
            && lhs.other?.agent == rhs.other?.agent && lhs.other?.standing == rhs.other?.standing
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(agent)
        hasher.combine(standing)
        hasher.combine(other?.agent)
        hasher.combine(other?.standing)
    }
}

public enum OverviewSummary {
    /// The most-used limit of all, then the most-used limit of another agent. A tie goes to the
    /// agent listed first in `Agent`, then to the window that frees up first.
    public static func headline(limits: [Agent: AgentLimits]) -> LimitHeadline? {
        let tightest = Agent.allCases.compactMap { agent in
            limits[agent].flatMap { tightestStanding($0) }.map { (agent: agent, standing: $0) }
        }
        guard let first = tightest.max(by: { $0.standing.usedPercent < $1.standing.usedPercent }) else { return nil }
        let other = tightest.filter { $0.agent != first.agent }.max { $0.standing.usedPercent < $1.standing.usedPercent }
        return LimitHeadline(agent: first.agent, standing: first.standing, other: other)
    }

    /// An agent's limit closest to running out.
    public static func tightestStanding(_ limits: AgentLimits) -> LimitStanding? {
        // `max(by:)` keeps the first of equal elements: the shorter window, listed first.
        limits.standings.max { $0.usedPercent < $1.usedPercent }
    }
}
