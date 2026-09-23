import Foundation

/// One model reply: a `turn` record.
public struct Turn: Sendable, Hashable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let agent: Agent
    public let sessionID: String
    public let model: ModelName
    public let work: Work
    public let tokens: TokenUsage?
    public let cost: Cost
    public let context: ContextUsage?
    public let duration: TimeInterval?
    /// What the request cost in the agent's credits, for an agent that bills in credits (Kiro).
    public let credits: Double?
    /// Tools the reply called, when the agent's record of it says.
    public let toolCalls: Int?

    public init(
        id: String,
        timestamp: Date,
        agent: Agent,
        sessionID: String,
        model: ModelName,
        work: Work,
        tokens: TokenUsage?,
        cost: Cost,
        context: ContextUsage?,
        duration: TimeInterval? = nil,
        credits: Double? = nil,
        toolCalls: Int? = nil
    ) {
        self.credits = credits
        self.toolCalls = toolCalls
        self.id = id
        self.timestamp = timestamp
        self.agent = agent
        self.sessionID = sessionID
        self.model = model
        self.work = work
        self.tokens = tokens
        self.cost = cost
        self.context = context
        self.duration = duration
    }
}

/// A model id such as "claude-opus-5", with the short name people use for it.
public struct ModelName: Sendable, Hashable, ExpressibleByStringLiteral {
    public let id: String

    public init(_ id: String) { self.id = id }
    public init(stringLiteral value: String) { self.id = value }

    /// "claude-opus-5" becomes "Opus 5" and "claude-haiku-4-5-20251001" becomes "Haiku 4.5": the
    /// version's numbers are joined with dots and the release date is left off. An id that does
    /// not follow that shape is shown as it is.
    public var displayName: String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts[2...].filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard !version.isEmpty, version.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return ([family] + parts[2...]).joined(separator: " ")
        }
        return "\(family) \(version.joined(separator: "."))"
    }
}

/// A usage-limit window of the agent's plan.
public enum LimitWindowKind: String, Sendable, Hashable, Codable {
    case fiveHour = "5h"
    case weekly
    case monthly
}

public struct LimitWindowReading: Sendable, Hashable, Codable {
    public let kind: LimitWindowKind
    /// Percentage of the window used, from 0 to 100.
    public let usedPercent: Double
    public let resetsAt: Date

    public init(kind: LimitWindowKind, usedPercent: Double, resetsAt: Date) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// A usage-limit reading: a `limit` record.
public struct LimitReading: Sendable, Hashable, Codable {
    public let timestamp: Date
    public let agent: Agent
    public let plan: String?
    public let windows: [LimitWindowReading]

    public init(timestamp: Date, agent: Agent, plan: String?, windows: [LimitWindowReading]) {
        self.timestamp = timestamp
        self.agent = agent
        self.plan = plan
        self.windows = windows
    }
}

/// What a session is doing right now.
public enum SessionState: String, Sendable, Hashable {
    /// The agent is working.
    case working
    /// The agent has stopped and is waiting for the user to reply.
    case waiting
    /// Nobody is doing anything.
    case idle
    case ended
}

/// What a session did, from its own record: the tools it called, the files it changed and
/// the person's first message. Each is nil when the agent's record does not say.
public struct SessionActivity: Sendable, Hashable {
    public let toolCalls: Int?
    public let filesChanged: Int?
    /// The person's first message, as they typed it.
    public let firstAsk: String?

    public init(toolCalls: Int? = nil, filesChanged: Int? = nil, firstAsk: String? = nil) {
        self.toolCalls = toolCalls
        self.filesChanged = filesChanged
        self.firstAsk = firstAsk
    }
}

/// One sub-agent a session started: its model, tokens, cost at API prices and working time.
/// Claude Code keeps each in its own transcript beside the session's.
public struct SubagentRun: Sendable, Hashable {
    public let id: String
    public let model: ModelName
    public let tokens: TokenUsage?
    public let costUSD: Decimal?
    public let workingTime: TimeInterval

    public init(id: String, model: ModelName, tokens: TokenUsage?, costUSD: Decimal?, workingTime: TimeInterval) {
        self.id = id
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
        self.workingTime = workingTime
    }

    /// A run from its replies: the model it used most, their tokens and cost, and the gaps
    /// between them (see `WorkingTime`). Nil for a run with no replies yet.
    public static func make(id: String, turns: [Turn]) -> SubagentRun? {
        let counts = Dictionary(grouping: turns, by: \.model).mapValues(\.count)
        guard let model = counts.max(by: { ($0.value, $1.key.id) < ($1.value, $0.key.id) })?.key else { return nil }
        return SubagentRun(
            id: id,
            model: model,
            tokens: Breakdown.totalTokens(turns),
            costUSD: turns.contains { $0.cost.usd != nil } ? Breakdown.totalCost(turns) : nil,
            workingTime: WorkingTime.of(turns.map(\.timestamp))
        )
    }
}

/// What an agent reports about a session as a whole, for agents that do not record each reply.
/// Cursor keeps only the chat's current context and model, not a token count per reply.
public struct SessionSnapshot: Sendable, Hashable {
    public let model: ModelName?
    public let context: ContextUsage?
    /// How many times the person has written to the agent.
    public let turnCount: Int?
    /// How hard the model was set to reason, as the agent names it: Codex's "medium".
    public let effort: String?
    public let activity: SessionActivity?
    /// Since when the session has been in its current state: when it stopped to wait, say.
    public let stateSince: Date?
    /// The sub-agents the session started, each once.
    public let subagents: [SubagentRun]

    public init(
        model: ModelName? = nil, context: ContextUsage? = nil, turnCount: Int? = nil, effort: String? = nil,
        activity: SessionActivity? = nil, stateSince: Date? = nil, subagents: [SubagentRun] = []
    ) {
        self.subagents = subagents
        self.model = model
        self.context = context
        self.turnCount = turnCount
        self.effort = effort
        self.activity = activity
        self.stateSince = stateSince
    }
}

/// A `session` record: a session starting, going idle, becoming active again, or ending.
public struct SessionEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case start, idle, active, end
    }

    public let timestamp: Date
    public let agent: Agent
    public let sessionID: String
    public let kind: Kind
    /// For `idle`, why it went idle: `.waiting` means it needs the user.
    public let state: SessionState
    /// Active and idle time so far, as the agent reported them at `timestamp`.
    public let activeDuration: TimeInterval
    public let idleDuration: TimeInterval
    public let work: WorkTag
    /// The repository, branch and folder the session runs in, when known.
    public let workDetail: Work?
    /// The process and terminal behind a session detected on this Mac.
    public let origin: SessionOrigin?
    /// The session's state as the agent reports it, when the agent keeps no per-reply record.
    public let snapshot: SessionSnapshot?

    public init(
        timestamp: Date,
        agent: Agent,
        sessionID: String,
        kind: Kind,
        state: SessionState,
        activeDuration: TimeInterval,
        idleDuration: TimeInterval,
        work: WorkTag,
        workDetail: Work? = nil,
        origin: SessionOrigin? = nil,
        snapshot: SessionSnapshot? = nil
    ) {
        self.timestamp = timestamp
        self.agent = agent
        self.sessionID = sessionID
        self.kind = kind
        self.state = state
        self.activeDuration = activeDuration
        self.idleDuration = idleDuration
        self.work = work
        self.workDetail = workDetail
        self.origin = origin
        self.snapshot = snapshot
    }
}

/// Every record the repository returned for a time range.
public struct UsageRecords: Sendable {
    public let turns: [Turn]
    public let limits: [LimitReading]
    public let sessionEvents: [SessionEvent]
    /// When the records were last read from their source.
    public let capturedAt: Date
    /// Credits each agent that bills in credits (Kiro) has used this calendar month.
    public let creditsThisMonth: [Agent: Double]
    /// The owner's usual pace with each agent, measured from their recent sessions. An agent
    /// is missing until there is enough history, and its sessions are not compared until then.
    public let usualRates: [Agent: UsualRate]
    /// False while the week's history is still being read, when the turns cover only the
    /// sessions open now and the totals are too low.
    public let isHistoryComplete: Bool
    /// Each agent's plan as its account reports it, for agents that can be asked (Kiro).
    public let plans: [Agent: PlanUsage]

    public init(
        turns: [Turn],
        limits: [LimitReading],
        sessionEvents: [SessionEvent],
        capturedAt: Date,
        usualRates: [Agent: UsualRate] = [:],
        isHistoryComplete: Bool = true,
        creditsThisMonth: [Agent: Double] = [:],
        plans: [Agent: PlanUsage] = [:]
    ) {
        self.plans = plans
        self.turns = turns
        self.limits = limits
        self.sessionEvents = sessionEvents
        self.capturedAt = capturedAt
        self.creditsThisMonth = creditsThisMonth
        self.usualRates = usualRates
        self.isHistoryComplete = isHistoryComplete
    }
}
