import Foundation
import Testing
@testable import UsageDomain

/// Kiro bills in credits, not dollars, and its Auto agent reports no tokens. These check that
/// credits are counted per session, per day, per model and for the month, and that the plan the
/// account reports joins Kiro's limits.
@Suite("Credits, the month, and the plan")
struct CreditsAndMonthTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Tuesday 22 September 2026, 14:00 UTC; the 1st of September is 21 days before the 22nd.
    let now = Date(timeIntervalSince1970: 1_790_085_600)
    let september1 = Date(timeIntervalSince1970: 1_788_220_800)
    let tag = WorkTag(project: "shop", concern: "main")

    func kiroTurn(_ id: String, _ at: Date, credits: Double?, session: String = "k") -> Turn {
        Turn(
            id: id, timestamp: at, agent: .kiro, sessionID: session, model: "auto", work: Work(tag: tag),
            tokens: nil, cost: Cost(usd: nil), context: nil, credits: credits
        )
    }

    func report(_ turns: [Turn], plans: [Agent: PlanUsage] = [:], at now: Date? = nil) -> UsageReport {
        let now = now ?? self.now
        let start = SessionEvent(
            timestamp: now - 3600, agent: .kiro, sessionID: "k", kind: .start, state: .working,
            activeDuration: 0, idleDuration: 0, work: tag
        )
        let claude = Turn(
            id: "c", timestamp: now - 60, agent: .claudeCode, sessionID: "c", model: "claude-opus-5",
            work: Work(tag: tag), tokens: TokenUsage(input: 1_000, output: 500), cost: Cost(usd: 1), context: nil
        )
        let records = UsageRecords(
            turns: turns + [claude], limits: [], sessionEvents: [start], capturedAt: now, plans: plans
        )
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        return GenerateUsageReport(settings: settings, calendar: calendar)(records, now: now)
    }

    var turns: [Turn] {
        [
            kiroTurn("today-1", now - 7200, credits: 0.5),
            kiroTurn("today-2", now - 600, credits: 0.25),
            // A request whose credits Kiro did not report counts as none, not zero.
            kiroTurn("today-3", now - 300, credits: nil),
            kiroTurn("3rd", september1 + 2 * 86_400 + 3600, credits: 1.0, session: "old"),
            kiroTurn("august", september1 - 86_400, credits: 9.0, session: "old"),
        ]
    }

    @Test func theSecondsReportReusesTheTotalsAndReadsOnlyTheOpenSessions() throws {
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let generate = GenerateUsageReport(settings: settings, calendar: calendar)
        let whole = report(turns)
        let start = SessionEvent(
            timestamp: now - 3600, agent: .kiro, sessionID: "k", kind: .start, state: .working,
            activeDuration: 0, idleDuration: 0, work: tag
        )
        let all = UsageRecords(turns: turns, limits: [], sessionEvents: [start], capturedAt: now)
        let totals = generate.totals(all, now: now)
        // The open session's own turns only, as the quick read gives them: no history.
        let open = UsageRecords(
            turns: turns.filter { $0.sessionID == "k" }, limits: [], sessionEvents: [start], capturedAt: now
        )
        let quick = generate.report(sessions: open, totals: totals, now: now + 30)
        #expect(quick.month == totals.month)
        #expect(quick.today == totals.today)
        #expect(quick.sessions.first?.summary.credits == whole.sessions.first { $0.id == "k" }?.summary.credits)
        // Thirty seconds on, the timer has moved though the totals were not rebuilt.
        let later = try #require(quick.sessions.first?.summary.activeDuration)
        let earlier = try #require(generate.report(sessions: open, totals: totals, now: now).sessions.first?.summary.activeDuration)
        #expect(later - earlier == 30)
        // Building it all at once gives the same as the two halves.
        #expect(generate(all, now: now) == generate.report(sessions: all, totals: totals, now: now))
    }

    @Test func aSessionCountsItsOwnCredits() throws {
        let session = try #require(report(turns).sessions.first { $0.id == "k" })
        #expect(session.summary.credits == 0.75)
    }

    @Test func theMonthRunsFromTheFirstToTodayWithCreditsPerDay() {
        let month = report(turns).month
        #expect(month.start == september1)
        #expect(month.days.count == 22)
        #expect(month.days.first?.day == september1)
        #expect(month.days[2].credits == 1.0)
        #expect(month.days.last?.credits == 0.75)
        // August's 9 credits are last month's.
        #expect(month.credits == 1.75)
        #expect(month.totalTokens == 1_500)
    }

    @Test func todayAndTheWeekCountCreditsToo() {
        let report = report(turns)
        #expect(report.limits(for: .kiro).creditsUsedToday == 0.75)
        // The week starts on the 16th, so the 3rd is not in it.
        #expect(report.week.credits == 0.75)
        #expect(report.week.days.last?.credits == 0.75)
        #expect(report.limits(for: .claudeCode).creditsUsedToday == nil)
    }

    @Test func aModelWithCreditsButNoTokensIsListed() throws {
        let models = report(turns).month.byModel
        #expect(models.map(\.model.id) == ["claude-opus-5", "auto"])
        let auto = try #require(models.last)
        #expect(auto.tokens == 0)
        #expect(auto.credits == 1.75)
    }

    @Test func thePlanJoinsKirosLimitsUntilItResets() throws {
        let october1 = Date(timeIntervalSince1970: 1_790_812_800)
        let plan = PlanUsage(
            name: "KIRO POWER", creditsUsed: 2_100, creditsLimit: 5_000, usedPercent: 42, resetsAt: october1,
            readAt: now - 60
        )
        let limits = report(turns, plans: [.kiro: plan]).limits(for: .kiro)
        #expect(limits.plan == plan)
        #expect(abs((limits.creditsPerDayLeft ?? 0) - 2_900.0 / 9) < 1e-9)
        // 2,900 left over the 9 days from the 22nd to the 30th.
        let perDay = try #require(plan.creditsPerDayLeft(now: now, calendar: calendar))
        #expect(abs(perDay - 2_900.0 / 9) < 1e-9)
        #expect(plan.creditsLeft == 2_900)
        // Read before a reset that has since passed, it says nothing about the new month.
        #expect(report([], plans: [.kiro: plan], at: october1 + 60).limits(for: .kiro).plan == nil)
        // A plan with only a percentage has no credits left to spread.
        let percentOnly = PlanUsage(name: nil, creditsUsed: nil, creditsLimit: nil, usedPercent: 42, resetsAt: october1, readAt: now)
        #expect(percentOnly.creditsPerDayLeft(now: now, calendar: calendar) == nil)
    }

    @Test func theRecordsReachBackToTheFirstOfTheMonthOrAWeekIfLonger() {
        let generate = GenerateUsageReport(
            settings: UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20), calendar: calendar
        )
        #expect(generate.recordRange(endingAt: now).start == september1)
        // On 3 October the week reaches further back than the month.
        let october3 = Date(timeIntervalSince1970: 1_790_985_600 + 3600)
        #expect(generate.recordRange(endingAt: october3).start == Date(timeIntervalSince1970: 1_790_467_200))
    }
}
