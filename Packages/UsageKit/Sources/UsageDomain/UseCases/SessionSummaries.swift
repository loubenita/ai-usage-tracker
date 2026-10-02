import Foundation

/// Everything known about one session at a moment in time.
public struct SessionSummary: Sendable, Hashable, Identifiable {
    public let id: String
    public let agent: Agent
    public let work: Work
    public let model: ModelName?
    /// The model's reasoning effort, when the agent records it.
    public let effort: String?
    public let startedAt: Date
    public let turnCount: Int
    /// The session's tokens and cost, its sub-agents' included.
    public let tokens: TokenUsage?
    public let costUSD: Decimal?
    /// Credits the session was billed, for an agent that bills in credits (Kiro).
    public let credits: Double?
    public let context: ContextUsage?
    public let state: SessionState
    public let activeDuration: TimeInterval
    public let idleDuration: TimeInterval
    public let origin: SessionOrigin?
    /// The tools called, files changed and first message, when the agent's record says.
    public let activity: SessionActivity?
    /// When the session entered its current state, when the agent says: how long it has waited.
    public let stateSince: Date?
    /// When the session's own files last changed: its latest reply, or the last time the agent
    /// said anything about it. This breaks ties in strip priority.
    public let lastActivityAt: Date
    /// The sub-agents it started; their tokens and cost are in the session's.
    public let subagents: [SubagentRun]
    /// True when the session is itself a sub-agent a parent agent started (Kiro).
    public let isSubagent: Bool
    /// A rough token estimate for a session whose agent reports no precise counts (Kiro's Auto),
    /// made from its transcript text. It is clearly an estimate, excludes cache, and is never
    /// summed into `tokens` or any exact total.
    public let estimatedTokens: TokenUsage?

    public init(
        id: String,
        agent: Agent,
        work: Work,
        model: ModelName?,
        effort: String?,
        startedAt: Date,
        turnCount: Int,
        tokens: TokenUsage?,
        costUSD: Decimal?,
        credits: Double?,
        context: ContextUsage?,
        state: SessionState,
        activeDuration: TimeInterval,
        idleDuration: TimeInterval,
        origin: SessionOrigin?,
        activity: SessionActivity?,
        stateSince: Date?,
        lastActivityAt: Date,
        subagents: [SubagentRun],
        isSubagent: Bool = false,
        estimatedTokens: TokenUsage? = nil
    ) {
        self.id = id
        self.agent = agent
        self.work = work
        self.model = model
        self.effort = effort
        self.startedAt = startedAt
        self.turnCount = turnCount
        self.tokens = tokens
        self.costUSD = costUSD
        self.credits = credits
        self.context = context
        self.state = state
        self.activeDuration = activeDuration
        self.idleDuration = idleDuration
        self.origin = origin
        self.activity = activity
        self.stateSince = stateSince
        self.lastActivityAt = lastActivityAt
        self.subagents = subagents
        self.isSubagent = isSubagent
        self.estimatedTokens = estimatedTokens
    }

    /// What the sub-agents cost, when any cost is known.
    public var subagentCostUSD: Decimal? {
        let costs = subagents.compactMap(\.costUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    public var subagentTokens: Int {
        subagents.reduce(0) { $0 + ($1.tokens?.total ?? 0) }
    }

    public var needsUser: Bool { state == .waiting }
}

public enum SessionSummaries {
    /// Builds a summary for every session that has a start event, in the order the sessions
    /// first appear in `events`. Active and idle time keep counting from the latest event:
    /// active while the session is working, idle while it waits or rests.
    public static func make(turns: [Turn], events: [SessionEvent], now: Date) -> [SessionSummary] {
        let turnsBySession = Dictionary(grouping: turns, by: \.sessionID)
        var order: [String] = []
        var eventsBySession: [String: [SessionEvent]] = [:]
        for event in events {
            if eventsBySession[event.sessionID] == nil { order.append(event.sessionID) }
            eventsBySession[event.sessionID, default: []].append(event)
        }

        return order.compactMap { sessionID in
            let events = (eventsBySession[sessionID] ?? []).sorted { $0.timestamp < $1.timestamp }
            guard let start = events.first(where: { $0.kind == .start }), let latest = events.last else {
                return nil
            }
            let turns = (turnsBySession[sessionID] ?? []).sorted { $0.timestamp < $1.timestamp }
            let sinceLatest = max(now.timeIntervalSince(latest.timestamp), 0)
            let state: SessionState = latest.kind == .end ? .ended : latest.state
            // Agents that keep no per-reply record report the session as a whole instead.
            let snapshot = events.last(where: { $0.snapshot != nil })?.snapshot
            let subagents = snapshot?.subagents ?? []
            let ownCost = turns.contains { $0.cost.usd != nil } ? Breakdown.totalCost(turns) : nil
            let subagentCosts = subagents.compactMap(\.costUSD)
            let cost = ownCost == nil && subagentCosts.isEmpty ? nil : (ownCost ?? 0) + subagentCosts.reduce(0, +)
            let tokens = subagents.reduce(Breakdown.totalTokens(turns)) { TokenUsage.sum($0, $1.tokens) }

            return SessionSummary(
                id: sessionID,
                agent: start.agent,
                work: turns.last?.work ?? start.workDetail ?? Work(tag: start.work),
                model: turns.last?.model ?? snapshot?.model,
                effort: snapshot?.effort,
                startedAt: start.timestamp,
                turnCount: turns.isEmpty ? snapshot?.turnCount ?? 0 : turns.count,
                tokens: tokens,
                costUSD: cost,
                credits: Breakdown.totalCredits(turns),
                context: turns.last(where: { $0.context != nil })?.context ?? snapshot?.context,
                state: state,
                activeDuration: latest.activeDuration + (state == .working ? sinceLatest : 0),
                idleDuration: latest.idleDuration + (state == .waiting || state == .idle ? sinceLatest : 0),
                origin: start.origin,
                activity: snapshot?.activity,
                stateSince: snapshot?.stateSince ?? (latest.kind == .start ? nil : latest.timestamp),
                lastActivityAt: [turns.last?.timestamp, snapshot?.stateSince, start.timestamp]
                    .compactMap { $0 }.max() ?? start.timestamp,
                subagents: subagents,
                isSubagent: snapshot?.isSubagent ?? false,
                estimatedTokens: snapshot?.estimatedTokens
            )
        }
    }
}
