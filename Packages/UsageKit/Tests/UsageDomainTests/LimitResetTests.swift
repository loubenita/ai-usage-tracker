import Foundation
import Testing
@testable import UsageDomain

/// A limit window whose reset has passed is not dropped: its last reading stays as a reset
/// window, which says the window is over and is never counted as usage.
@Suite("Limits that have reset")
struct LimitResetTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let tag = WorkTag(project: "app", concern: "main")
    let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
    var calendar: Calendar { Calendar(identifier: .gregorian) }

    func reading(
        _ agent: Agent, _ kind: LimitWindowKind, _ percent: Double, readAt: Date, resetsAt: Date,
        account: (id: String, name: String)? = nil
    ) -> LimitReading {
        LimitReading(
            timestamp: readAt, agent: agent, plan: nil,
            windows: [LimitWindowReading(kind: kind, usedPercent: percent, resetsAt: resetsAt)],
            accountID: account?.id, accountName: account?.name
        )
    }

    func usage(
        limits: [LimitReading] = [], plans: [Agent: PlanUsage] = [:], events: [SessionEvent] = [], now: Date
    ) -> UsageReport {
        let records = UsageRecords(
            turns: [], limits: limits, sessionEvents: events, capturedAt: now, plans: plans
        )
        return GenerateUsageReport(settings: settings, calendar: calendar)(records, now: now)
    }

    // MARK: - Which readings are kept

    @Test func aWindowThatHasResetKeepsItsLastReading() {
        let readings = [reading(.codex, .weekly, 95, readAt: start, resetsAt: start + 3600)]
        #expect(ResetWindow.lastSeen(in: readings, now: start + 3000) == [])
        #expect(ResetWindow.lastSeen(in: readings, now: start + 3600) == [
            ResetWindow(kind: .weekly, resetsAt: start + 3600, readAt: start),
        ])
    }

    @Test func onlyTheLatestReadingOfAKindIsKept() {
        let readings = [
            reading(.codex, .weekly, 20, readAt: start - 7 * 86_400, resetsAt: start - 86_400),
            reading(.codex, .weekly, 40, readAt: start - 3600, resetsAt: start + 600),
            reading(.codex, .weekly, 90, readAt: start - 1800, resetsAt: start + 600),
        ]
        #expect(ResetWindow.lastSeen(in: readings, now: start + 3600) == [
            ResetWindow(kind: .weekly, resetsAt: start + 600, readAt: start - 1800),
        ])
    }

    @Test func aKindWithAWindowStillRunningHasNoResetWindow() {
        let readings = [
            reading(.codex, .weekly, 20, readAt: start - 7 * 86_400, resetsAt: start - 3600),
            reading(.codex, .weekly, 5, readAt: start, resetsAt: start + 7 * 86_400),
        ]
        #expect(ResetWindow.lastSeen(in: readings, now: start + 60) == [])
    }

    @Test func eachKindIsJudgedOnItsOwn() {
        let readings = [
            reading(.claudeCode, .fiveHour, 62, readAt: start, resetsAt: start + 3600),
            reading(.claudeCode, .weekly, 48, readAt: start, resetsAt: start + 3 * 86_400),
        ]
        #expect(ResetWindow.lastSeen(in: readings, now: start + 7200) == [
            ResetWindow(kind: .fiveHour, resetsAt: start + 3600, readAt: start),
        ])
    }

    @Test func aPlanThatHasResetKeepsItsLastReading() {
        let plan = PlanUsage(
            name: "KIRO POWER", creditsUsed: 2_100, creditsLimit: 5_000, usedPercent: 42,
            resetsAt: start + 3600, readAt: start
        )
        #expect(ResetWindow.lastSeen(plan: plan, now: start + 3000) == nil)
        #expect(ResetWindow.lastSeen(plan: plan, now: start + 3600)
            == ResetWindow(kind: .plan, resetsAt: start + 3600, readAt: start))
        // A plan that does not say when it resets has not reset.
        let open = PlanUsage(
            name: nil, creditsUsed: nil, creditsLimit: nil, usedPercent: 42, resetsAt: nil, readAt: start
        )
        #expect(ResetWindow.lastSeen(plan: open, now: start + 86_400 * 90) == nil)
        #expect(ResetWindow.lastSeen(plan: nil, now: start) == nil)
    }

    // MARK: - In the report

    @Test func theReportKeepsTheResetWindowBesideLimitsThatAreStillRunning() {
        let limits = [
            reading(.codex, .fiveHour, 40, readAt: start, resetsAt: start + 3600),
            reading(.codex, .weekly, 95, readAt: start, resetsAt: start + 3 * 86_400),
        ]
        let codex = usage(limits: limits, now: start + 7200).limits(for: .codex)
        #expect(codex.fiveHour == nil)
        #expect(codex.weekly?.usedPercent == 95)
        #expect(codex.resetWindows == [ResetWindow(kind: .fiveHour, resetsAt: start + 3600, readAt: start)])
        #expect(!codex.isEmpty)
    }

    @Test func aResetWindowIsNotUsageAnywhereElse() {
        let limits = [
            reading(.codex, .weekly, 95, readAt: start - 3600, resetsAt: start - 60),
            reading(.claudeCode, .fiveHour, 30, readAt: start, resetsAt: start + 3600),
        ]
        let report = usage(limits: limits, events: [startEvent(.codex), startEvent(.codex, id: "b")], now: start)
        let codex = report.limits(for: .codex)
        #expect(codex.resetWindows.count == 1)
        // Nothing that reads limits sees it: not a live window, a standing, a headline or a forecast.
        #expect(!codex.hasWindows)
        #expect(codex.standings.isEmpty)
        #expect(OverviewSummary.tightestStanding(codex) == nil)
        #expect(codex.headline(for: .week) == nil)
        #expect(codex.weeklyUsedToday == nil && codex.weeklyUsedByDay == nil && codex.weeklyAllowancePerDay == nil)
        let headline = OverviewSummary.headline(limits: report.limitsByAgent)
        #expect(headline?.agent == .claudeCode)
        #expect(headline?.other == nil)
        // Codex has the most open sessions, but the strip only chooses an agent with a live window.
        #expect(report.stripAgent == .claudeCode)
        #expect(report.fiveHour?.usedPercent == 30)
    }

    @Test func anAgentWithOnlyAResetWindowStillHasLimitsToShow() {
        let limits = [reading(.codex, .weekly, 95, readAt: start - 3600, resetsAt: start - 60)]
        let report = usage(limits: limits, now: start)
        #expect(report.limitsByAgent.keys.contains(.codex))
        #expect(report.stripAgent == nil)
        #expect(OverviewSummary.headline(limits: report.limitsByAgent) == nil)
    }

    @Test func eachAccountKeepsItsOwnResetWindow() {
        let work = (id: "/profiles/work", name: "Work")
        let limits = [
            reading(.claudeCode, .weekly, 100, readAt: start - 86_400, resetsAt: start - 60, account: work),
            reading(.claudeCode, .fiveHour, 20, readAt: start, resetsAt: start + 3600),
        ]
        let report = usage(limits: limits, now: start)
        let account = report.accounts.first { $0.id == work.id }
        #expect(account?.limits.resetWindows == [
            ResetWindow(kind: .weekly, resetsAt: start - 60, readAt: start - 86_400),
        ])
        #expect(account?.limits.hasWindows == false)
        // The agent's own limits are the readings no account made, and a reset one changes none of them.
        #expect(report.limits(for: .claudeCode).resetWindows.isEmpty)
        #expect(report.limits(for: .claudeCode).fiveHour?.usedPercent == 20)
    }

    @Test func aPlanThatHasResetShowsAsAResetWindowNotAPlan() {
        let plan = PlanUsage(
            name: "KIRO POWER", creditsUsed: 2_100, creditsLimit: 5_000, usedPercent: 42,
            resetsAt: start + 3600, readAt: start
        )
        let before = usage(plans: [.kiro: plan], now: start + 60).limits(for: .kiro)
        #expect(before.plan == plan)
        #expect(before.resetWindows.isEmpty)
        let after = usage(plans: [.kiro: plan], now: start + 3660).limits(for: .kiro)
        #expect(after.plan == nil)
        #expect(after.standings.isEmpty)
        #expect(after.creditsPerDayLeft == nil)
        #expect(after.resetWindows == [ResetWindow(kind: .plan, resetsAt: start + 3600, readAt: start)])
    }

    func startEvent(_ agent: Agent, id: String = "a") -> SessionEvent {
        SessionEvent(
            timestamp: start, agent: agent, sessionID: id, kind: .start, state: .working,
            activeDuration: 0, idleDuration: 0, work: tag
        )
    }
}
