import Foundation
import Testing
@testable import UsageDomain

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let tag = WorkTag(project: "app", concern: "main")

private func startEvent(_ agent: Agent, id: String) -> SessionEvent {
    SessionEvent(
        timestamp: start, agent: agent, sessionID: id, kind: .start, state: .working,
        activeDuration: 0, idleDuration: 0, work: tag
    )
}

private func limit(_ agent: Agent, _ kind: LimitWindowKind, _ percent: Double) -> LimitReading {
    LimitReading(
        timestamp: start, agent: agent, plan: nil,
        windows: [LimitWindowReading(kind: kind, usedPercent: percent, resetsAt: start + 3600)]
    )
}

private func report(events: [SessionEvent], limits: [LimitReading]) -> UsageReport {
    let settings = UsageSettings(dailyCostBudget: 9, dailyTokenBudget: 1, workdayEndHour: 20)
    let records = UsageRecords(turns: [], limits: limits, sessionEvents: events, capturedAt: start)
    return GenerateUsageReport(settings: settings, calendar: Calendar(identifier: .gregorian))(records, now: start + 60)
}

@Suite("Agents that report a whole session, not each reply")
struct SessionSnapshotTests {
    @Test func theSnapshotGivesContextModelAndTurns() throws {
        let snapshot = SessionSnapshot(model: "grok-4.6", context: ContextUsage(used: 140_454, window: 256_000), turnCount: 9)
        let status = SessionEvent(
            timestamp: start + 30, agent: .cursor, sessionID: "c", kind: .idle, state: .waiting,
            activeDuration: 30, idleDuration: 0, work: tag, snapshot: snapshot
        )
        let summary = try #require(
            SessionSummaries.make(turns: [], events: [startEvent(.cursor, id: "c"), status], now: start + 60).first
        )
        #expect(summary.model == "grok-4.6")
        #expect(summary.context == ContextUsage(used: 140_454, window: 256_000))
        #expect(summary.turnCount == 9)
        #expect(summary.tokens == nil)
        #expect(summary.costUSD == nil)
    }

    @Test func repliesWinOverTheSnapshot() throws {
        let turn = Turn(
            id: "t", timestamp: start + 10, agent: .kiro, sessionID: "k", model: "claude-sonnet-4.5",
            work: Work(tag: tag), tokens: nil, cost: Cost(usd: nil), context: ContextUsage(used: 10, window: 100)
        )
        let status = SessionEvent(
            timestamp: start + 30, agent: .kiro, sessionID: "k", kind: .active, state: .working,
            activeDuration: 30, idleDuration: 0, work: tag,
            snapshot: SessionSnapshot(model: "auto", context: ContextUsage(used: 50, window: 100), turnCount: 4)
        )
        let summary = try #require(
            SessionSummaries.make(turns: [turn], events: [startEvent(.kiro, id: "k"), status], now: start + 60).first
        )
        #expect(summary.model == "claude-sonnet-4.5")
        #expect(summary.context == ContextUsage(used: 10, window: 100))
        #expect(summary.turnCount == 1)
    }
}

@Suite("Each agent's own limits")
struct AgentLimitsTests {
    @Test func limitsAreKeptApartByAgent() {
        let report = report(
            events: [startEvent(.claudeCode, id: "a")],
            limits: [limit(.claudeCode, .fiveHour, 62), limit(.codex, .weekly, 87)]
        )
        #expect(report.limits(for: .claudeCode).fiveHour?.usedPercent == 62)
        #expect(report.limits(for: .claudeCode).weekly == nil)
        #expect(report.limits(for: .codex).weekly?.usedPercent == 87)
        #expect(report.limits(for: .codex).fiveHour == nil)
        #expect(report.limits(for: .cursor).isEmpty)
    }

    @Test func theStripShowsTheAgentWithTheMostOpenSessions() {
        let limits = [limit(.claudeCode, .fiveHour, 62), limit(.codex, .fiveHour, 20)]
        let codexHeavy = report(
            events: [startEvent(.claudeCode, id: "a"), startEvent(.codex, id: "b"), startEvent(.codex, id: "c")],
            limits: limits
        )
        #expect(codexHeavy.stripAgent == .codex)
        #expect(codexHeavy.fiveHour?.usedPercent == 20)
    }

    @Test func aTieGoesToTheAgentListedFirst() {
        let limits = [limit(.codex, .fiveHour, 20), limit(.claudeCode, .fiveHour, 62)]
        let tie = report(events: [startEvent(.codex, id: "b"), startEvent(.claudeCode, id: "a")], limits: limits)
        #expect(tie.stripAgent == .claudeCode)
        #expect(report(events: [], limits: limits).stripAgent == .claudeCode)
    }

    @Test func anAgentWithoutLimitsIsNeverChosen() {
        let report = report(
            events: [startEvent(.cursor, id: "x"), startEvent(.cursor, id: "y"), startEvent(.codex, id: "b")],
            limits: [limit(.codex, .weekly, 87)]
        )
        #expect(report.stripAgent == .codex)
        #expect(report.fiveHour == nil)
        #expect(report.weekly?.usedPercent == 87)
    }

    @Test func creditsAreKirosLimitButNeverTheStrips() {
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let records = UsageRecords(
            turns: [], limits: [limit(.codex, .weekly, 87)],
            sessionEvents: [startEvent(.kiro, id: "k"), startEvent(.kiro, id: "l")],
            capturedAt: start, creditsThisMonth: [.kiro: 12.5]
        )
        let report = GenerateUsageReport(settings: settings, calendar: Calendar(identifier: .gregorian))(records, now: start + 60)
        #expect(report.limits(for: .kiro).creditsUsedThisMonth == 12.5)
        #expect(report.limits(for: .kiro).hasWindows == false)
        // Kiro has more open sessions, but the strip shows a percentage, which only Codex has.
        #expect(report.stripAgent == .codex)
    }

    @Test func aWindowThatHasResetIsNotShown() {
        // The window reset at start + 3600; an hour and a minute later it says nothing.
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let records = UsageRecords(
            turns: [], limits: [limit(.codex, .fiveHour, 40)], sessionEvents: [], capturedAt: start
        )
        let generate = GenerateUsageReport(settings: settings, calendar: Calendar(identifier: .gregorian))
        #expect(generate(records, now: start + 3000).limits(for: .codex).fiveHour?.usedPercent == 40)
        #expect(generate(records, now: start + 3660).limits(for: .codex).isEmpty)
        #expect(generate(records, now: start + 3660).stripAgent == nil)
    }

    @Test func aSessionsShareOfTheFiveHourLimitUsesItsOwnAgent() throws {
        // Two Claude readings an hour apart give Claude a pace; Codex has none, so a Codex
        // session never borrows Claude's.
        let later = LimitReading(
            timestamp: start + 3600, agent: .claudeCode, plan: nil,
            windows: [LimitWindowReading(kind: .fiveHour, usedPercent: 72, resetsAt: start + 3600)]
        )
        let events = [startEvent(.claudeCode, id: "a"), startEvent(.codex, id: "b")]
        let settings = UsageSettings(dailyCostBudget: 9, dailyTokenBudget: 1, workdayEndHour: 20)
        let records = UsageRecords(
            turns: [], limits: [limit(.claudeCode, .fiveHour, 62), later], sessionEvents: events, capturedAt: start
        )
        let report = GenerateUsageReport(settings: settings, calendar: Calendar(identifier: .gregorian))(
            records, now: start + 1800
        )
        #expect(report.sessions.first { $0.id == "a" }?.shareOfFiveHourLimit != nil)
        #expect(report.sessions.first { $0.id == "b" }?.shareOfFiveHourLimit == nil)
    }
}
