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

    func usageReport(now: Date, turns: [Turn]) -> UsageReport {
        GenerateUsageReport(
            settings: UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20),
            calendar: calendar
        )(UsageRecords(turns: turns, limits: [], sessionEvents: [], capturedAt: now), now: now)
    }

    func usageTurn(
        _ id: String,
        at timestamp: Date,
        session: String,
        model: ModelName,
        tokens: Int,
        cost: Decimal,
        tag: WorkTag
    ) -> Turn {
        Turn(
            id: id,
            timestamp: timestamp,
            agent: .claudeCode,
            sessionID: session,
            model: model,
            work: Work(tag: tag),
            tokens: TokenUsage(input: tokens),
            cost: Cost(usd: cost),
            context: nil
        )
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
        // Today has no Codex 5-hour reading, so its weekly limit stays in Week.
        #expect(codex.limits.isEmpty)
        #expect(codex.whereRows.map(\.label) == ["OpenKitchen · Bug fixes"])
        #expect(codex.models.map(\.name) == ["gpt-5.6"])
        #expect(codex.stats.first { $0.label == "Tokens" }?.value == "410k")
    }

    @Test func todayExcludesWeeklyLimitsWhileWeekIncludesThem() async throws {
        let report = try await OverlayPresenterTests.fakeReport()

        let today = try all(report, .today)
        #expect(today.limits.map(\.name) == ["Claude 5-hour", "Cursor"])
        #expect(today.headline == "Claude runs out first: 38% of its 5-hour window is left until 16:40.")
        #expect(try agent(report, .claudeCode, .today).limits.map(\.title) == ["5-hour limit 62%"])
        #expect(try agent(report, .codex, .today).limits.isEmpty)

        let week = try all(report, .week)
        #expect(week.limits.map(\.name) == ["Claude 5-hour", "Claude week", "Codex week", "Cursor"])
        #expect(try agent(report, .claudeCode, .week).limits.map(\.title) == ["Week limit 48%", "5-hour limit 62%"])
    }

    @Test func twoClaudeAccountsShowOnlyCurrentPercentagesAndTruthfulResetAvailability() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshots = [
            AccountUsageSnapshot(
                id: "/profiles/work", name: "Work", agent: .claudeCode, readAt: now,
                fiveHourPercent: 20, weeklyPercent: 40
            ),
            AccountUsageSnapshot(
                id: "/profiles/personal", name: "Personal", agent: .claudeCode,
                readAt: now - 3600, fiveHourPercent: 80, weeklyPercent: 90
            )
        ]
        let records = UsageRecords(
            turns: [], limits: [], sessionEvents: [], capturedAt: now, accountSnapshots: snapshots
        )
        let report = GenerateUsageReport(
            settings: UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20),
            calendar: calendar
        )(records, now: now)
        let overview = try all(report)
        #expect(overview.limits.count == 2)
        #expect(overview.limits.map(\.name).contains("Claude · Personal"))
        #expect(overview.limits.first { $0.name == "Claude · Personal" }?.freesUp == "no current data")
        #expect(overview.limits.first { $0.name == "Claude · Work 5-hour" }?.used == "20%")
        #expect(overview.limits.first { $0.name == "Claude · Work 5-hour" }?.freesUp == "Reset time unavailable")
        let claude = try agent(report, .claudeCode, .today)
        #expect(claude.limits.map(\.title) == ["Work · 5-hour limit 20%"])
        #expect(claude.limits.first?.detail == "Reset time unavailable")

        let week = try all(report, .week)
        #expect(week.limits.first { $0.name == "Claude · Work week" }?.used == "40%")
        #expect(week.limits.first { $0.name == "Claude · Work week" }?.freesUp == "Reset time unavailable")
    }

    @Test func staleSnapshotAtAResetDoesNotClaimTheOldPercentage() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = AccountUsageSnapshot(
            id: "/profiles/personal", name: "Personal", agent: .claudeCode,
            readAt: now - 27 * 60, fiveHourPercent: 100, weeklyPercent: 100
        )
        let records = UsageRecords(
            turns: [], limits: [], sessionEvents: [], capturedAt: now, accountSnapshots: [snapshot]
        )
        let report = GenerateUsageReport(
            settings: UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20),
            calendar: calendar
        )(records, now: now)

        let today = try all(report)
        #expect(today.limits == [
            LimitListRowModel(
                id: "claude-code-/profiles/personal-none", agent: .claudeCode, name: "Claude · Personal",
                fraction: nil, used: "", freesUp: "no current data", isNearlyUsed: false
            )
        ])
        #expect(try agent(report, .claudeCode, .today).limits.isEmpty)
    }

    // MARK: - Frame 4: every agent, today

    @Test func theAllViewMatchesFrame4() async throws {
        let model = try all(try await OverlayPresenterTests.fakeReport())
        #expect(model.headline == "Claude runs out first: 38% of its 5-hour window is left until 16:40.")
        #expect(model.limits.map(\.name) == ["Claude 5-hour", "Cursor"])
        #expect(model.limits.map(\.used) == ["62%", ""])
        #expect(model.limits.map(\.freesUp) == ["16:40", "no data"])
        // 85% or more is amber; an agent that shares no limits has no bar.
        #expect(model.limits.map(\.isNearlyUsed) == [false, false])
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
        let chart = try #require(model.chart)
        #expect(chart.title == "TOKENS PER DAY")
        #expect(chart.caption == "busiest Thu · 3.1M")
        #expect(chart.bars.map(\.label) == ["Tue", "Wed", "Thu", "Fri", "Sat", "Sun", "Today"])
        #expect(chart.bars.map(\.isBusiest) == [false, false, true, false, false, false, false])
        #expect(chart.bars.last?.isCurrent == true)
        #expect(chart.bars.last?.isSelected == true)
    }

    @Test func selectingAWeekDayShowsThatDaysSpendModelsAndWorkWhileAllStaysWeekly() throws {
        let now = Date(timeIntervalSince1970: 1_790_085_600)
        let startOfToday = calendar.startOfDay(for: now)
        let selectedDay = calendar.date(byAdding: .day, value: -2, to: startOfToday)!
        let selectedTag = WorkTag(project: "Demo", concern: "Selected")
        let currentTag = WorkTag(project: "Demo", concern: "Current")
        let report = usageReport(now: now, turns: [
            usageTurn("selected-1", at: selectedDay + 9 * 3600, session: "selected", model: "claude-opus-5", tokens: 300, cost: 2, tag: selectedTag),
            usageTurn("selected-2", at: selectedDay + 9 * 3600 + 5 * 60, session: "selected", model: "claude-opus-5", tokens: 400, cost: 4, tag: selectedTag),
            usageTurn("current-1", at: startOfToday + 9 * 3600, session: "current", model: "claude-sonnet-5", tokens: 200, cost: 1, tag: currentTag),
            usageTurn("current-2", at: startOfToday + 10 * 3600, session: "current", model: "claude-sonnet-5", tokens: 300, cost: 4, tag: currentTag),
        ])
        let selectedPanel = presenter.panel(
            report, filter: .agent(.claudeCode), period: .week, selectedBucketStart: selectedDay
        )
        let selectedAgent = try #require({
            if case .agent(let model) = selectedPanel.content { return model }
            return nil
        }())
        #expect(selectedPanel.selectedBucketStart == selectedDay)
        #expect(selectedAgent.chart?.bars.filter(\.isSelected).map(\.start) == [selectedDay])
        #expect(selectedAgent.stats == [
            StatModel(label: "Spent", value: "$6.00"), StatModel(label: "Tokens", value: "700"),
            StatModel(label: "Time", value: "5m"), StatModel(label: "Sessions", value: "1"),
        ])
        #expect(selectedAgent.models == [ModelShareRowModel(name: "Opus 5", percent: "100%")])
        #expect(selectedAgent.whereRows == [
            TimeRowModel(id: "Demo/Selected", agent: .claudeCode, label: "Demo · Selected", percent: "100%", time: "5m")
        ])

        let all = try all(report, .week)
        #expect(all.tableTitle == "THIS WEEK")
        #expect(all.rows.first { $0.agent == .claudeCode }?.tokens == "1k")
        #expect(all.rows.first { $0.agent == .claudeCode }?.spend == "$11.00")
    }

    // MARK: - Frame 6: Cursor's month

    @Test func cursorsMonthSaysWhatItDoesNotShareAndShowsItsActivity() async throws {
        let model = try agent(try await OverlayPresenterTests.fakeReport(), .cursor, .month)
        #expect(model.note == NoteModel(
            title: "Cursor",
            text: "Cursor doesn't share tokens, cost or limits on this Mac, so this shows time and activity only."
        ))
        #expect(model.limits.isEmpty)
        let chart = try #require(model.chart)
        #expect(chart.title == "HOURS PER WEEK")
        #expect(chart.caption == "September")
        // Weeks from Monday; the first starts on the 1st, the month's own first day.
        #expect(chart.bars.map(\.label) == ["1 Sep · 3h", "7 Sep · 4h", "14 Sep · 10h", "Now · 30m"])
        #expect(chart.bars.map(\.isBusiest) == [false, false, true, false])
        #expect(chart.bars.last?.isSelected == true)
    }

    @Test func selectingAMonthWeekShowsThatWeeksConcreteDetailAndEmptyBucketsStayEmpty() throws {
        let now = Date(timeIntervalSince1970: 1_790_085_600)
        let startOfToday = calendar.startOfDay(for: now)
        let selectedWeekDay = calendar.date(byAdding: .day, value: -8, to: startOfToday)!
        let selectedTag = WorkTag(project: "Demo", concern: "Week")
        let report = usageReport(now: now, turns: [
            usageTurn("week-1", at: selectedWeekDay + 9 * 3600, session: "week", model: "claude-opus-5", tokens: 250, cost: 2, tag: selectedTag),
            usageTurn("week-2", at: selectedWeekDay + 9 * 3600 + 5 * 60, session: "week", model: "claude-opus-5", tokens: 350, cost: 3, tag: selectedTag),
        ])
        let selectedWeek = try #require(report.periods[.month]?.buckets.first { $0.tokens == 600 }?.start)
        let panel = presenter.panel(report, filter: .agent(.claudeCode), period: .month, selectedBucketStart: selectedWeek)
        let agent = try #require({
            if case .agent(let model) = panel.content { return model }
            return nil
        }())
        #expect(panel.selectedBucketStart == selectedWeek)
        #expect(agent.stats == [
            StatModel(label: "Spent", value: "$5.00"), StatModel(label: "Tokens", value: "600"),
            StatModel(label: "Time", value: "5m"), StatModel(label: "Sessions", value: "1"),
        ])
        #expect(agent.models == [ModelShareRowModel(name: "Opus 5", percent: "100%")])
        #expect(agent.whereRows == [
            TimeRowModel(id: "Demo/Week", agent: .claudeCode, label: "Demo · Week", percent: "100%", time: "5m")
        ])

        let emptyWeek = try #require(report.periods[.month]?.buckets.first { $0.tokens == 0 }?.start)
        let emptyPanel = presenter.panel(report, filter: .agent(.claudeCode), period: .month, selectedBucketStart: emptyWeek)
        let empty = try #require({
            if case .agent(let model) = emptyPanel.content { return model }
            return nil
        }())
        #expect(empty.stats.isEmpty)
        #expect(empty.models.isEmpty)
        #expect(empty.whereRows.isEmpty)
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
