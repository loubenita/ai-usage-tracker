import Foundation
import UsageDomain

/// Ready-to-draw text and fractions. Views only lay these out; every number is decided upstream.
/// A value the agent did not report is left out, never shown as 0.

public enum ItemHighlight: Sendable, Equatable {
    case none, hovered, selected
}

public struct RingModel: Sendable, Equatable {
    /// Inside the ring: the current context in use, "68k", or its short label when the agent
    /// reports no context. This is the same reading that fills the ring.
    public let label: String
    public let fraction: Double
    public let isNearlyFull: Bool
    /// Which agent runs the session: each agent's ring has its own colour.
    public let agent: Agent
}

public struct StripItemModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let ring: RingModel
    /// The expanded strip's short task identity. Provider identity is carried by the icon and
    /// colour beside it, with the provider name in the accessibility label.
    public let title: String
    public let time: String
    public let needsUser: Bool
    /// The amber dot pulses until the item has been hovered once.
    public let pulses: Bool
    public let highlight: ItemHighlight
    /// 0 for the session whose work changed most recently. At rest the strip lists the first
    /// few in this order; the full strip keeps the order the sessions started in.
    public let recency: Int
    public let accessibilityLabel: String
}

public struct StripModel: Sendable, Equatable {
    public let items: [StripItemModel]
    /// The full strip shows while the pointer is over it or a panel is open;
    /// otherwise only the half strip on the screen edge shows.
    public let isExpanded: Bool
}

public enum StatusKind: Sendable, Equatable {
    case waiting, working, contextNearlyFull, idle
}

public struct StatusModel: Sendable, Equatable {
    public let kind: StatusKind
    /// "Waiting for your reply · 4m".
    public let text: String
    /// Where the session runs, "Warp · tmux lead"; nil when it is not known.
    public let place: String?
}

/// A small caption over a key number: "Spent" over "$1.10".
public struct StatModel: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let value: String
}

/// A title and detail over a thin bar: "Context 34%", "68k of 200k · full ~15:15".
public struct BarRowModel: Sendable, Equatable {
    public let title: String
    public let detail: String
    public let fraction: Double
    /// The part of the bar that is this session's, drawn in the agent's colour at its end.
    public let highlightFraction: Double?
    /// The bar is amber: the limit is nearly used.
    public let isNearlyUsed: Bool
    /// A sentence under the bar: "On pace to end the week at about 90%."
    public let note: String?
}

public enum SegmentStyle: Sendable, Equatable {
    case input, output, cacheRead, cacheWrite
}

public struct TokenSegmentModel: Sendable, Equatable {
    public let style: SegmentStyle
    public let label: String
    public let value: String
}

public enum SessionOpenAction: Sendable, Equatable {
    /// The terminal integration can select this exact session.
    case session
    /// The terminal app can be brought forward, but its exact tab cannot be selected.
    case terminal(String)
}

public struct DetailRowModel: Sendable, Equatable {
    public let label: String
    public let value: String
}

/// One sub-agent run and the usage attributable to that run.
public struct SubagentRowModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let model: String
    public let run: String
    public let tokens: String?
    public let cost: String?
    public let time: String
}

/// An aggregate followed by one row per sub-agent run.
public struct SubagentsModel: Sendable, Equatable {
    public let title: String
    /// Makes it explicit that the key session totals already contain these runs.
    public let inclusion: String
    public let share: String?
    public let total: String
    public let rows: [SubagentRowModel]
}

/// The panel a session opens (Paper frame 3).
public struct SessionPanelModel: Sendable, Equatable {
    public let sessionID: String
    public let agent: Agent
    /// The selected session's project, such as "Marketing Studio". The provider is its mark.
    public let subtitle: String
    public let title: String
    /// What the panel can truthfully promise when its terminal button is pressed.
    public let openAction: SessionOpenAction?
    public let status: StatusModel
    /// Total spent, Total tokens, Active, Turns: those the agent reported. The totals include
    /// any sub-agent runs listed below.
    public let stats: [StatModel]
    public let context: BarRowModel?
    public let tokenMix: [TokenSegmentModel]
    /// Explains why a small uncached input can sit beside a much larger cache read.
    public let tokenMixNote: String?
    /// Nil when the session started no sub-agents.
    public let subagents: SubagentsModel?
    public let details: [DetailRowModel]
}

/// Whose usage the usage panel shows: every agent, or one.
public enum AgentFilter: Sendable, Hashable {
    case all
    case agent(Agent)
}

public struct PickerItemModel: Sendable, Equatable, Identifiable {
    public var id: AgentFilter { filter }
    public let filter: AgentFilter
    public let name: String
    /// The dot beside the name; nil for All.
    public let agent: Agent?
}

/// One row of the All view's limits list: "Claude 5-hour", a bar, "62%", "16:40".
public struct LimitListRowModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let agent: Agent
    public let name: String
    /// Nil for an agent that shares no limits: the row says "no data".
    public let fraction: Double?
    public let used: String
    public let freesUp: String
    public let isNearlyUsed: Bool
}

/// One row of the All view's table: time, tokens and spend, or "n/a".
public struct AgentTableRowModel: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// Nil for the "All agents" total.
    public let agent: Agent?
    public let name: String
    public let time: String
    /// Nil when the agent reports no tokens: shown as "n/a".
    public let tokens: String?
    public let spend: String?
}

/// "MS · Video generation  50%  2h 58m".
public struct TimeRowModel: Sendable, Equatable, Identifiable {
    public let id: String
    /// The dot beside the work; nil for the "N more" row.
    public let agent: Agent?
    public let label: String
    public let percent: String?
    public let time: String
}

public struct ModelShareRowModel: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let percent: String
}

public struct ChartBarModel: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let fraction: Double
    /// The busiest bar is drawn in the agent's colour.
    public let isBusiest: Bool
    /// Today, or this week: drawn in white.
    public let isCurrent: Bool
}

public struct ChartModel: Sendable, Equatable {
    /// "TOKENS PER DAY".
    public let title: String
    /// "busiest Thu · 3.1M".
    public let caption: String
    public let bars: [ChartBarModel]
}

/// A note at the top of an agent's view, saying what the agent does not share.
public struct NoteModel: Sendable, Equatable {
    public let title: String
    public let text: String
}

/// Every agent together (Paper frame 4).
public struct AllAgentsModel: Sendable, Equatable {
    /// "Codex runs out first: 5% of its week is left until Thu 06:57. …"; nil without limits.
    public let headline: String?
    public let limits: [LimitListRowModel]
    /// "TODAY", "THIS WEEK", "THIS MONTH".
    public let tableTitle: String
    public let rows: [AgentTableRowModel]
    public let total: AgentTableRowModel?
    public let whereRows: [TimeRowModel]
}

/// One agent on its own (Paper frames 5 and 6).
public struct AgentUsageModel: Sendable, Equatable {
    public let agent: Agent
    public let note: NoteModel?
    public let limits: [BarRowModel]
    public let stats: [StatModel]
    public let chart: ChartModel?
    public let models: [ModelShareRowModel]
    public let whereRows: [TimeRowModel]
}

public enum UsageContent: Sendable, Equatable {
    case all(AllAgentsModel)
    case agent(AgentUsageModel)
}

/// Where the usage panel's totals are in their refresh cycle.
public enum UsageRefresh: Sendable, Equatable {
    case refreshing
    /// The next rebuild is this many seconds away.
    case next(in: TimeInterval)
}

/// The usage button's panel: an agent picker, Today, Week and Month.
public struct UsagePanelModel: Sendable, Equatable {
    public let picker: [PickerItemModel]
    public let selected: AgentFilter
    public let period: UsagePeriod
    /// "Refreshes in 8:12", or "Refreshing…"; nil before the first countdown starts.
    public let refreshLabel: String?
    public let content: UsageContent
}
