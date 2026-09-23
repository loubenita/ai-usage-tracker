import Foundation
import Testing
@testable import UsageDomain

/// The overview, agent by agent: each agent's usage in its own units, the agents not used,
/// the limit each row leads with, and the sentence that names the tightest limit.
@Suite("Each agent's usage in a period")
struct PeriodUsageTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Tuesday 22 September 2026, 14:00 UTC.
    let now = Date(timeIntervalSince1970: 1_790_085_600)
    var today: Date { calendar.startOfDay(for: now) }
    let app = WorkTag(project: "app", concern: "main")
    let site = WorkTag(project: "site", concern: "copy")

    func turn(
        _ agent: Agent, _ session: String, minutesAgo: Double, tokens: Int? = nil, cost: Decimal? = nil,
        credits: Double? = nil, tag: WorkTag? = nil
    ) -> Turn {
        Turn(
            id: "\(session)-\(minutesAgo)", timestamp: now - minutesAgo * 60, agent: agent, sessionID: session,
            model: "m", work: Work(tag: tag ?? app), tokens: tokens.map { TokenUsage(input: $0, output: 0) },
            cost: Cost(usd: cost), context: nil, credits: credits
        )
    }

    var turns: [Turn] {
        var turns: [Turn] = []
        // Claude: two sessions side by side, 20 and 10 minutes each, with tokens and a price.
        for step in 0...4 {
            turns.append(turn(.claudeCode, "c1", minutesAgo: 60 - Double(step) * 5, tokens: 1_000, cost: 1))
        }
        for step in 0...2 {
            turns.append(turn(.claudeCode, "c2", minutesAgo: 58 - Double(step) * 5, tokens: 500, cost: 1, tag: site))
        }
        // Kiro: credits and no tokens, as its Auto agent reports.
        turns.append(turn(.kiro, "k", minutesAgo: 30, credits: 2))
        turns.append(turn(.kiro, "k", minutesAgo: 27, credits: 1.5))
        // Codex: tokens and no price.
        turns.append(turn(.codex, "x", minutesAgo: 90, tokens: 4_000))
        turns.append(turn(.codex, "x", minutesAgo: 86, tokens: 4_000))
        // Yesterday's Claude reply is not today's.
        turns.append(turn(.claudeCode, "old", minutesAgo: 24 * 60, tokens: 99_999, cost: 9))
        return turns
    }

    func today(open: Set<Agent> = []) -> PeriodUsage {
        PeriodUsageBuilder.make(.today, turns: turns, start: today, bucketStarts: [], openAgents: open)
    }

    @Test func eachAgentIsCountedInItsOwnUnits() throws {
        let usage = today()
        let claude = try #require(usage.usage(of: .claudeCode))
        #expect(claude.workingTime == 30 * 60)
        #expect(claude.tokens == 6_500)
        #expect(claude.costUSD == 8)
        #expect(claude.credits == nil)
        // An agent with credits and no tokens: its tokens are unknown, not zero.
        let kiro = try #require(usage.usage(of: .kiro))
        #expect(kiro.tokens == nil)
        #expect(kiro.credits == 3.5)
        #expect(kiro.workingTime == 3 * 60)
        // An agent with tokens and no price.
        let codex = try #require(usage.usage(of: .codex))
        #expect(codex.tokens == 8_000)
        #expect(codex.costUSD == nil)
        #expect(usage.workingTime == 37 * 60)
        // Most working time first.
        #expect(usage.agents.map(\.agent) == [.claudeCode, .codex, .kiro])
    }

    @Test func agentsWithNothingInThePeriodAreNotUsed() {
        #expect(today().unused == [.cursor, .opencode])
        // Cursor records no replies, but a session open today counts as used.
        let withCursor = today(open: [.cursor])
        #expect(withCursor.unused == [.opencode])
        #expect(withCursor.usage(of: .cursor)?.onlyOpenSessions == true)
        #expect(withCursor.usage(of: .cursor)?.tokens == nil)
    }

    @Test func whereTheTimeWentSharesTheWorkingTime() {
        let work = today().byWork
        #expect(work.map(\.tag) == [app, site])
        // 20 min Claude + 4 Codex + 3 Kiro on the app, 10 min Claude on the site, of 37.
        let minutes: [TimeInterval] = [27 * 60, 10 * 60]
        #expect(work.map(\.workingTime) == minutes)
        #expect(abs(work[0].share - 27.0 / 37) < 1e-9)
    }

    @Test func theChartCountsTokensPerBucketFromThePeriodsStart() {
        let yesterday = today.addingTimeInterval(-86_400)
        let week = PeriodUsageBuilder.make(
            .week, turns: turns, start: yesterday, bucketStarts: [yesterday, today], openAgents: []
        )
        #expect(week.tokenAgents == [.claudeCode, .codex])
        #expect(week.buckets.map(\.tokens) == [99_999, 14_500])
        #expect(week.totalTokens == 114_499)
        // A bucket that starts before the period counts only from the period's start.
        let fromToday = PeriodUsageBuilder.make(.month, turns: turns, start: today, bucketStarts: [yesterday], openAgents: [])
        #expect(fromToday.buckets.map(\.tokens) == [14_500])
    }

    // MARK: - Limits

    func report(_ kind: LimitWindowKind, used: Double, resets: Date, runsOut: Date? = nil, left: Double? = nil) -> LimitReport {
        LimitReport(
            kind: kind, usedPercent: used, resetsAt: resets, readAt: now, percentPerHour: nil, runsOutAt: runsOut,
            projectedLeftAtReset: left, calendarDaysLeft: 2
        )
    }

    var limits: [Agent: AgentLimits] {
        let thursday = now + 2 * 86_400
        let plan = PlanUsage(
            name: "KIRO PRO", creditsUsed: 312, creditsLimit: 1_000, usedPercent: 31.2, resetsAt: now + 9 * 86_400, readAt: now
        )
        return [
            .claudeCode: AgentLimits(
                fiveHour: report(.fiveHour, used: 62, resets: now + 2 * 3600, runsOut: now + 5_400),
                weekly: report(.weekly, used: 48, resets: thursday, left: 10), monthly: nil
            ),
            .codex: AgentLimits(fiveHour: nil, weekly: report(.weekly, used: 95, resets: thursday), monthly: nil),
            // An agent with limits and no tokens.
            .kiro: AgentLimits(fiveHour: nil, weekly: nil, monthly: nil, plan: plan),
        ]
    }

    @Test func eachRowLeadsWithTheLimitThatFitsThePeriod() throws {
        let claude = try #require(limits[.claudeCode])
        // Today: the 5-hour window, used more than the week; the week is mentioned under it.
        #expect(claude.headline(for: .today)?.kind == .fiveHour)
        #expect(claude.secondary(for: .today)?.kind == .weekly)
        // A week or a month is measured against the week.
        #expect(claude.headline(for: .week)?.kind == .weekly)
        #expect(claude.headline(for: .month)?.kind == .weekly)
        #expect(claude.secondary(for: .week) == nil)
        // Kiro has only its monthly plan, in credits.
        let kiro = try #require(limits[.kiro]?.headline(for: .today))
        #expect(kiro.kind == .plan)
        #expect(kiro.creditsUsed == 312 && kiro.creditsLimit == 1_000)
        #expect(limits[.codex]?.headline(for: .today)?.isNearlyUsed == true)
        #expect(claude.headline(for: .today)?.isNearlyUsed == false)
        // An agent with no limits has no heading limit.
        #expect(AgentLimits.none.headline(for: .today) == nil)
    }

    @Test func theHeadlineNamesTheTightestWindowOfEveryAgent() throws {
        let headline = try #require(OverviewSummary.headline(limits: limits))
        // Codex's week at 95% is tighter than Claude's 5-hour 62% and Kiro's plan at 31%.
        #expect(headline.agent == .codex)
        #expect(headline.standing.kind == .weekly)
        // Then another agent's tightest limit, with when it frees up: Claude's 5-hour window.
        #expect(headline.other?.agent == .claudeCode)
        #expect(headline.other?.standing.kind == .fiveHour)
        #expect(headline.other?.standing.resetsAt == now + 2 * 3600)
        // One agent alone has nothing to compare with; no limits at all make no headline.
        let alone = try #require(OverviewSummary.headline(limits: [.kiro: limits[.kiro]!]))
        #expect(alone.agent == .kiro && alone.other == nil)
        #expect(OverviewSummary.headline(limits: [:]) == nil)
    }

    @Test func aTieGoesToTheFirstAgentAndItsFirstWindow() throws {
        let resets = now + 3600
        let even: [Agent: AgentLimits] = [
            .codex: AgentLimits(fiveHour: report(.fiveHour, used: 50, resets: resets), weekly: nil, monthly: nil),
            .claudeCode: AgentLimits(
                fiveHour: report(.fiveHour, used: 50, resets: resets), weekly: report(.weekly, used: 50, resets: resets),
                monthly: nil
            ),
        ]
        let headline = try #require(OverviewSummary.headline(limits: even))
        #expect(headline.agent == .claudeCode)
        #expect(headline.standing.kind == .fiveHour)
        #expect(OverviewSummary.tightestStanding(even[.claudeCode]!)?.kind == .fiveHour)
    }

    // MARK: - One agent on its own

    @Test func eachAgentHasItsOwnPeriod() throws {
        let usage = today()
        #expect(Set(usage.byAgent.keys) == [.claudeCode, .codex, .kiro])
        let claude = try #require(usage.byAgent[.claudeCode])
        // Only Claude's turns: its two pieces of work, and none of Codex's or Kiro's time.
        #expect(claude.agents.map(\.agent) == [.claudeCode])
        #expect(claude.workingTime == 30 * 60)
        #expect(claude.byWork.map(\.tag) == [app, site])
        let minutes: [TimeInterval] = [20 * 60, 10 * 60]
        #expect(claude.byWork.map(\.workingTime) == minutes)
        // The whole period's totals are the agents' added up.
        let perAgent = usage.byAgent.values.reduce(0) { $0 + $1.workingTime }
        #expect(perAgent == usage.workingTime)
    }

    @Test func anAgentsRowCountsItsSessionsRepliesAndToolCalls() throws {
        let usage = today()
        let claude = try #require(usage.usage(of: .claudeCode))
        #expect(claude.sessionCount == 2)
        #expect(claude.turnCount == 8)
        // None of these replies says how many tools it called: unknown, not zero.
        #expect(claude.toolCalls == nil)
        let withTools = PeriodUsageBuilder.make(
            .today,
            turns: [
                Turn(id: "a", timestamp: now - 60, agent: .cursor, sessionID: "s", model: "Auto", work: Work(tag: app),
                     tokens: nil, cost: Cost(usd: nil), context: nil, toolCalls: 4),
                Turn(id: "b", timestamp: now - 30, agent: .cursor, sessionID: "s", model: "Auto", work: Work(tag: app),
                     tokens: nil, cost: Cost(usd: nil), context: nil, toolCalls: 3),
            ],
            start: today, bucketStarts: [], openAgents: []
        )
        let cursor = try #require(withTools.usage(of: .cursor))
        #expect(cursor.toolCalls == 7)
        #expect(cursor.tokens == nil)
        #expect(cursor.onlyOpenSessions == false)
    }

    @Test func whereTheTimeWentNamesTheAgentThatSpentMostOfIt() {
        // The app had 20 minutes of Claude, 4 of Codex and 3 of Kiro.
        #expect(today().byWork.map(\.agent) == [.claudeCode, .claudeCode])
    }

    @Test func modelsShareTokensOrTimeWithoutTokens() throws {
        func reply(_ id: String, _ model: ModelName, minutesAgo: Double, tokens: Int?) -> Turn {
            Turn(
                id: id, timestamp: now - minutesAgo * 60, agent: .cursor, sessionID: "s", model: model,
                work: Work(tag: app), tokens: tokens.map { TokenUsage(input: $0, output: 0) }, cost: Cost(usd: nil),
                context: nil
            )
        }
        let byTokens = PeriodUsageBuilder.modelShares([
            reply("1", "a", minutesAgo: 10, tokens: 300), reply("2", "b", minutesAgo: 9, tokens: 100),
        ])
        #expect(byTokens.map(\.model) == ["a", "b"])
        #expect(byTokens.map(\.share) == [0.75, 0.25])
        // No tokens: the share is of the working time. "b" worked 3 minutes of 4.
        let byTime = PeriodUsageBuilder.modelShares([
            reply("1", "a", minutesAgo: 10, tokens: nil), reply("2", "a", minutesAgo: 9, tokens: nil),
            reply("3", "b", minutesAgo: 5, tokens: nil), reply("4", "b", minutesAgo: 2, tokens: nil),
        ])
        #expect(byTime.map(\.model) == ["b", "a"])
        #expect(byTime.map(\.share) == [0.75, 0.25])
    }

    @Test func eachBucketCountsItsWorkingTimeToo() {
        let yesterday = today.addingTimeInterval(-86_400)
        let week = PeriodUsageBuilder.make(
            .week, turns: turns, start: yesterday, bucketStarts: [yesterday, today], openAgents: []
        )
        // Yesterday's one reply has no gap to measure; today has the 37 minutes.
        #expect(week.buckets.map(\.workingTime) == [0, 37 * 60])
    }
}
