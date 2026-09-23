import Foundation

/// One live session with the numbers worked out from it.
public struct SessionReport: Sendable, Hashable, Identifiable {
    public let summary: SessionSummary
    /// The label inside the ring, up to four characters.
    public let code: String
    /// What the panel calls the session: "Session detection", or the concern for fake data.
    public let title: String
    /// Tokens a working hour, cache reads left out (see `TokenPace`).
    public let tokensPerHour: Double?
    /// The session's pace divided by the owner's usual pace; nil without a usual pace.
    public let rateComparedWithUsual: Double?
    public let contextFullAt: Date?
    public let isContextNearlyFull: Bool
    /// The session's share of everything spent today, from 0 to 1.
    public let shareOfTodaysSpend: Double?
    /// Percentage points of the 5-hour limit this session used.
    public let shareOfFiveHourLimit: Double?

    public var id: String { summary.id }
}

public struct TodayReport: Sendable, Hashable {
    public let costUSD: Decimal
    public let costBudget: Decimal?
    public let costShareOfBudget: Double?
    public let tokens: TokenUsage?
    public let totalTokens: Int
    public let tokenBudget: Int?
    public let tokenShareOfBudget: Double?
    public let projection: DayProjection?
    public let byWork: [WorkSpend]
    public let byModel: [ModelUsage]
}

public struct WeekReport: Sendable, Hashable {
    public let days: [DayTotal]
    public let totalTokens: Int
    public let costUSD: Decimal
    public let dailyTokenBudget: Int?
    public let byWork: [WorkSpend]
    public let byModel: [ModelUsage]
    /// Credits billed over the week by agents that bill in credits; nil when none did.
    public let credits: Double?
}

/// The calendar month so far: one total per day from the 1st to today.
public struct MonthReport: Sendable, Hashable {
    public let start: Date
    public let days: [DayTotal]
    public let totalTokens: Int
    public let costUSD: Decimal
    /// Credits billed this month by agents that bill in credits; nil when none did.
    public let credits: Double?
    public let byWork: [WorkSpend]
    public let byModel: [ModelUsage]
}

/// One agent's plan limits. Each agent counts its own: Claude's 5-hour limit says nothing
/// about Codex.
public struct AgentLimits: Sendable, Hashable {
    public let fiveHour: LimitReport?
    public let weekly: LimitReport?
    public let monthly: LimitReport?
    /// For an agent that bills in credits, such as Kiro: the credits used this calendar month.
    public let creditsUsedThisMonth: Double?
    /// Points of the weekly limit used today (see `LimitUsage`).
    public let weeklyUsedToday: Double?
    /// Points of the weekly limit used on each of the week view's days, oldest first; nil
    /// unless the readings go back that far.
    public let weeklyUsedByDay: [Double]?
    /// The plan as the agent's account reports it: Kiro's monthly credits and allowance.
    public let plan: PlanUsage?
    /// Credits billed today, for an agent that bills in credits.
    public let creditsUsedToday: Double?
    /// The plan's credits left spread over the days until it resets (see `PlanUsage`).
    public let creditsPerDayLeft: Double?

    public init(
        fiveHour: LimitReport?,
        weekly: LimitReport?,
        monthly: LimitReport?,
        creditsUsedThisMonth: Double? = nil,
        weeklyUsedToday: Double? = nil,
        weeklyUsedByDay: [Double]? = nil,
        plan: PlanUsage? = nil,
        creditsUsedToday: Double? = nil,
        creditsPerDayLeft: Double? = nil
    ) {
        self.creditsPerDayLeft = creditsPerDayLeft
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.monthly = monthly
        self.creditsUsedThisMonth = creditsUsedThisMonth
        self.weeklyUsedToday = weeklyUsedToday
        self.weeklyUsedByDay = weeklyUsedByDay
        self.plan = plan
        self.creditsUsedToday = creditsUsedToday
    }

    /// The weekly limit left, spread over the calendar days until it resets: "about 17% a day".
    public var weeklyAllowancePerDay: Double? {
        weekly.map { max(100 - $0.usedPercent, 0) / Double(max($0.calendarDaysLeft, 1)) }
    }

    public static let none = AgentLimits(fiveHour: nil, weekly: nil, monthly: nil)

    /// Whether the agent reported any limit window as a percentage.
    public var hasWindows: Bool { fiveHour != nil || weekly != nil || monthly != nil }
    public var isEmpty: Bool { !hasWindows && creditsUsedThisMonth == nil && plan == nil && creditsUsedToday == nil }
}

/// The slow half of the report: every total, built from all the records at `builtAt`.
public struct UsageTotals: Sendable, Hashable {
    public let builtAt: Date
    public let today: TodayReport
    public let week: WeekReport
    public let month: MonthReport
    public let limitsByAgent: [Agent: AgentLimits]
    public let isHistoryComplete: Bool
    /// Today, the week and the month, agent by agent, for the overview.
    public let periods: [UsagePeriod: PeriodUsage]
}

/// Everything the overlay shows, worked out from the records at one moment.
public struct UsageReport: Sendable, Hashable {
    public let now: Date
    public let capturedAt: Date
    public let sessions: [SessionReport]
    public let today: TodayReport
    public let week: WeekReport
    public let month: MonthReport
    public let limitsByAgent: [Agent: AgentLimits]
    public let periods: [UsagePeriod: PeriodUsage]
    /// False while the week's history is still being read (see `UsageRecords`).
    public let isHistoryComplete: Bool
    /// The agent whose limits the strip shows: the one with the most open sessions among
    /// those that report limits.
    public let stripAgent: Agent?

    /// The limits the strip shows.
    public var fiveHour: LimitReport? { limits(for: stripAgent).fiveHour }
    public var weekly: LimitReport? { limits(for: stripAgent).weekly }
    public var monthly: LimitReport? { limits(for: stripAgent).monthly }

    public func limits(for agent: Agent?) -> AgentLimits {
        agent.flatMap { limitsByAgent[$0] } ?? .none
    }
}

/// Works out the whole report from raw records. Pure: the same records and `now`
/// always give the same report, so the views can rebuild it every second.
public struct GenerateUsageReport: Sendable {
    public static let daysInWeekView = 7

    private let settings: UsageSettings
    private let calendar: Calendar

    public init(settings: UsageSettings, calendar: Calendar) {
        self.settings = settings
        self.calendar = calendar
    }

    /// The range of records the report needs: the week view's days, and the calendar month so far.
    public func recordRange(endingAt now: Date) -> (start: Date, end: Date) {
        (min(weekStart(now), monthStart(now)), now)
    }

    private func weekStart(_ now: Date) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(Self.daysInWeekView - 1), to: today) ?? today
    }

    private func monthStart(_ now: Date) -> Date {
        calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    /// The whole report at once: the totals, then the open sessions. The app builds the two
    /// parts at different rates instead (see `totals(_:now:)` and `report(sessions:totals:now:)`).
    public func callAsFunction(_ records: UsageRecords, now: Date) -> UsageReport {
        report(sessions: records, totals: totals(records, now: now), now: now)
    }

    /// Today, This week, Month and every agent's limits, from all the records. This walks every
    /// turn since the 1st of the month, which on a busy month is hundreds of thousands, so the
    /// app builds it off the main thread and only when the history changes.
    public func totals(_ records: UsageRecords, now: Date) -> UsageTotals {
        let startOfToday = calendar.startOfDay(for: now)
        let turns = records.turns.filter { $0.timestamp <= now }
        let todaysTurns = turns.filter { $0.timestamp >= startOfToday }
        let creditsToday = Dictionary(grouping: todaysTurns.filter { $0.credits != nil }, by: \.agent)
            .compactMapValues(Breakdown.totalCredits)
        return UsageTotals(
            builtAt: now,
            today: makeToday(todaysTurns, now: now),
            week: makeWeek(turns, now: now),
            month: makeMonth(turns, now: now),
            limitsByAgent: limitsByAgent(
                records.limits, credits: records.creditsThisMonth, plans: records.plans, creditsToday: creditsToday,
                now: now
            ),
            isHistoryComplete: records.isHistoryComplete,
            periods: periods(turns, open: Set(records.sessionEvents.map(\.agent)), now: now)
        )
    }

    /// Today, the week (7 days, a bar a day) and the month (a bar a week, weeks from Monday).
    private func periods(_ turns: [Turn], open: Set<Agent>, now: Date) -> [UsagePeriod: PeriodUsage] {
        let today = calendar.startOfDay(for: now)
        let week = weekStart(now)
        let month = monthStart(now)
        let days = (0..<Self.daysInWeekView).compactMap { calendar.date(byAdding: .day, value: $0, to: week) }
        var monday = calendar.date(byAdding: .day, value: -((calendar.component(.weekday, from: month) + 5) % 7), to: month)
            ?? month
        var weeks: [Date] = []
        while monday <= now {
            weeks.append(monday)
            monday = calendar.date(byAdding: .day, value: 7, to: monday) ?? now.addingTimeInterval(1)
        }
        return [
            .today: PeriodUsageBuilder.make(.today, turns: turns, start: today, bucketStarts: [], openAgents: open),
            .week: PeriodUsageBuilder.make(.week, turns: turns, start: week, bucketStarts: days, openAgents: open),
            .month: PeriodUsageBuilder.make(.month, turns: turns, start: month, bucketStarts: weeks, openAgents: open),
        ]
    }

    /// The open sessions, worked out from their own turns only, with `totals` built earlier.
    /// Cheap enough to run every second, so the timers move without redoing the month.
    public func report(sessions records: UsageRecords, totals: UsageTotals, now: Date) -> UsageReport {
        let live = Set(records.sessionEvents.map(\.sessionID))
        let turns = records.turns.filter { live.contains($0.sessionID) && $0.timestamp <= now }
        let turnsBySession = Dictionary(grouping: turns, by: \.sessionID)
        let summaries = SessionSummaries.make(turns: turns, events: records.sessionEvents, now: now)
            .filter { $0.state != .ended }
        let limits = totals.limitsByAgent
        let sessions = summaries.map {
            makeSession(
                $0, turns: turnsBySession[$0.id] ?? [], usual: records.usualRates[$0.agent],
                todaysCost: totals.today.costUSD, fiveHour: limits[$0.agent]?.fiveHour, now: now
            )
        }
        return UsageReport(
            now: now,
            capturedAt: records.capturedAt,
            sessions: sessions,
            today: totals.today,
            week: totals.week,
            month: totals.month,
            limitsByAgent: limits,
            periods: totals.periods,
            isHistoryComplete: totals.isHistoryComplete,
            stripAgent: Self.stripAgent(sessions: summaries, limits: limits)
        )
    }

    /// Each agent's limits from its readings. A window that has already reset says nothing about
    /// the window running now, so it is left out: a 5-hour reading from last week is not 0%.
    /// Kiro's credits and plan join its limits: they are what Kiro counts its plan in.
    private func limitsByAgent(
        _ readings: [LimitReading], credits: [Agent: Double], plans: [Agent: PlanUsage],
        creditsToday: [Agent: Double], now: Date
    ) -> [Agent: AgentLimits] {
        let current = readings.map { reading in
            LimitReading(
                timestamp: reading.timestamp, agent: reading.agent, plan: reading.plan,
                windows: reading.windows.filter { $0.resetsAt > now }
            )
        }
        let byAgent = Dictionary(grouping: current, by: \.agent)
        // What was used each day needs the past periods too, so it reads every reading.
        let allByAgent = Dictionary(grouping: readings, by: \.agent)
        let today = calendar.startOfDay(for: now)
        let agents = Set(byAgent.keys).union(credits.keys).union(plans.keys).union(creditsToday.keys)
        return agents.reduce(into: [:]) { result, agent in
            let readings = byAgent[agent] ?? []
            let weekly = LimitForecast.report(.weekly, from: readings, calendar: calendar)
            let all = allByAgent[agent] ?? []
            // A plan that has already reset says nothing about the period running now.
            let plan = plans[agent].flatMap { plan in (plan.resetsAt ?? .distantFuture) > now ? plan : nil }
            let limits = AgentLimits(
                fiveHour: LimitForecast.report(.fiveHour, from: readings, calendar: calendar),
                weekly: weekly,
                monthly: LimitForecast.report(.monthly, from: readings, calendar: calendar),
                creditsUsedThisMonth: credits[agent],
                weeklyUsedToday: weekly.flatMap { _ in LimitUsage.used(.weekly, in: all, from: today, to: now) },
                weeklyUsedByDay: weekly.flatMap { _ in
                    LimitUsage.daily(.weekly, in: all, days: Self.daysInWeekView, endingAt: now, calendar: calendar)
                },
                plan: plan,
                creditsUsedToday: creditsToday[agent],
                creditsPerDayLeft: plan?.creditsPerDayLeft(now: now, calendar: calendar)
            )
            if !limits.isEmpty { result[agent] = limits }
        }
    }

    /// The agent with the most open sessions among those with limits. A tie, or no open
    /// session, goes to the agent listed first in `Agent`.
    static func stripAgent(sessions: [SessionSummary], limits: [Agent: AgentLimits]) -> Agent? {
        let open = Dictionary(grouping: sessions, by: \.agent).mapValues(\.count)
        // `max(by:)` keeps the first of equal elements, so a tie goes to the earlier agent.
        // The strip shows a percentage, so an agent with only credits is never chosen.
        return Agent.allCases
            .filter { limits[$0]?.hasWindows == true }
            .max { (open[$0] ?? 0) < (open[$1] ?? 0) }
    }

    private func makeSession(
        _ summary: SessionSummary,
        turns: [Turn],
        usual: UsualRate?,
        todaysCost: Decimal,
        fiveHour: LimitReport?,
        now: Date
    ) -> SessionReport {
        let rate = TokenPace.perWorkingHour(turns)
        let source = labelSource(for: summary.work, origin: summary.origin)
        return SessionReport(
            summary: summary,
            code: code(for: summary.work, source: source),
            title: summary.origin == nil ? summary.work.tag.concern : source.map(TaskTitle.make)
                ?? summary.work.tag.concern,
            tokensPerHour: rate,
            rateComparedWithUsual: rate.flatMap { rate in
                usual.flatMap { TokenRate.comparedWithUsual(rate, usual: $0.tokensPerHour) }
            },
            contextFullAt: ContextForecast.timeFull(turns, now: now),
            isContextNearlyFull: (summary.context?.fraction ?? 0) > settings.contextNearlyFullThreshold,
            shareOfTodaysSpend: summary.costUSD.flatMap { Share.of($0, in: todaysCost) },
            shareOfFiveHourLimit: fiveHour.flatMap {
                LimitForecast.sessionShare(
                    percentPerHour: $0.percentPerHour,
                    activeDuration: summary.activeDuration,
                    limitUsedPercent: $0.usedPercent
                )
            }
        )
    }

    /// The user's label for the concern wins; a session with a known folder is labelled
    /// from its branch and folder; anything else from the concern's first word.
    private func code(for work: Work, source: LabelSource?) -> String {
        if let label = settings.concernLabels[work.tag.concern] { return label }
        if let source { return TaskLabel.make(source, rules: settings.labelRules) }
        return work.tag.concernCode()
    }

    /// What a session's label and title are made from, when its folder is known.
    private func labelSource(for work: Work, origin: SessionOrigin?) -> LabelSource? {
        work.folder.map { folder in
            LabelSource(
                sessionName: origin?.sessionName,
                branch: work.branch,
                folderName: URL(fileURLWithPath: folder).lastPathComponent,
                isHomeFolder: origin?.isHomeFolder ?? false
            )
        }
    }

    private func makeToday(_ turns: [Turn], now: Date) -> TodayReport {
        let cost = Breakdown.totalCost(turns)
        let tokens = Breakdown.totalTokens(turns)
        let total = tokens?.total ?? 0
        let dayEnd = calendar.date(
            bySettingHour: settings.workdayEndHour, minute: 0, second: 0, of: now
        ) ?? now
        let projection = turns.map(\.timestamp).min().flatMap { firstActivity in
            DayProjection.make(
                tokensSoFar: total,
                firstActivity: firstActivity,
                now: now,
                dayEnd: dayEnd,
                budget: settings.dailyTokenBudget
            )
        }
        return TodayReport(
            costUSD: cost,
            costBudget: settings.dailyCostBudget,
            costShareOfBudget: settings.dailyCostBudget.flatMap { Share.of(cost, in: $0) },
            tokens: tokens,
            totalTokens: total,
            tokenBudget: settings.dailyTokenBudget,
            tokenShareOfBudget: settings.dailyTokenBudget.flatMap { Share.of(total, in: $0) },
            projection: projection,
            byWork: Breakdown.byWork(turns),
            byModel: Breakdown.byModel(turns)
        )
    }

    private func makeWeek(_ turns: [Turn], now: Date) -> WeekReport {
        let weekTurns = turns.filter { $0.timestamp >= weekStart(now) }
        let days = Breakdown.daily(weekTurns, days: Self.daysInWeekView, endingAt: now, calendar: calendar)
        return WeekReport(
            days: days,
            totalTokens: days.reduce(0) { $0 + $1.tokens },
            costUSD: Breakdown.totalCost(weekTurns),
            dailyTokenBudget: settings.dailyTokenBudget,
            byWork: Breakdown.byWork(weekTurns),
            byModel: Breakdown.byModel(weekTurns),
            credits: Breakdown.totalCredits(weekTurns)
        )
    }

    private func makeMonth(_ turns: [Turn], now: Date) -> MonthReport {
        let start = monthStart(now)
        let monthTurns = turns.filter { $0.timestamp >= start }
        let dayCount = CalendarDays.between(start, and: now, calendar: calendar) + 1
        let days = Breakdown.daily(monthTurns, days: dayCount, endingAt: now, calendar: calendar)
        return MonthReport(
            start: start,
            days: days,
            totalTokens: days.reduce(0) { $0 + $1.tokens },
            costUSD: Breakdown.totalCost(monthTurns),
            credits: Breakdown.totalCredits(monthTurns),
            byWork: Breakdown.byWork(monthTurns),
            byModel: Breakdown.byModel(monthTurns)
        )
    }
}
