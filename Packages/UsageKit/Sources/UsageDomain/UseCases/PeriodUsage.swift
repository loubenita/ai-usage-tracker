import Foundation

/// The overview's three spans of time.
public enum UsagePeriod: String, Sendable, Hashable, CaseIterable {
    case today, week, month
}

/// What one agent did in a period, in its own units. A unit the agent does not report is nil,
/// never zero: Kiro's Auto agent reports no tokens, Cursor reports nothing per reply.
public struct AgentPeriodUsage: Sendable, Hashable {
    public let agent: Agent
    /// Time spent working: the gaps between replies, each session on its own (see `WorkingTime`).
    public let workingTime: TimeInterval
    public let tokens: Int?
    /// The API list price of those tokens, where the price is known (Claude).
    public let costUSD: Decimal?
    public let credits: Double?
    /// True when the agent had a session open but recorded no replies, as Cursor does.
    public let onlyOpenSessions: Bool
    /// Sessions with a reply in the period.
    public let sessionCount: Int
    /// Replies in the period: for an agent that records one per prompt (Cursor), the prompts.
    public let turnCount: Int
    /// Tools called, when the agent's records say; nil when none of them did.
    public let toolCalls: Int?
}

/// One piece of work's share of the period's working time.
public struct WorkTime: Sendable, Hashable {
    public let tag: WorkTag
    public let workingTime: TimeInterval
    public let share: Double
    /// The agent that spent the most time on it, for the dot beside it.
    public let agent: Agent
}

/// One model's share of the period: of its tokens, or of its time when no tokens are reported.
public struct ModelShare: Sendable, Hashable {
    public let model: ModelName
    public let tokens: Int?
    public let workingTime: TimeInterval
    public let share: Double
}

/// One bar of the overview's chart, a day on Week and a week on Month: its tokens and time.
public struct TokenBucket: Sendable, Hashable {
    public let start: Date
    public let tokens: Int
    public let workingTime: TimeInterval
}

/// Everything the overview shows for one period, agent by agent.
public struct PeriodUsage: Sendable, Hashable {
    public let period: UsagePeriod
    public let start: Date
    public let workingTime: TimeInterval
    /// Agents that did something in the period, most working time first.
    public let agents: [AgentPeriodUsage]
    /// Agents that did nothing in the period, in `Agent` order.
    public let unused: [Agent]
    public let byWork: [WorkTime]
    /// The agents whose tokens the chart counts, and the chart's bars (empty for Today).
    public let tokenAgents: [Agent]
    public let buckets: [TokenBucket]
    /// Most-used model first.
    public let byModel: [ModelShare]
    /// The same period for each agent on its own, as the overview's agent picker shows it.
    public let byAgent: [Agent: PeriodUsage]

    public var totalTokens: Int { buckets.reduce(0) { $0 + $1.tokens } }

    public func usage(of agent: Agent) -> AgentPeriodUsage? {
        agents.first { $0.agent == agent }
    }
}

public enum PeriodUsageBuilder {
    /// The agents the overview lists, used or not. Antigravity cannot be tracked, so it is left out.
    public static let trackedAgents: [Agent] = [.claudeCode, .codex, .cursor, .kiro, .opencode]

    /// The period's usage from the turns in it. `openAgents` are agents with a session open in
    /// the period, which count as used even with no replies to show.
    public static func make(
        _ period: UsagePeriod,
        turns: [Turn],
        start: Date,
        bucketStarts: [Date],
        openAgents: Set<Agent>
    ) -> PeriodUsage {
        let inPeriod = turns.filter { $0.timestamp >= start }
        let whole = make(period, inPeriod: inPeriod, start: start, bucketStarts: bucketStarts, openAgents: openAgents)
        let perAgent = whole.agents.map(\.agent).reduce(into: [Agent: PeriodUsage]()) { result, agent in
            result[agent] = make(
                period, inPeriod: inPeriod.filter { $0.agent == agent }, start: start, bucketStarts: bucketStarts,
                openAgents: openAgents.intersection([agent])
            )
        }
        return whole.with(byAgent: perAgent)
    }

    private static func make(
        _ period: UsagePeriod,
        inPeriod: [Turn],
        start: Date,
        bucketStarts: [Date],
        openAgents: Set<Agent>
    ) -> PeriodUsage {
        let byAgent = Dictionary(grouping: inPeriod, by: \.agent)
        let agents = trackedAgents.compactMap { agent -> AgentPeriodUsage? in
            let turns = byAgent[agent] ?? []
            guard !turns.isEmpty || openAgents.contains(agent) else { return nil }
            let tokens = Breakdown.totalTokens(turns)?.total
            return AgentPeriodUsage(
                agent: agent,
                workingTime: workingTime(turns),
                tokens: tokens.flatMap { $0 > 0 ? $0 : nil },
                costUSD: turns.contains { $0.cost.usd != nil } ? Breakdown.totalCost(turns) : nil,
                credits: Breakdown.totalCredits(turns),
                onlyOpenSessions: turns.isEmpty,
                sessionCount: Set(turns.map(\.sessionID)).count,
                turnCount: turns.count,
                toolCalls: turns.contains { $0.toolCalls != nil } ? turns.reduce(0) { $0 + ($1.toolCalls ?? 0) } : nil
            )
        }
        .sorted { ($0.workingTime, -rank($0.agent)) > ($1.workingTime, -rank($1.agent)) }
        let used = Set(agents.map(\.agent))
        let total = agents.reduce(0) { $0 + $1.workingTime }

        let byWork = Dictionary(grouping: inPeriod, by: \.work.tag)
            .map { tag, turns in (tag: tag, time: workingTime(turns), agent: mainAgent(turns)) }
            .filter { $0.time > 0 }
            .map { WorkTime(tag: $0.tag, workingTime: $0.time, share: total > 0 ? $0.time / total : 0, agent: $0.agent) }
            .sorted { ($0.workingTime, $0.tag.concern) > ($1.workingTime, $1.tag.concern) }

        let tokenAgents = agents.filter { $0.tokens != nil }.map(\.agent)
        let buckets = bucketStarts.enumerated().map { index, bucketStart in
            let end = index + 1 < bucketStarts.count ? bucketStarts[index + 1] : .distantFuture
            let inBucket = inPeriod.filter { $0.timestamp >= max(bucketStart, start) && $0.timestamp < end }
            return TokenBucket(
                start: bucketStart, tokens: inBucket.reduce(0) { $0 + ($1.tokens?.total ?? 0) },
                workingTime: workingTime(inBucket)
            )
        }

        return PeriodUsage(
            period: period,
            start: start,
            workingTime: total,
            agents: agents,
            unused: trackedAgents.filter { !used.contains($0) },
            byWork: byWork,
            tokenAgents: tokenAgents,
            buckets: buckets,
            byModel: modelShares(inPeriod),
            byAgent: [:]
        )
    }

    /// Each model's share of the tokens; of the working time when no model reported tokens.
    static func modelShares(_ turns: [Turn]) -> [ModelShare] {
        let byModel = Dictionary(grouping: turns, by: \.model).map { model, turns in
            (model: model, tokens: Breakdown.totalTokens(turns)?.total, time: workingTime(turns))
        }
        let totalTokens = byModel.reduce(0) { $0 + ($1.tokens ?? 0) }
        let totalTime = byModel.reduce(0) { $0 + $1.time }
        return byModel
            .map { model in
                let share = totalTokens > 0
                    ? Double(model.tokens ?? 0) / Double(totalTokens)
                    : totalTime > 0 ? model.time / totalTime : 0
                return ModelShare(model: model.model, tokens: model.tokens, workingTime: model.time, share: share)
            }
            .filter { $0.share > 0 }
            .sorted { ($0.share, $0.model.id) > ($1.share, $1.model.id) }
    }

    /// The agent with the most working time among the turns; the first agent on a tie.
    private static func mainAgent(_ turns: [Turn]) -> Agent {
        let times = Dictionary(grouping: turns, by: \.agent).mapValues(workingTime)
        return trackedAgents.filter { times[$0] != nil }.max { (times[$0] ?? 0) < (times[$1] ?? 0) }
            ?? turns.first?.agent ?? .claudeCode
    }

    /// Working time adds up each session on its own, so two sessions running side by side
    /// both count.
    static func workingTime(_ turns: [Turn]) -> TimeInterval {
        Dictionary(grouping: turns, by: \.sessionID).values.reduce(0) { $0 + WorkingTime.of($1.map(\.timestamp)) }
    }

    fileprivate static func rank(_ agent: Agent) -> Int {
        trackedAgents.firstIndex(of: agent) ?? trackedAgents.count
    }
}

private extension PeriodUsage {
    func with(byAgent: [Agent: PeriodUsage]) -> PeriodUsage {
        PeriodUsage(
            period: period, start: start, workingTime: workingTime, agents: agents, unused: unused, byWork: byWork,
            tokenAgents: tokenAgents, buckets: buckets, byModel: byModel, byAgent: byAgent
        )
    }
}
