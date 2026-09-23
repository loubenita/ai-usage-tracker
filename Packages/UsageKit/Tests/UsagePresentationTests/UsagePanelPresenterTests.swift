import Foundation
import Testing
import UsageData
@testable import UsageDomain
@testable import UsagePresentation

/// The usage panel against the Paper frames 4 to 6: the agent picker, every agent together,
/// and one agent on its own, with nothing an agent does not report shown as 0.
@Suite("The usage panel matches the Paper frames")
struct UsagePanelPresenterTests {
    var calendar: Calendar { OverlayPresenterTests.calendar }
    var presenter: UsagePanelPresenter { UsagePanelPresenter(formatter: UsageFormatter(calendar: calendar)) }

    func all(_ report: UsageReport, _ period: UsagePeriod = .today) throws -> AllAgentsModel {
        guard case .all(let model) = presenter.panel(report, filter: .all, period: period).content else {
            throw Failure.wrongView
        }
        return model
    }

    func agent(_ report: UsageReport, _ agent: Agent, _ period: UsagePeriod) throws -> AgentUsageModel {
        guard case .agent(let model) = presenter.panel(report, filter: .agent(agent), period: period).content else {
            throw Failure.wrongView
        }
        return model
    }

    enum Failure: Error { case wrongView }

    // MARK: - The picker

    @Test func thePickerListsAllThenEachAgentWithData() async throws {
        let panel = presenter.panel(try await OverlayPresenterTests.fakeReport(), filter: .all, period: .today)
        #expect(panel.picker.map(\.name) == ["All", "Claude", "Codex", "Cursor"])
        #expect(panel.picker.map(\.filter) == [.all, .agent(.claudeCode), .agent(.codex), .agent(.cursor)])
        #expect(panel.selected == .all)
    }

    @Test func anAgentThatIsNotInThePickerFallsBackToAll() async throws {
        let panel = presenter.panel(try await OverlayPresenterTests.fakeReport(), filter: .agent(.kiro), period: .week)
        #expect(panel.selected == .all)
        guard case .all = panel.content else { Issue.record("not the All view"); return }
    }

    @Test func pickingAnAgentShowsOnlyThatAgent() async throws {
        let report = try await OverlayPresenterTests.fakeReport()
        let codex = try agent(report, .codex, .today)
        // Codex's own limit, its own work and model, nothing of Claude's.
        #expect(codex.limits.map(\.title) == ["Week limit 95%"])
        #expect(codex.whereRows.map(\.label) == ["OpenKitchen · Bug fixes"])
        #expect(codex.models.map(\.name) == ["gpt-5.6"])
        #expect(codex.stats.first { $0.label == "Tokens" }?.value == "410k")
    }

    // MARK: - Frame 4: every agent, today

    @Test func theAllViewMatchesFrame4() async throws {
        let model = try all(try await OverlayPresenterTests.fakeReport())
        #expect(model.headline
            == "Codex runs out first: 5% of its week is left until Thu 06:57. Claude's 5-hour limit frees up at 16:40.")
        #expect(model.limits.map(\.name) == ["Claude 5-hour", "Claude week", "Codex week", "Cursor"])
        #expect(model.limits.map(\.used) == ["62%", "48%", "95%", ""])
        #expect(model.limits.map(\.freesUp) == ["16:40", "Thu", "Thu", "no data"])
        // 85% or more is amber; an agent that shares no limits has no bar.
        #expect(model.limits.map(\.isNearlyUsed) == [false, false, true, false])
        #expect(model.limits.last?.fraction == nil)
        #expect(model.tableTitle == "TODAY")
    }

    @Test func eachAgentsTotalsAndTheirSum() async throws {
        let model = try all(try await OverlayPresenterTests.fakeReport())
        #expect(model.rows == [
            AgentTableRowModel(agent: .claudeCode, name: "Claude", time: "4h 10m", tokens: "1.2M", spend: "$4.20"),
            AgentTableRowModel(agent: .codex, name: "Codex", time: "1h 20m", tokens: "410k", spend: "$1.35"),
            // Cursor reports neither tokens nor cost: "n/a", not 0.
            AgentTableRowModel(agent: .cursor, name: "Cursor", time: "30m", tokens: nil, spend: nil),
        ])
        // The frame's 5h 55m has Cursor at 25m; the made-up data gives it a prompt every
        // 5 minutes, so 30m.
        #expect(model.total == AgentTableRowModel(agent: nil, name: "All agents", time: "6h 00m", tokens: "1.6M", spend: "$5.55"))
        #expect(model.whereRows.map(\.label)
            == ["MS · Video generation", "MS · Image generation", "OpenKitchen · Bug fixes", "OpenKitchen · iOS"])
        #expect(model.whereRows.map(\.agent) == [.claudeCode, .claudeCode, .codex, .cursor])
        #expect(model.whereRows.map(\.time) == ["2h 38m", "1h 32m", "1h 20m", "30m"])
    }

    @Test func theHeadlineSaysWhenALimitHasRunOut() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let full = LimitReport(
            kind: .fiveHour, usedPercent: 100, resetsAt: now + 3600, readAt: now, percentPerHour: nil, runsOutAt: nil,
            projectedLeftAtReset: nil, calendarDaysLeft: 0
        )
        let headline = presenter.headline(
            [.codex: AgentLimits(fiveHour: full, weekly: nil, monthly: nil)], now: now
        )
        #expect(headline == "Codex has run out of its 5-hour window until 16:13.")
        #expect(presenter.headline([:], now: now) == nil)
    }

    // MARK: - Frame 5: Claude's week

    @Test func claudesWeekMatchesFrame5() async throws {
        let model = try agent(try await OverlayPresenterTests.fakeReport(), .claudeCode, .week)
        #expect(model.note == nil)
        // The week first on Week, then the 5-hour window, each with when it frees up.
        #expect(model.limits.map(\.title) == ["Week limit 48%", "5-hour limit 62%"])
        #expect(model.limits.map(\.detail) == ["frees up Thu 09:00 · in 2d 18h", "frees up 16:40 · in 2h 08m"])
        #expect(model.limits.first?.note == "On pace to end the week at about 90%.")
        #expect(model.stats == [
            StatModel(label: "Spent", value: "$31.40"), StatModel(label: "Tokens", value: "12.2M"),
            StatModel(label: "Time", value: "22h 04m"), StatModel(label: "Sessions", value: "14"),
        ])
        let chart = try #require(model.chart)
        #expect(chart.title == "TOKENS PER DAY")
        #expect(chart.caption == "busiest Thu · 3.1M")
        #expect(chart.bars.map(\.label) == ["Tue", "Wed", "Thu", "Fri", "Sat", "Sun", "Today"])
        #expect(chart.bars.map(\.isBusiest) == [false, false, true, false, false, false, false])
        #expect(chart.bars.last?.isCurrent == true)
        #expect(model.models.map(\.name) == ["Opus 5", "Sonnet 5", "Haiku 4.5"])
    }

    // MARK: - Frame 6: Cursor's month

    @Test func cursorsMonthSaysWhatItDoesNotShareAndShowsItsActivity() async throws {
        let model = try agent(try await OverlayPresenterTests.fakeReport(), .cursor, .month)
        #expect(model.note == NoteModel(
            title: "Cursor",
            text: "Cursor doesn't share tokens, cost or limits on this Mac, so this shows time and activity only."
        ))
        #expect(model.limits.isEmpty)
        #expect(model.stats == [
            StatModel(label: "Time", value: "16h 55m"), StatModel(label: "Sessions", value: "9"),
            StatModel(label: "Prompts", value: "212"), StatModel(label: "Tool calls", value: "1,480"),
        ])
        let chart = try #require(model.chart)
        #expect(chart.title == "HOURS PER WEEK")
        #expect(chart.caption == "September")
        // Weeks from Monday; the first starts on the 1st, the month's own first day.
        #expect(chart.bars.map(\.label) == ["1 Sep · 3h", "7 Sep · 4h", "14 Sep · 10h", "Now · 30m"])
        #expect(chart.bars.map(\.isBusiest) == [false, false, true, false])
        #expect(model.models.map(\.name) == ["Auto", "gpt-5.6"])
        #expect(model.whereRows.map(\.label) == ["OpenKitchen · iOS", "3 more"])
    }

    @Test func anAgentWithOnlyAnOpenSessionIsMeasuredByIt() throws {
        // A Cursor chat open for 40 minutes with 6 prompts and nothing recorded per reply.
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tag = WorkTag(project: "app", concern: "main")
        let records = UsageRecords(
            turns: [], limits: [],
            sessionEvents: [
                SessionEvent(
                    timestamp: start, agent: .cursor, sessionID: "c", kind: .start, state: .working,
                    activeDuration: 0, idleDuration: 0, work: tag
                ),
                SessionEvent(
                    timestamp: start + 2400, agent: .cursor, sessionID: "c", kind: .active, state: .working,
                    activeDuration: 2400, idleDuration: 0, work: tag, snapshot: SessionSnapshot(turnCount: 6)
                ),
            ],
            capturedAt: start + 2400
        )
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let report = GenerateUsageReport(settings: settings, calendar: calendar)(records, now: start + 2400)
        let cursor = try agent(report, .cursor, .today)
        // No tool calls reported: that stat is left out, not shown as 0. Today has no chart.
        #expect(cursor.stats == [
            StatModel(label: "Time", value: "40m"), StatModel(label: "Sessions", value: "1"),
            StatModel(label: "Prompts", value: "6"),
        ])
        #expect(cursor.chart == nil)
        #expect(cursor.models.isEmpty)
        #expect(cursor.whereRows.isEmpty)
        let table = try all(report)
        #expect(table.rows == [AgentTableRowModel(agent: .cursor, name: "Cursor", time: "40m", tokens: nil, spend: nil)])
        // One agent needs no total, and no agent has limits, so there is no headline.
        #expect(table.total == nil)
        #expect(table.headline == nil)
        #expect(table.limits.map(\.freesUp) == ["no data"])
    }

    @Test func claudeWithoutItsStatusLineSaysHowToTurnItsLimitsOn() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tag = WorkTag(project: "app", concern: "main")
        let turn = Turn(
            id: "t", timestamp: start, agent: .claudeCode, sessionID: "a", model: "claude-opus-5", work: Work(tag: tag),
            tokens: TokenUsage(input: 1_000), cost: Cost(usd: 1), context: nil
        )
        let records = UsageRecords(turns: [turn], limits: [], sessionEvents: [], capturedAt: start)
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let report = GenerateUsageReport(settings: settings, calendar: calendar)(records, now: start + 60)
        let claude = try agent(report, .claudeCode, .today)
        #expect(claude.note?.title == "Claude's limits")
        #expect(claude.limits.isEmpty)
    }

    @Test func whereTheTimeWentAddsUpTheRestInOneRow() {
        let tag = { (name: String) in WorkTag(project: "p", concern: name) }
        let work = (0..<5).map { WorkTime(tag: tag("w\($0)"), workingTime: 600, share: 0.2, agent: .codex) }
        let rows = presenter.whereRows(work, limit: 3)
        #expect(rows.map(\.label) == ["p · w0", "p · w1", "3 more"])
        #expect(rows.last?.time == "30m")
        #expect(rows.last?.percent == "60%")
        #expect(rows.last?.agent == nil)
        #expect(presenter.whereRows(Array(work.prefix(3)), limit: 3).count == 3)
    }
}
