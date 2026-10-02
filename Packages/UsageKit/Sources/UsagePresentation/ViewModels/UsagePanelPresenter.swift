import Foundation
import UsageDomain

/// A window's last known reading when no live reading covers it, as the panel says it: an
/// account cache's percentage, or a window that has reset with nothing read since.
struct LastWindow: Equatable {
    enum State: Equatable {
        /// A percentage read from an account cache; its reset is ahead, or not known.
        case reading(percent: Double, resetsAt: Date?)
        /// The window reset and nothing has been read since.
        case reset(Date)
    }

    let kind: LimitStanding.Kind
    let state: State
    let readAt: Date

    var isReset: Bool { if case .reset = state { true } else { false } }
    /// Nil for a window that has reset: its old percentage says nothing about the next one.
    var percent: Double? { if case .reading(let percent, _) = state { percent } else { nil } }
    var isNearlyUsed: Bool { (percent ?? 0) >= LimitStanding.warningPercent }
}

/// Maps a `UsageReport` to the usage button's panel (Paper frames 4 to 6): an agent picker,
/// Today, Week and Month, and either every agent together or one agent on its own. Pure.
///
/// Nothing an agent does not report is shown as 0. A table cell it cannot fill says "n/a";
/// absent limits are left out, while a limit with no live reading shows what was last read of
/// it and when, or that it has reset.
public struct UsagePanelPresenter: Sendable {
    /// Rows of "Where the time went" before the rest are added up in one "N more" row.
    static let allWhereRows = 4
    static let agentWhereRows = 2
    static let modelRows = 3

    private let format: UsageFormatter

    public init(formatter: UsageFormatter) {
        self.format = formatter
    }

    public func panel(
        _ report: UsageReport,
        filter: AgentFilter,
        period: UsagePeriod,
        selectedBucketStart: Date? = nil,
        refresh: UsageRefresh? = nil
    ) -> UsagePanelModel {
        let agents = pickerAgents(report)
        // An agent that has gone from the picker takes the panel back to All.
        let selected: AgentFilter = if case .agent(let agent) = filter, !agents.contains(agent) { .all } else { filter }
        let picker = [PickerItemModel(filter: .all, name: "All", agent: nil)]
            + agents.map { PickerItemModel(filter: .agent($0), name: $0.displayName, agent: $0) }
        let periodUsage = report.periods[period]
        let bucketStart = resolvedBucketStart(periodUsage, period: period, requested: selectedBucketStart)
        let selectedUsage = bucketStart.flatMap { periodUsage?.selecting(bucketStart: $0) }
        let content: UsageContent = switch selected {
        // The All view has no chart to make a bucket selection, so its THIS WEEK / THIS MONTH
        // table always remains the full period aggregate.
        case .all: .all(all(report, usage: periodUsage, period: period, agents: agents))
        case .agent(let agent): .agent(agentView(
            report, agent: agent, period: period, selectedUsage: selectedUsage, selectedBucketStart: bucketStart
        ))
        }
        return UsagePanelModel(
            picker: picker,
            selected: selected,
            period: period,
            selectedBucketStart: bucketStart,
            refreshLabel: refresh.map(refreshLabel),
            content: content
        )
    }

    /// Week defaults to today and Month to the current week. A bucket that disappeared after
    /// refresh also goes to the current bucket, rather than displaying an unrelated period.
    func resolvedBucketStart(_ usage: PeriodUsage?, period: UsagePeriod, requested: Date?) -> Date? {
        guard period != .today, let usage, !usage.buckets.isEmpty else { return nil }
        if let requested, usage.buckets.contains(where: { $0.start == requested }) { return requested }
        return usage.buckets.last?.start
    }

    /// Every agent with something to show this month: replies, a limit, or an open session.
    func pickerAgents(_ report: UsageReport) -> [Agent] {
        var found = Set(report.periods[.month]?.agents.map(\.agent) ?? [])
        found.formUnion(report.limitsByAgent.keys)
        found.formUnion(report.accounts.map(\.agent))
        found.formUnion(report.sessions.map(\.summary.agent))
        return Agent.allCases.filter(found.contains)
    }

    /// "Refreshes in 3:12", counting down in minutes and seconds.
    func refreshLabel(_ refresh: UsageRefresh) -> String {
        switch refresh {
        case .refreshing:
            return "Refreshing…"
        case .next(let seconds):
            let whole = Int(max(seconds, 0).rounded(.up))
            return "Refreshes in \(whole / 60):\(String(format: "%02d", whole % 60))"
        }
    }

    // MARK: - All agents

    func all(
        _ report: UsageReport,
        usage: PeriodUsage?,
        period: UsagePeriod,
        agents: [Agent]
    ) -> AllAgentsModel {
        let periodStart = usage?.start
        let rows = agents.compactMap { agent -> AgentTableRowModel? in
            let used = usage?.usage(of: agent)
            let time = workingTime(used, agent: agent, report: report, periodStart: periodStart)
            guard used != nil || time > 0 else { return nil }
            let tokens = used?.tokens.map(format.tokens)
            // An agent with no tokens but a context reading shows how full its context is, marked
            // as an estimate, in place of "n/a". It is not tokens used, so no total adds it up.
            // Kiro reports no precise tokens; it shows the same transcript-text estimate the
            // session panel does ("~Nk"), so one Kiro number appears everywhere, and only falls
            // back to the context reading ("ctx ~Nk") when no estimate is available.
            let estimate = tokens == nil
                ? (estimatedTokensText(agent, report: report, periodStart: periodStart)
                    ?? used?.context.map(contextEstimate))
                : nil
            return AgentTableRowModel(
                agent: agent, name: agent.displayName, time: timeText(time), tokens: tokens ?? estimate,
                spend: spend(used), tokensIsEstimate: tokens == nil && estimate != nil
            )
        }
        let used = agents.compactMap { usage?.usage(of: $0) }
        let tokens = used.compactMap(\.tokens)
        let costs = used.compactMap(\.costUSD)
        let total = rows.count > 1 ? AgentTableRowModel(
            agent: nil, name: "All agents",
            time: timeText(agents.reduce(0) {
                $0 + workingTime(usage?.usage(of: $1), agent: $1, report: report, periodStart: periodStart)
            }),
            tokens: tokens.isEmpty ? nil : format.tokens(tokens.reduce(0, +)),
            spend: costs.isEmpty ? nil : format.usd(costs.reduce(0, +))
        ) : nil
        return AllAgentsModel(
            headline: headline(report.limitsByAgent, now: report.now, period: period),
            limits: agents.flatMap { agent in
                let accounts = report.accounts.filter { $0.agent == agent }
                return accounts.isEmpty
                    ? limitRows(agent, limits: report.limits(for: agent), period: period, now: report.now)
                    : accounts.flatMap {
                        limitRows(
                            agent, limits: $0.limits, period: period, now: report.now,
                            account: $0.name, accountID: $0.id, snapshot: $0.snapshot
                        )
                    }
            },
            tableTitle: Self.tableTitle(period),
            rows: rows,
            total: total,
            whereRows: whereRows(usage?.byWork ?? [], limit: Self.allWhereRows)
        )
    }

    static func tableTitle(_ period: UsagePeriod) -> String {
        switch period {
        case .today: "TODAY"
        case .week: "THIS WEEK"
        case .month: "THIS MONTH"
        }
    }

    /// "Codex runs out first: 5% of its week is left until Thu 06:57. Claude's 5-hour limit
    /// frees up at 16:40."
    func headline(_ limits: [Agent: AgentLimits], now: Date, period: UsagePeriod = .week) -> String? {
        let scoped = limits.mapValues { visibleLimits($0, period: period) }
        guard let headline = OverviewSummary.headline(limits: scoped) else { return nil }
        let standing = headline.standing
        let name = headline.agent.displayName
        let window = Self.windowNoun(standing.kind)
        var first: String
        if standing.usedPercent >= 100 {
            first = "\(name) has run out of its \(window)"
            if let reset = standing.resetsAt { first += " until \(format.moment(reset, now: now))" }
        } else {
            first = "\(name) runs out first: \(format.percentPoints(standing.leftPercent)) of its \(window) is left"
            if let reset = standing.resetsAt { first += " until \(format.moment(reset, now: now))" }
        }
        var sentences = [first + "."]
        if let other = headline.other, let reset = other.standing.resetsAt {
            let when = format.moment(reset, now: now)
            let at = when.contains(" ") ? when : "at \(when)"
            sentences.append("\(other.agent.displayName)'s \(Self.limitNoun(other.standing.kind)) frees up \(at).")
        }
        return sentences.joined(separator: " ")
    }

    /// "5% of its week", "of its 5-hour window".
    static func windowNoun(_ kind: LimitStanding.Kind) -> String {
        switch kind {
        case .fiveHour: "5-hour window"
        case .weekly: "week"
        case .monthly: "month"
        case .plan: "monthly plan"
        }
    }

    /// "Claude's 5-hour limit frees up".
    static func limitNoun(_ kind: LimitStanding.Kind) -> String {
        switch kind {
        case .fiveHour: "5-hour limit"
        case .weekly: "weekly limit"
        case .monthly: "monthly limit"
        case .plan: "plan"
        }
    }

    /// Each limit the agent shares, then each window with no live reading as it was last read or
    /// as reset; or one "no data" row for an account with no reading at all.
    func limitRows(
        _ agent: Agent, limits: AgentLimits, period: UsagePeriod, now: Date,
        account: String? = nil, accountID: String? = nil,
        snapshot: AccountUsageSnapshot? = nil
    ) -> [LimitListRowModel] {
        let label = [agent.displayName, account].compactMap { $0 }.joined(separator: " · ")
        func id(_ kind: LimitStanding.Kind) -> String { "\(agent.rawValue)-\(accountID ?? "default")-\(kind)" }
        let live = visibleStandings(limits.standings, period: period).map { standing in
            LimitListRowModel(
                id: id(standing.kind),
                agent: agent,
                name: "\(label) \(Self.shortWindow(standing.kind))",
                fraction: standing.usedPercent / 100,
                used: format.percentPoints(standing.usedPercent),
                freesUp: standing.resetsAt.map { "Resets \(format.moment($0, now: now))" } ?? "Reset time unavailable",
                isNearlyUsed: standing.isNearlyUsed
            )
        }
        let last = lastWindows(limits, snapshot: snapshot, period: period, now: now).map { window in
            LimitListRowModel(
                id: id(window.kind),
                agent: agent,
                name: "\(label) \(Self.shortWindow(window.kind))" + (window.isReset ? " limit reset" : ""),
                fraction: window.percent.map { $0 / 100 } ?? 0,
                used: window.percent.map { format.percentPoints($0) } ?? "",
                freesUp: detail(window, now: now),
                isNearlyUsed: window.isNearlyUsed
            )
        }
        if !live.isEmpty || !last.isEmpty { return live + last }
        // An agent that only shares a window outside the selected period, or an account whose
        // reading is of another period, is not an empty row on this one. Month shows no rolling
        // window, so a missing reading is nothing to report there.
        guard limits.standings.isEmpty, limits.resetWindows.isEmpty, snapshot == nil,
              account != nil, period != .month else { return [] }
        return [LimitListRowModel(
            id: "\(agent.rawValue)-\(accountID ?? "none")-none", agent: agent, name: label, fraction: nil, used: "",
            freesUp: "No recent limit reading", isNearlyUsed: false
        )]
    }

    static func shortWindow(_ kind: LimitStanding.Kind) -> String {
        switch kind {
        case .fiveHour: "5-hour"
        case .weekly: "week"
        case .monthly, .plan: "month"
        }
    }

    // MARK: - One agent

    func agentView(
        _ report: UsageReport,
        agent: Agent,
        period: UsagePeriod,
        selectedUsage: PeriodUsage?,
        selectedBucketStart: Date?
    ) -> AgentUsageModel {
        let fullUsage = report.periods[period]?.byAgent[agent]
        let usage = selectedUsage?.byAgent[agent] ?? (selectedBucketStart == nil ? fullUsage : nil)
        let used = usage?.usage(of: agent)
        let fullUsed = fullUsage?.usage(of: agent)
        let open = report.sessions.map(\.summary).filter { $0.agent == agent }
        let limits = report.limits(for: agent)
        let accounts = report.accounts.filter { $0.agent == agent }
        // Only an account with no reading at all: no live limit, no cache and no window that reset.
        let accountsWithoutReadings = period == .month ? [] : accounts.filter {
            $0.limits.standings.isEmpty && $0.limits.resetWindows.isEmpty && $0.snapshot == nil
        }.map(\.name)
        let hasTokens = fullUsed?.tokens != nil
        let models = (usage?.byModel ?? []).prefix(Self.modelRows).map { share in
            ModelShareRowModel(
                name: share.model.displayName, percent: format.percent(share.share),
                credits: share.credits.map(creditsText)
            )
        }
        // Where the time went always shows; the second section ranks the same work by tokens, or
        // by credits for an agent that bills in them (Kiro), and is omitted when it reports
        // neither. A narrower collapsed count when the models column shares the row.
        let byWork = usage?.byWork ?? []
        let collapsed = models.isEmpty ? Self.allWhereRows : Self.agentWhereRows
        let timeSection = whereFull(byWork, limit: collapsed)
        let metricSection = whereByMetric(byWork, limit: collapsed)
        return AgentUsageModel(
            agent: agent,
            note: accountsWithoutReadings.isEmpty
                ? note(
                    agent, used: fullUsed, limits: limits,
                    hasAccountUsage: accounts.contains { $0.snapshot != nil || !$0.limits.resetWindows.isEmpty }
                )
                : NoteModel(
                    title: "Limit reading unavailable",
                    text: "No limit reading saved for \(accountsWithoutReadings.joined(separator: ", ")) yet."
                ),
            limits: accounts.isEmpty
                ? limitBars(limits, period: period, agent: agent, now: report.now)
                : accounts.flatMap {
                    limitBars(
                        $0.limits, period: period, agent: agent, now: report.now,
                        account: $0.name, snapshot: $0.snapshot
                    )
                },
            stats: hasTokens
                ? tokenStats(used, agent: agent, report: report, includesOpenSessions: selectedBucketStart == nil, periodStart: report.periods[period]?.start)
                : activityStats(used, open: open, report: report, includesOpenSessions: selectedBucketStart == nil, periodStart: report.periods[period]?.start),
            chart: fullUsage.flatMap {
                chart($0, period: period, mode: chartMode(hasTokens: hasTokens, usage: $0), now: report.now, selectedBucketStart: selectedBucketStart)
            },
            models: Array(models),
            whereRows: timeSection.rows,
            whereCollapsedCount: timeSection.collapsedCount,
            whereMore: timeSection.more,
            whereMetric: metricSection?.rows ?? [],
            whereMetricTitle: metricSection?.title,
            whereMetricCollapsedCount: metricSection?.collapsedCount ?? 0,
            whereMetricMore: metricSection?.more,
            localCredits: localCredits(agent: agent, limits: limits, period: period)
        )
    }

    /// A faint "on this Mac" credit line below the chart, for an agent that bills in credits
    /// (Kiro) when its local buckets carry something to show. Today shows the day's credits;
    /// Week and Month show the current seven-day band's range and credits. Nil for every other
    /// agent, when there are no local buckets, or when the current band is unknown. The sums are
    /// local to this Mac, so the label always ends "on this Mac" to keep them apart from the
    /// plan total.
    func localCredits(agent: Agent, limits: AgentLimits, period: UsagePeriod) -> LocalCreditsModel? {
        guard agent == .kiro, let buckets = limits.localCreditBuckets else { return nil }
        let scope = CreditBuckets.scopeLabel
        switch period {
        case .today:
            guard buckets.day > 0 else { return nil }
            return LocalCreditsModel(caption: "Today - \(creditsLine(buckets.day)) \(scope)")
        case .week, .month:
            guard let index = buckets.currentBandIndex, buckets.bands.indices.contains(index) else { return nil }
            let band = buckets.bands[index]
            guard band.credits > 0 else { return nil }
            let range = "Days \(band.firstDay)-\(band.lastDay)"
            return LocalCreditsModel(caption: "\(range) - \(creditsLine(band.credits)) \(scope)")
        }
    }

    /// "12.4 CR - ~$0.50": credits with the dollar estimate, joined with " - " for the local
    /// credit caption. Kept apart from `creditsText`, whose "·" separator the stats and models
    /// columns use.
    private func creditsLine(_ credits: Double) -> String {
        "\(format.credits(credits)) CR - ~\(format.usd(format.creditsUSD(credits)))"
    }

    /// What the agent does not share, said once at the top, so the missing numbers are not a
    /// surprise. Claude's limits are missing only until its status line saves them.
    func note(
        _ agent: Agent, used: AgentPeriodUsage?, limits: AgentLimits,
        hasAccountUsage: Bool = false
    ) -> NoteModel? {
        let hasLimits = !limits.standings.isEmpty || !limits.resetWindows.isEmpty || hasAccountUsage
        let hasTokens = used?.tokens != nil
        let hasCost = used?.costUSD != nil || used?.credits != nil
        if agent == .claudeCode && !hasLimits && hasTokens {
            return NoteModel(
                title: "Claude's limits",
                text: "Claude shares its limits only with a status line. The README has the one setting that turns it on."
            )
        }
        let missing = [hasTokens ? nil : "tokens", hasCost ? nil : "cost", hasLimits ? nil : "limits"].compactMap { $0 }
        guard !missing.isEmpty, !(agent == .claudeCode && hasTokens) else { return nil }
        let list = missing.count == 1 ? missing[0] : missing.dropLast().joined(separator: ", ") + " or " + missing.last!
        // An agent that bills in credits shows them, so the note says so (Kiro).
        let shows = hasTokens ? "what it does share"
            : used?.credits != nil ? "credits, time and activity" : "time and activity only"
        return NoteModel(
            title: agent.displayName,
            text: "\(agent.displayName) doesn't share \(list) on this Mac, so this shows \(shows)."
        )
    }

    /// Each limit as a bar: the shortest window first on Today, the week first otherwise. A window
    /// with no live reading follows the same order, as it was last read or as reset.
    func limitBars(
        _ limits: AgentLimits, period: UsagePeriod, agent: Agent, now: Date,
        account: String? = nil, snapshot: AccountUsageSnapshot? = nil
    ) -> [BarRowModel] {
        let order: [LimitStanding.Kind] = period == .today
            ? [.fiveHour, .weekly, .monthly, .plan] : [.weekly, .monthly, .plan, .fiveHour]
        func rank(_ kind: LimitStanding.Kind) -> Int { order.firstIndex(of: kind) ?? 0 }
        let who = account.map { "\($0) · " } ?? ""
        let standings = visibleStandings(limits.standings, period: period).sorted { rank($0.kind) < rank($1.kind) }
        var bars: [(kind: LimitStanding.Kind, bar: BarRowModel)] = []
        for (index, standing) in standings.enumerated() {
            // A credit plan (Kiro) names its allowance and credits used; every other window
            // keeps the generic name and the plain reset detail.
            let name = planName(standing, limits: limits) ?? OverlayPresenter.limitName(standing.kind)
            let detail = planDetail(standing, now: now) ?? standing.resetsAt.map { reset in
                "Resets \(format.moment(reset, now: now)) · in \(format.duration(reset.timeIntervalSince(now)))"
            } ?? "Reset time unavailable"
            bars.append((standing.kind, BarRowModel(
                title: "\(who)\(name) \(format.percentPoints(standing.usedPercent))",
                detail: detail,
                fraction: standing.usedPercent / 100,
                highlightFraction: nil,
                isNearlyUsed: standing.isNearlyUsed,
                note: index == 0 ? pace(standing, now: now) : nil
            )))
        }
        for window in lastWindows(limits, snapshot: snapshot, period: period, now: now) {
            let name = OverlayPresenter.limitName(window.kind)
            bars.append((window.kind, BarRowModel(
                title: window.percent.map { "\(who)\(name) \(format.percentPoints($0))" } ?? "\(who)\(name) reset",
                detail: detail(window, now: now),
                fraction: window.percent.map { $0 / 100 } ?? 0,
                highlightFraction: nil,
                isNearlyUsed: window.isNearlyUsed,
                note: nil
            )))
        }
        return bars.sorted { rank($0.kind) < rank($1.kind) }.map(\.bar)
    }

    /// The windows of this period that no live reading covers, as last known: an account cache's
    /// percentages and the windows seen resetting, the later reading of each kind winning. Nothing
    /// hides one for being old; a reset that has passed says so instead of showing its percentage.
    func lastWindows(
        _ limits: AgentLimits, snapshot: AccountUsageSnapshot?, period: UsagePeriod, now: Date
    ) -> [LastWindow] {
        let resets = limits.resetWindows.map {
            LastWindow(kind: $0.kind, state: .reset($0.resetsAt), readAt: $0.readAt)
        }
        var latest: [LimitStanding.Kind: LastWindow] = [:]
        for window in resets + (snapshot.map { snapshotWindows($0, now: now) } ?? []) {
            if let known = latest[window.kind], known.readAt > window.readAt { continue }
            latest[window.kind] = window
        }
        let live = Set(limits.standings.map(\.kind))
        let order: [LimitStanding.Kind] = [.fiveHour, .weekly, .monthly, .plan]
        return latest.values
            .filter { Self.isVisible($0.kind, in: period) && !live.contains($0.kind) }
            .sorted { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
    }

    /// What an account cache last read of each window it has a percentage for. A reset time that
    /// has passed ends the reading: its percentage was of a window that is over.
    func snapshotWindows(_ snapshot: AccountUsageSnapshot, now: Date) -> [LastWindow] {
        let windows: [(LimitStanding.Kind, Double?, Date?)] = [
            (.fiveHour, snapshot.fiveHourPercent, snapshot.fiveHourResetsAt),
            (.weekly, snapshot.weeklyPercent, snapshot.weeklyResetsAt),
        ]
        return windows.compactMap { kind, percent, resetsAt -> LastWindow? in
            guard let percent else { return nil }
            if let resetsAt, resetsAt <= now {
                return LastWindow(kind: kind, state: .reset(resetsAt), readAt: snapshot.readAt)
            }
            return LastWindow(
                kind: kind, state: .reading(percent: percent, resetsAt: resetsAt), readAt: snapshot.readAt
            )
        }
    }

    /// "Resets Thu 09:00 · in 2d 18h · read 15:13", "Reset time unknown · read 15:13", or
    /// "Reset Thu 09:00 · no reading since".
    func detail(_ window: LastWindow, now: Date) -> String {
        switch window.state {
        case .reset(let date):
            return "Reset \(format.moment(date, now: now)) · no reading since"
        case .reading(_, let resetsAt):
            let read = "read \(format.moment(window.readAt, now: now))"
            guard let resetsAt else { return "Reset time unknown · \(read)" }
            let left = format.duration(resetsAt.timeIntervalSince(now))
            return "Resets \(format.moment(resetsAt, now: now)) · in \(left) · \(read)"
        }
    }

    /// A credit plan's title uses its own name in title case ("Kiro Power"), falling back to
    /// nil so the caller keeps the generic limit name. Only the plan kind carries a name.
    private func planName(_ standing: LimitStanding, limits: AgentLimits) -> String? {
        guard standing.kind == .plan, let name = limits.plan?.name else { return nil }
        return format.planName(name)
    }

    /// A credit plan's detail: credits used of the allowance, then the reset. "1,260 of 10,000
    /// credits - resets 1 Nov - in 30 days", or just "1,260 of 10,000 credits" with no reset.
    /// nil for any other kind, so the caller shows its own reset detail.
    private func planDetail(_ standing: LimitStanding, now: Date) -> String? {
        guard standing.kind == .plan, let used = standing.creditsUsed, let limit = standing.creditsLimit else {
            return nil
        }
        let credits = "\(format.credits(used)) of \(format.credits(limit)) credits"
        guard let reset = standing.resetsAt else { return credits }
        return "\(credits) - resets \(format.moment(reset, now: now)) - in \(format.duration(reset.timeIntervalSince(now)))"
    }

    /// The account-usage cache only contains percentages. It has neither a reset timestamp nor
    /// a way to say which window those percentages still belong to, so after fifteen minutes it
    /// cannot safely describe a live limit. A status-line reading with a future `resetsAt` wins
    /// over this cache through `limits` above and remains visible for its own account.
    func currentSnapshot(_ snapshot: AccountUsageSnapshot?, now: Date) -> AccountUsageSnapshot? {
        guard let snapshot, now.timeIntervalSince(snapshot.readAt) <= 15 * 60 else { return nil }
        return snapshot
    }

    func snapshotValues(_ snapshot: AccountUsageSnapshot, period: UsagePeriod) -> [(String, Double?)] {
        switch period {
        case .today: [("5-hour", snapshot.fiveHourPercent)]
        case .week: [("week", snapshot.weeklyPercent)]
        case .month: []
        }
    }

    /// Each period shows the limit that runs over it: Today the 5-hour window, Week the weekly
    /// limit, and Month only a monthly allowance, since neither rolling window says anything
    /// about a month.
    func visibleStandings(_ standings: [LimitStanding], period: UsagePeriod) -> [LimitStanding] {
        standings.filter { Self.isVisible($0.kind, in: period) }
    }

    func visibleLimits(_ limits: AgentLimits, period: UsagePeriod) -> AgentLimits {
        let showsWeek = Self.isVisible(.weekly, in: period)
        return AgentLimits(
            fiveHour: Self.isVisible(.fiveHour, in: period) ? limits.fiveHour : nil,
            weekly: showsWeek ? limits.weekly : nil,
            monthly: limits.monthly,
            creditsUsedThisMonth: limits.creditsUsedThisMonth,
            weeklyUsedToday: showsWeek ? limits.weeklyUsedToday : nil,
            weeklyUsedByDay: showsWeek ? limits.weeklyUsedByDay : nil,
            plan: limits.plan, creditsUsedToday: limits.creditsUsedToday, creditsPerDayLeft: limits.creditsPerDayLeft,
            localCreditBuckets: limits.localCreditBuckets
        )
    }

    private static func isVisible(_ kind: LimitStanding.Kind, in period: UsagePeriod) -> Bool {
        switch kind {
        case .fiveHour: period == .today
        case .weekly: period == .week
        default: true
        }
    }

    /// "On pace to end the week at about 90%.", or when it runs out first.
    func pace(_ standing: LimitStanding, now: Date) -> String? {
        let span = switch standing.kind {
        case .fiveHour: "the window"
        case .weekly: "the week"
        case .monthly, .plan: "the month"
        }
        if let runsOut = standing.runsOutAt {
            return "On pace to run out around \(format.moment(runsOut, now: now)), before \(span) ends."
        }
        guard let left = standing.projectedLeftAtReset else { return nil }
        return "On pace to end \(span) at about \(format.approximatePercentPoints(100 - left))."
    }

    /// Spent, Tokens, Time and Sessions, for an agent that reports tokens.
    func tokenStats(
        _ used: AgentPeriodUsage?, agent: Agent, report: UsageReport,
        includesOpenSessions: Bool = true, periodStart: Date? = nil
    ) -> [StatModel] {
        let time = workingTime(
            used, agent: agent, report: report, includesOpenSessions: includesOpenSessions, periodStart: periodStart
        )
        return [
            spend(used).map { StatModel(label: used?.costUSD != nil ? "Spent" : "Credits", value: $0) },
            used?.tokens.map { StatModel(label: "Tokens", value: format.tokens($0)) },
            time >= 60 ? StatModel(label: "Time", value: format.duration(time)) : nil,
            (used?.sessionCount ?? 0) > 0 ? StatModel(label: "Sessions", value: "\(used!.sessionCount)") : nil,
        ].compactMap { $0 }
    }

    /// Credits, Time, Sessions, Prompts and Tool calls, for an agent that reports no tokens;
    /// Credits only for an agent that bills in them. An agent that records nothing per reply is
    /// measured by its open sessions.
    func activityStats(
        _ used: AgentPeriodUsage?, open: [SessionSummary], report: UsageReport,
        includesOpenSessions: Bool = true, periodStart: Date? = nil
    ) -> [StatModel] {
        let recorded = (used?.turnCount ?? 0) > 0
        // A session with no overlap in the selected period should not inflate the period's
        // counts, so sessions, prompts and tool calls only count sessions whose active span
        // touches the period; the time is clamped to that same overlap.
        let inPeriod = open.filter { periodActiveDuration($0, periodStart: periodStart, now: report.now) > 0 }
        let fallbackSessions = periodStart == nil ? open : inPeriod
        let time = recorded ? used?.workingTime ?? 0
            : includesOpenSessions ? open.reduce(0) { $0 + periodActiveDuration($1, periodStart: periodStart, now: report.now) } : 0
        let sessions = recorded ? used?.sessionCount ?? 0 : includesOpenSessions ? fallbackSessions.count : 0
        let prompts = recorded ? used?.turnCount ?? 0 : includesOpenSessions ? fallbackSessions.reduce(0) { $0 + $1.turnCount } : 0
        let toolCalls = recorded ? used?.toolCalls : includesOpenSessions ? fallbackSessions.compactMap(\.activity?.toolCalls).reduce(0, +) : nil
        return [
            used?.credits.map { StatModel(label: "Credits", value: creditsText($0)) },
            time >= 60 ? StatModel(label: "Time", value: format.duration(time)) : nil,
            sessions > 0 ? StatModel(label: "Sessions", value: "\(sessions)") : nil,
            prompts > 0 ? StatModel(label: "Prompts", value: format.grouped(prompts)) : nil,
            toolCalls.flatMap { $0 > 0 ? StatModel(label: "Tool calls", value: format.grouped($0)) : nil },
        ].compactMap { $0 }
    }

    /// How a chart bar's height is measured. An agent that reports tokens plots them; one that
    /// bills in credits with none reported (Kiro) plots its credits; anything else plots the
    /// hours it worked.
    enum ChartMode {
        case tokens, credits, hours
    }

    /// Tokens if the agent reports them, else credits if it billed any over the period, else the
    /// hours it worked. Kiro's Auto agent reports no tokens but bills in credits, so its chart
    /// plots credits.
    func chartMode(hasTokens: Bool, usage: PeriodUsage) -> ChartMode {
        if hasTokens { return .tokens }
        if usage.buckets.contains(where: { $0.credits > 0 }) { return .credits }
        return .hours
    }

    /// Tokens, credits for an agent that bills in them (Kiro), or hours for an agent with
    /// neither: a bar a day on Week, a week on Month. Today has no chart, and a chart with
    /// nothing in it is left out.
    func chart(
        _ usage: PeriodUsage,
        period: UsagePeriod,
        mode: ChartMode,
        now: Date,
        selectedBucketStart: Date?
    ) -> ChartModel? {
        guard period != .today, !usage.buckets.isEmpty else { return nil }
        let values = usage.buckets.map { bucket -> Double in
            switch mode {
            case .tokens: Double(bucket.tokens)
            case .credits: bucket.credits
            case .hours: bucket.workingTime
            }
        }
        guard let top = values.max(), top > 0 else { return nil }
        let busiest = values.firstIndex(of: top)
        let last = values.count - 1
        func value(_ index: Int) -> String {
            switch mode {
            case .tokens: format.tokens(usage.buckets[index].tokens)
            case .credits: "\(format.credits(usage.buckets[index].credits)) CR"
            case .hours: format.hours(usage.buckets[index].workingTime)
            }
        }
        let bars = usage.buckets.indices.map { index in
            let start = max(usage.buckets[index].start, usage.start)
            let label = switch period {
            case .week: index == last ? "Today" : format.weekday(start)
            default: "\(index == last ? "Now" : format.dayOfMonth(start)) · \(value(index))"
            }
            return ChartBarModel(
                start: usage.buckets[index].start,
                label: label,
                fraction: values[index] / top,
                isBusiest: index == busiest && index != last,
                isCurrent: index == last,
                isSelected: usage.buckets[index].start == selectedBucketStart
            )
        }
        let unit = switch mode {
        case .tokens: "TOKENS"
        case .credits: "CREDITS"
        case .hours: "HOURS"
        }
        return ChartModel(
            title: period == .week ? "\(unit) PER DAY" : "\(unit) PER WEEK",
            caption: period == .week
                ? busiest.map { "busiest \($0 == last ? "today" : format.weekday(usage.buckets[$0].start)) · \(value($0))" } ?? ""
                : format.monthName(usage.start),
            bars: bars
        )
    }

    // MARK: - Shared

    /// The period's working time, or for an agent that records nothing per reply, the time its
    /// open sessions have been active. When `periodStart` is given, each open session's active
    /// time is clamped to its overlap with the period, so a session open for days does not add
    /// its whole life to Today. When `periodStart` is nil the full active time is used.
    func workingTime(
        _ used: AgentPeriodUsage?, agent: Agent, report: UsageReport,
        includesOpenSessions: Bool = true, periodStart: Date? = nil
    ) -> TimeInterval {
        if let used, used.workingTime > 0 { return used.workingTime }
        guard includesOpenSessions else { return 0 }
        let open = report.sessions.map(\.summary).filter { $0.agent == agent }
        return open.reduce(0) { $0 + periodActiveDuration($1, periodStart: periodStart, now: report.now) }
    }

    /// An open session's active time within the selected period. `activeDuration` is a scalar
    /// over the session's whole life, not a timeline, so the in-period share is approximated by
    /// the fraction of the session's life that falls inside `[periodStart, now]`. A session that
    /// is still open counts as present up to `now`, since `lastActivityAt` can lag (an agent
    /// that writes no per-reply record leaves it at the start). With no `periodStart` the full
    /// active time is returned unchanged.
    func periodActiveDuration(_ session: SessionSummary, periodStart: Date?, now: Date) -> TimeInterval {
        guard let periodStart else { return session.activeDuration }
        let lifeEnd = session.state == .ended ? session.lastActivityAt : max(session.lastActivityAt, now)
        let spanStart = max(session.startedAt, periodStart)
        let spanEnd = min(lifeEnd, now)
        guard spanEnd > spanStart else { return 0 }
        let lifeSpan = max(lifeEnd.timeIntervalSince(session.startedAt), 1)
        let overlapFraction = min(max(spanEnd.timeIntervalSince(spanStart) / lifeSpan, 0), 1)
        return session.activeDuration * overlapFraction
    }

    private func timeText(_ time: TimeInterval) -> String {
        time >= 60 ? format.duration(time) : UsageFormatter.notReported
    }

    /// "$4.20", or credits for an agent that bills in them; nil when neither is reported.
    private func spend(_ used: AgentPeriodUsage?) -> String? {
        if let cost = used?.costUSD { return format.usd(cost) }
        return used?.credits.map(creditsText)
    }

    /// "12.4 CR · ~$0.50", "3,917 CR · ~$156.68": credits with the dollar estimate beside them.
    private func creditsText(_ credits: Double) -> String {
        format.creditsWithUSD(credits)
    }

    /// "ctx ~126k": how full the context is now, said as an estimate because it is not tokens used.
    private func contextEstimate(_ context: ContextUsage) -> String {
        "ctx ~\(format.tokens(context.used))"
    }

    /// "~126k": the transcript-text token estimate for an agent whose files carry no precise
    /// counts (Kiro's Auto), summed over the agent's open sessions that touch the period, so the
    /// usage panel shows the same figure the session panel does. Only Kiro has such estimates
    /// today, and the sum is input-plus-output only, never a count and never added to a total.
    /// Nil when the agent is not Kiro or no session carries an estimate for the period.
    func estimatedTokensText(_ agent: Agent, report: UsageReport, periodStart: Date?) -> String? {
        guard agent == .kiro else { return nil }
        let sessions = report.sessions.map(\.summary).filter {
            $0.agent == agent && periodActiveDuration($0, periodStart: periodStart, now: report.now) > 0
        }
        let total = sessions.reduce(0) { sum, summary in
            guard let estimate = summary.estimatedTokens else { return sum }
            return sum + (estimate.input ?? 0) + (estimate.output ?? 0)
        }
        return total > 0 ? "~\(format.tokens(total))" : nil
    }

    /// The top pieces of work by time, then one row adding up the rest.
    func whereRows(_ work: [WorkTime], limit: Int) -> [TimeRowModel] {
        let shown = work.count > limit ? Array(work.prefix(limit - 1)) : work
        var rows = shown.map { item in
            TimeRowModel(
                id: "\(item.tag.project)/\(item.tag.concern)",
                agent: item.agent,
                // Work outside git, or in the home folder, has one name, said once.
                label: item.tag.project == item.tag.concern
                    ? item.tag.project : "\(item.tag.projectShortName) · \(item.tag.concern)",
                percent: format.percent(item.share),
                time: format.duration(item.workingTime)
            )
        }
        let rest = work.dropFirst(shown.count)
        if !rest.isEmpty {
            rows.append(TimeRowModel(
                id: "more", agent: nil, label: "\(rest.count) more",
                percent: format.percent(rest.reduce(0) { $0 + $1.share }),
                time: format.duration(rest.reduce(0) { $0 + $1.workingTime })
            ))
        }
        return rows
    }

    /// Where the time went as the full ordered list, plus the number of itemized rows to show
    /// while collapsed (`limit - 1`, leaving room for the "+N more" row) and that aggregate row.
    /// The view shows the collapsed slice and the aggregate, or expands to every row. `more` is
    /// nil when nothing is hidden at the collapsed count.
    func whereFull(_ work: [WorkTime], limit: Int)
        -> (rows: [TimeRowModel], collapsedCount: Int, more: TimeRowModel?)
    {
        let rows = work.map { item in
            TimeRowModel(
                id: workID(item.tag),
                agent: item.agent,
                label: workLabel(item.tag),
                percent: format.percent(item.share),
                time: format.duration(item.workingTime)
            )
        }
        let collapsedCount = max(limit - 1, 0)
        let hidden = work.dropFirst(collapsedCount)
        let more = work.count > limit && !hidden.isEmpty
            ? TimeRowModel(
                id: "more", agent: nil, label: "\(hidden.count) more",
                percent: format.percent(hidden.reduce(0) { $0 + $1.share }),
                time: format.duration(hidden.reduce(0) { $0 + $1.workingTime })
            )
            : nil
        return (rows, collapsedCount, more)
    }

    /// Which metric the second "where … went" section ranks by for this work: tokens when any
    /// of the work reports a token count, else credits when any bills them (Kiro), else none.
    enum WorkMetric { case tokens, credits }

    private static func metric(of work: [WorkTime]) -> WorkMetric? {
        // Credits are an agent's real billed unit (Kiro), so prefer them. Token agents that
        // bill no credits (Claude, Codex, Cursor) still get a tokens section.
        if work.contains(where: { $0.credits != nil }) { return .credits }
        if work.contains(where: { $0.tokens != nil }) { return .tokens }
        return nil
    }

    /// The second breakdown section, ranked by tokens or credits. Nil when the work reports
    /// neither, so the view shows only the time section. Rows carry the work's share of the
    /// metric and its value (tokens as "280k", credits as "61.7 CR · ~$2.47"); the collapsed
    /// count and "+N more" aggregate mirror the time section so both expand the same way.
    func whereByMetric(_ work: [WorkTime], limit: Int)
        -> (title: String, rows: [WorkMetricRowModel], collapsedCount: Int, more: WorkMetricRowModel?)?
    {
        guard let metric = Self.metric(of: work) else { return nil }
        let title = metric == .tokens ? "WHERE THE TOKENS WENT" : "WHERE THE CREDITS WENT"
        func amount(_ item: WorkTime) -> Double {
            switch metric {
            case .tokens: Double(item.tokens ?? 0)
            case .credits: item.credits ?? 0
            }
        }
        func valueText(_ item: WorkTime) -> String {
            switch metric {
            case .tokens: format.tokens(item.tokens)
            case .credits: creditsText(item.credits ?? 0)
            }
        }
        let ranked = work.sorted { (amount($0), $0.tag.concern) > (amount($1), $1.tag.concern) }
        let total = ranked.reduce(0) { $0 + amount($1) }
        func share(_ item: WorkTime) -> String { format.percent(total > 0 ? amount(item) / total : 0) }
        let rows = ranked.map { item in
            WorkMetricRowModel(
                id: workID(item.tag), agent: item.agent, label: workLabel(item.tag),
                percent: share(item), value: valueText(item)
            )
        }
        let collapsedCount = max(limit - 1, 0)
        let hidden = ranked.dropFirst(collapsedCount)
        let more = ranked.count > limit && !hidden.isEmpty
            ? WorkMetricRowModel(
                id: "more", agent: nil, label: "\(hidden.count) more",
                percent: format.percent(total > 0 ? hidden.reduce(0) { $0 + amount($1) } / total : 0),
                value: metric == .tokens
                    ? format.tokens(hidden.reduce(0) { $0 + ($1.tokens ?? 0) })
                    : creditsText(hidden.reduce(0) { $0 + ($1.credits ?? 0) })
            )
            : nil
        return (title, rows, collapsedCount, more)
    }

    /// The row id for a piece of work, stable across the time and metric sections.
    private func workID(_ tag: WorkTag) -> String { "\(tag.project)/\(tag.concern)" }

    /// The row label for a piece of work. Work outside git, or in the home folder, has one name,
    /// said once; otherwise the short project and the concern.
    private func workLabel(_ tag: WorkTag) -> String {
        tag.project == tag.concern ? tag.project : "\(tag.projectShortName) · \(tag.concern)"
    }
}
