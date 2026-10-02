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

    /// The made-up month before any Claude account saved a cache, so that Claude's own 62% and
    /// 48% are the limits the panels show for Claude.
    static func fakeReportWithoutAccounts() async throws -> UsageReport {
        let calendar = OverlayPresenterTests.calendar
        let repository = FakeUsageRepository(calendar: calendar)
        let generate = GenerateUsageReport(settings: try await repository.settings(), calendar: calendar)
        let range = generate.recordRange(endingAt: repository.anchor)
        let all = try await repository.records(from: range.start, to: range.end)
        let records = UsageRecords(
            turns: all.turns, limits: all.limits, sessionEvents: all.sessionEvents, capturedAt: all.capturedAt,
            usualRates: all.usualRates
        )
        return generate(records, now: repository.anchor)
    }

    /// Monday 21 September 2026, 15:13 in London.
    let readingNow = Date(timeIntervalSince1970: 1_790_000_000)

    /// A report at `now` made only from account caches, status-line readings and open sessions.
    func accountReport(
        snapshots: [AccountUsageSnapshot] = [], limits: [LimitReading] = [], sessions: [SessionEvent] = [],
        now: Date
    ) -> UsageReport {
        GenerateUsageReport(
            settings: UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20),
            calendar: calendar
        )(
            UsageRecords(
                turns: [], limits: limits, sessionEvents: sessions, capturedAt: now, accountSnapshots: snapshots
            ),
            now: now
        )
    }

    func cache(
        _ id: String, _ name: String, readAt: Date, fiveHour: Double?, weekly: Double?,
        fiveHourResetsAt: Date? = nil, weeklyResetsAt: Date? = nil
    ) -> AccountUsageSnapshot {
        AccountUsageSnapshot(
            id: id, name: name, agent: .claudeCode, readAt: readAt, fiveHourPercent: fiveHour, weeklyPercent: weekly,
            fiveHourResetsAt: fiveHourResetsAt, weeklyResetsAt: weeklyResetsAt
        )
    }

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

    @Test func eachPeriodShowsOnlyItsOwnLimit() async throws {
        let report = try await Self.fakeReportWithoutAccounts()

        #expect(try all(report, .today).limits.map(\.name) == ["Claude 5-hour"])
        // Week: the weekly limit only, never the 5-hour window. Codex's week reset at 12:32.
        #expect(try all(report, .week).limits.map(\.name) == ["Claude week", "Codex week limit reset"])
        #expect(try agent(report, .claudeCode, .week).limits.map(\.title) == ["Week limit 48%"])
        // Month: neither rolling limit; the month's spend and tokens remain.
        let month = try agent(report, .claudeCode, .month)
        #expect(month.limits.isEmpty)
        #expect(try all(report, .month).limits.isEmpty)
        #expect(month.stats.map(\.label).contains("Spent"))
        #expect(month.stats.map(\.label).contains("Tokens"))
    }

    @Test func monthSaysNothingAboutAnAccountWithoutAReading() {
        let presenter = UsagePanelPresenter(formatter: UsageFormatter(calendar: .current))
        let none = AgentLimits(fiveHour: nil, weekly: nil, monthly: nil)
        let row = { (period: UsagePeriod) in
            presenter.limitRows(.claudeCode, limits: none, period: period, now: .now, account: "Default")
        }
        #expect(row(.today).map(\.freesUp) == ["No recent limit reading"])
        #expect(row(.week).map(\.freesUp) == ["No recent limit reading"])
        #expect(row(.month).isEmpty)
    }

    @Test func accountPercentagesFollowThePeriodToo() {
        let snapshot = cache("/Users/me/.claude", "Default", readAt: readingNow, fiveHour: 11, weekly: 18)
        let windows = { (period: UsagePeriod) in
            presenter.lastWindows(.none, snapshot: snapshot, period: period, now: readingNow).map(\.kind)
        }
        #expect(windows(.today) == [.fiveHour])
        #expect(windows(.week) == [.weekly])
        #expect(windows(.month).isEmpty)
    }

    @Test func todayExcludesWeeklyLimitsWhileWeekIncludesThem() async throws {
        let report = try await Self.fakeReportWithoutAccounts()

        let today = try all(report, .today)
        #expect(today.limits.map(\.name) == ["Claude 5-hour"])
        #expect(today.headline == "Claude runs out first: 38% of its 5-hour window is left until 16:40.")
        #expect(try agent(report, .claudeCode, .today).limits.map(\.title) == ["5-hour limit 62%"])
        #expect(try agent(report, .codex, .today).limits.isEmpty)

        let week = try all(report, .week)
        #expect(week.limits.map(\.name) == ["Claude week", "Codex week limit reset"])
        #expect(try agent(report, .claudeCode, .week).limits.map(\.title) == ["Week limit 48%"])
    }

    // MARK: - The last reading, however old

    @Test func twoClaudeAccountsShowTheirLastReadingWhateverItsAge() throws {
        let now = readingNow
        let report = accountReport(snapshots: [
            cache("/profiles/work", "Work", readAt: now, fiveHour: 20, weekly: 40),
            cache("/profiles/personal", "Personal", readAt: now - 3600, fiveHour: 80, weekly: 90),
        ], now: now)

        // Accounts are listed by their folder, so Personal comes first. Neither cache has a reset time.
        let overview = try all(report)
        #expect(overview.limits.map(\.name) == ["Claude · Personal 5-hour", "Claude · Work 5-hour"])
        #expect(overview.limits.map(\.used) == ["80%", "20%"])
        #expect(overview.limits.map(\.freesUp) == [
            "Reset time unknown · read 14:13", "Reset time unknown · read 15:13",
        ])
        let claude = try agent(report, .claudeCode, .today)
        #expect(claude.limits.map(\.title) == ["Personal · 5-hour limit 80%", "Work · 5-hour limit 20%"])
        #expect(claude.limits.map(\.detail) == ["Reset time unknown · read 14:13", "Reset time unknown · read 15:13"])
        // Both accounts have a reading, so there is nothing to say is missing.
        #expect(claude.note?.title != "Limit reading unavailable")

        let week = try all(report, .week)
        #expect(week.limits.map(\.name) == ["Claude · Personal week", "Claude · Work week"])
        #expect(week.limits.map(\.used) == ["90%", "40%"])
        #expect(week.limits.map(\.isNearlyUsed) == [true, false])
    }

    @Test func anOldReadingAtEitherEndIsShownAsReadNeverAsCurrent() throws {
        for percentage in [0.0, 100.0] {
            let report = accountReport(snapshots: [
                cache("/profiles/personal", "Personal", readAt: readingNow - 27 * 60, fiveHour: percentage, weekly: percentage),
            ], now: readingNow)

            let row = try #require(try all(report).limits.first)
            #expect(row.name == "Claude · Personal 5-hour")
            #expect(row.fraction == percentage / 100)
            #expect(row.used == "\(Int(percentage))%")
            #expect(row.freesUp == "Reset time unknown · read 14:46")
            #expect(row.isNearlyUsed == (percentage >= 85))
            let claude = try agent(report, .claudeCode, .today)
            #expect(claude.limits.map(\.title) == ["Personal · 5-hour limit \(Int(percentage))%"])
            #expect(claude.limits.map(\.detail) == ["Reset time unknown · read 14:46"])
            #expect(claude.note?.title != "Limit reading unavailable")
        }
    }

    @Test func aReadingWithAFutureResetSaysWhenItResetsAndHowOldItIs() throws {
        // Read at 11:13, at its weekly limit, with the week resetting on Wednesday at 17:13.
        let now = readingNow
        let report = accountReport(snapshots: [
            cache("/profiles/second", "Second", readAt: now - 4 * 3600, fiveHour: 0, weekly: 100,
                  weeklyResetsAt: now + 2 * 86_400 + 2 * 3600),
        ], now: now)

        #expect(try agent(report, .claudeCode, .week).limits == [BarRowModel(
            title: "Second · Week limit 100%", detail: "Resets Wed 17:13 · in 2d 2h · read 11:13",
            fraction: 1, highlightFraction: nil, isNearlyUsed: true, note: nil
        )])
        let row = try #require(try all(report, .week).limits.first)
        #expect(row.name == "Claude · Second week")
        #expect(row.fraction == 1)
        #expect(row.used == "100%")
        #expect(row.freesUp == "Resets Wed 17:13 · in 2d 2h · read 11:13")
        #expect(row.isNearlyUsed)
        // The 5-hour percentage of the same cache has no reset time of its own.
        #expect(try agent(report, .claudeCode, .today).limits == [BarRowModel(
            title: "Second · 5-hour limit 0%", detail: "Reset time unknown · read 11:13",
            fraction: 0, highlightFraction: nil, isNearlyUsed: false, note: nil
        )])
    }

    @Test func aReadingWhoseResetHasPassedSaysItResetAndIsNotAmber() throws {
        let now = readingNow
        let report = accountReport(snapshots: [
            cache("/profiles/second", "Second", readAt: now - 2 * 86_400, fiveHour: 96, weekly: 100,
                  fiveHourResetsAt: now - 2 * 3600, weeklyResetsAt: now - 86_400),
        ], now: now)

        #expect(try agent(report, .claudeCode, .week).limits == [BarRowModel(
            title: "Second · Week limit reset", detail: "Reset Sun 15:13 · no reading since",
            fraction: 0, highlightFraction: nil, isNearlyUsed: false, note: nil
        )])
        #expect(try agent(report, .claudeCode, .today).limits == [BarRowModel(
            title: "Second · 5-hour limit reset", detail: "Reset 13:13 · no reading since",
            fraction: 0, highlightFraction: nil, isNearlyUsed: false, note: nil
        )])
        let week = try #require(try all(report, .week).limits.first)
        #expect(week.name == "Claude · Second week limit reset")
        #expect(week.fraction == 0)
        #expect(week.used == "")
        #expect(week.freesUp == "Reset Sun 15:13 · no reading since")
        #expect(!week.isNearlyUsed)
        let today = try #require(try all(report).limits.first)
        #expect(today.name == "Claude · Second 5-hour limit reset")
        #expect(today.freesUp == "Reset 13:13 · no reading since")
        #expect(!today.isNearlyUsed)
    }

    @Test func theLaterOfAnAccountCacheAndAResetWindowIsWhatIsShown() {
        let now = readingNow
        let reset = ResetWindow(kind: .weekly, resetsAt: now - 86_400, readAt: now - 2 * 86_400)
        let limits = AgentLimits(fiveHour: nil, weekly: nil, monthly: nil, resetWindows: [reset])
        func titles(cachedAt: Date) -> [String] {
            let snapshot = cache("/profiles/work", "Work", readAt: cachedAt, fiveHour: nil, weekly: 70)
            return presenter.limitBars(
                limits, period: .week, agent: .claudeCode, now: now, account: "Work", snapshot: snapshot
            ).map(\.title)
        }
        // Read after the reset: 70% of the week now running, with no reset time.
        #expect(titles(cachedAt: now - 3600) == ["Work · Week limit 70%"])
        // Read before the reset: that 70% belonged to the window that has ended.
        #expect(titles(cachedAt: now - 3 * 86_400) == ["Work · Week limit reset"])
    }

    @Test func aLiveReadingOfAWindowWinsOverTheCacheOfIt() {
        let now = readingNow
        let live = LimitReport(
            kind: .weekly, usedPercent: 48, resetsAt: now + 86_400, readAt: now - 60, percentPerHour: nil,
            runsOutAt: nil, projectedLeftAtReset: nil, calendarDaysLeft: 1
        )
        let limits = AgentLimits(fiveHour: nil, weekly: live, monthly: nil)
        let snapshot = cache("/profiles/work", "Work", readAt: now - 3600, fiveHour: nil, weekly: 95)
        let bars = presenter.limitBars(
            limits, period: .week, agent: .claudeCode, now: now, account: "Work", snapshot: snapshot
        )
        #expect(bars.map(\.title) == ["Work · Week limit 48%"])
        let rows = presenter.limitRows(
            .claudeCode, limits: limits, period: .week, now: now, account: "Work", accountID: "/profiles/work",
            snapshot: snapshot
        )
        #expect(rows.map(\.used) == ["48%"])
    }

    @Test func theNoteAppearsOnlyForAnAccountWithNoReadingAtAll() throws {
        let now = readingNow
        func session(_ id: String, _ name: String) -> SessionEvent {
            SessionEvent(
                timestamp: now - 60, agent: .claudeCode, sessionID: "claude-\(name)", kind: .start, state: .working,
                activeDuration: 0, idleDuration: 0, work: WorkTag(project: "app", concern: "main"),
                origin: SessionOrigin(
                    pid: 10, tty: "ttys001", terminal: .warp, folder: "/Users/me/app",
                    accountName: name, accountID: id
                )
            )
        }
        let work = cache("/profiles/work", "Work", readAt: now, fiveHour: 20, weekly: 40)
        let report = accountReport(
            snapshots: [work], sessions: [session("/profiles/new", "New"), session("/profiles/other", "Other")], now: now
        )
        let claude = try agent(report, .claudeCode, .today)
        #expect(claude.note == NoteModel(
            title: "Limit reading unavailable", text: "No limit reading saved for New, Other yet."
        ))
        // Their rows say so too, and the account with a reading keeps its row.
        #expect(try all(report).limits.map(\.freesUp) == [
            "No recent limit reading", "No recent limit reading", "Reset time unknown · read 15:13",
        ])
        // Month has no rolling window, so a missing reading is nothing to report there.
        #expect(try agent(report, .claudeCode, .month).note?.title != "Limit reading unavailable")

        let one = accountReport(snapshots: [work], sessions: [session("/profiles/new", "New")], now: now)
        #expect(try agent(one, .claudeCode, .today).note?.text == "No limit reading saved for New yet.")
        let none = accountReport(snapshots: [work], sessions: [session("/profiles/work", "Work")], now: now)
        #expect(try agent(none, .claudeCode, .today).note?.title != "Limit reading unavailable")
    }

    @Test func aWindowThatHasResetIsShownAsResetInsteadOfDisappearing() async throws {
        let report = try await OverlayPresenterTests.fakeReport()
        // Codex's week reset at 12:32, and its reading at noon is the last it has.
        let codex = try agent(report, .codex, .week)
        #expect(codex.limits == [BarRowModel(
            title: "Week limit reset", detail: "Reset 12:32 · no reading since",
            fraction: 0, highlightFraction: nil, isNearlyUsed: false, note: nil
        )])
        // Codex does share its limits, so the note does not say it doesn't.
        #expect(codex.note == nil)
        let row = try #require(try all(report, .week).limits.first { $0.agent == .codex })
        #expect(row.name == "Codex week limit reset")
        #expect(row.fraction == 0)
        #expect(row.freesUp == "Reset 12:32 · no reading since")
        #expect(!row.isNearlyUsed)
        // Today has no weekly window to show, and a reset window is not a limit to lead with.
        #expect(try agent(report, .codex, .today).limits.isEmpty)
        #expect(try all(report, .week).headline == "Claude runs out first: 52% of its week is left until Thu 09:00.")
    }

    @Test func aPlanThatHasResetSaysSoOnTheMonthView() {
        let now = readingNow
        let reset = ResetWindow(kind: .plan, resetsAt: now - 3600, readAt: now - 7200)
        let limits = AgentLimits(fiveHour: nil, weekly: nil, monthly: nil, resetWindows: [reset])
        #expect(presenter.limitBars(limits, period: .month, agent: .kiro, now: now) == [BarRowModel(
            title: "Plan reset", detail: "Reset 14:13 · no reading since",
            fraction: 0, highlightFraction: nil, isNearlyUsed: false, note: nil
        )])
        #expect(presenter.limitRows(.kiro, limits: limits, period: .month, now: now).map(\.name)
            == ["Kiro month limit reset"])
    }

    @Test func theFakeAccountsShowOneKnownResetAndOneUnknown() async throws {
        let report = try await OverlayPresenterTests.fakeReport()
        let week = try agent(report, .claudeCode, .week)
        #expect(week.limits.map(\.title) == ["Default · Week limit 95%", "Second · Week limit 100%"])
        #expect(week.limits.map(\.detail) == [
            "Reset time unknown · read 14:29", "Resets Wed 17:00 · in 2d 2h · read 10:32",
        ])
        #expect(week.limits.map(\.isNearlyUsed) == [true, true])
        #expect(week.note == nil)
        let today = try agent(report, .claudeCode, .today)
        #expect(today.limits.map(\.title) == ["Default · 5-hour limit 9%", "Second · 5-hour limit 0%"])
        #expect(try all(report, .week).limits.map(\.name)
            == ["Claude · Default week", "Claude · Second week", "Codex week limit reset"])
    }

    @Test func reportedPercentageWithoutResetSaysResetTimeIsUnavailable() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let plan = PlanUsage(
            name: "Kiro Power", creditsUsed: 37, creditsLimit: 100,
            usedPercent: 37, resetsAt: nil, readAt: now
        )
        let limits = AgentLimits(fiveHour: nil, weekly: nil, monthly: nil, plan: plan)
        let overview = presenter.limitRows(.kiro, limits: limits, period: .today, now: now)
        #expect(overview.map(\.used) == ["37%"])
        #expect(overview.map(\.freesUp) == ["Reset time unavailable"])
        #expect(presenter.limitBars(limits, period: .today, agent: .kiro, now: now).map(\.detail)
            == ["Reset time unavailable"])
    }

    // MARK: - Frame 4: every agent, today

    @Test func theAllViewMatchesFrame4() async throws {
        let model = try all(try await Self.fakeReportWithoutAccounts())
        #expect(model.headline == "Claude runs out first: 38% of its 5-hour window is left until 16:40.")
        #expect(model.limits.map(\.name) == ["Claude 5-hour"])
        #expect(model.limits.map(\.used) == ["62%"])
        #expect(model.limits.map(\.freesUp) == ["Resets 16:40"])
        // 85% or more is amber; agents that share no limits have no empty row.
        #expect(model.limits.map(\.isNearlyUsed) == [false])
        #expect(model.limits.last?.fraction == 0.62)
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

    // MARK: - Kiro: credits and no tokens

    // Tuesday 22 September 2026, 15:00 in London, so the replies below fall on today.
    var kiroNow: Date { Date(timeIntervalSince1970: 1_790_085_600) }

    /// Kiro replies as a current build writes them: credits, a model of each reply's own, tool
    /// calls and no tokens. The latest reply that says how full the context is puts it at 126k
    /// of a million; the newest reply says nothing.
    var kiroTurns: [Turn] {
        func reply(
            _ id: String, _ model: ModelName, minutesAgo: Double, credits: Double, toolCalls: Int,
            context: ContextUsage?
        ) -> Turn {
            Turn(
                id: id, timestamp: kiroNow - minutesAgo * 60, agent: .kiro, sessionID: "k", model: model,
                work: Work(tag: WorkTag(project: "shop", concern: "main")), tokens: nil, cost: Cost(usd: nil),
                context: context, credits: credits, toolCalls: toolCalls
            )
        }
        return [
            reply("1", "auto", minutesAgo: 30, credits: 10, toolCalls: 4,
                  context: ContextUsage(used: 50_000, window: 1_000_000)),
            reply("2", "claude-opus-4.8", minutesAgo: 20, credits: 60, toolCalls: 3,
                  context: ContextUsage(used: 125_619, window: 1_000_000)),
            reply("3", "auto", minutesAgo: 15, credits: 2.5, toolCalls: 1, context: nil),
        ]
    }

    /// A Claude reply with tokens and a context of its own, so the table has two agents.
    var claudeTurn: Turn {
        Turn(
            id: "c1", timestamp: kiroNow - 1_800, agent: .claudeCode, sessionID: "c", model: "claude-opus-5",
            work: Work(tag: WorkTag(project: "app", concern: "main")), tokens: TokenUsage(input: 1_000),
            cost: Cost(usd: 2), context: ContextUsage(used: 80_000, window: 200_000)
        )
    }

    @Test func anAgentWithNoTokensButAContextShowsItAsAnEstimateInsteadOfNotAvailable() throws {
        let report = usageReport(now: kiroNow, turns: [claudeTurn] + kiroTurns)
        let model = try all(report)
        let kiro = try #require(model.rows.first { $0.agent == .kiro })
        // 125,619 tokens of the million, said as an estimate and marked, never as tokens used.
        #expect(kiro.tokens == "ctx ~126k")
        #expect(kiro.tokensIsEstimate)
        #expect(kiro.spend == "72.5 cr")
        // Claude has tokens, so its context never replaces them.
        let claude = try #require(model.rows.first { $0.agent == .claudeCode })
        #expect(claude.tokens == "1k")
        #expect(!claude.tokensIsEstimate)
    }

    @Test func theTotalRowLeavesTheContextEstimateOut() throws {
        let report = usageReport(now: kiroNow, turns: [claudeTurn] + kiroTurns)
        let total = try #require(try all(report).total)
        // Only Claude's measured tokens and cost are added up.
        #expect(total.tokens == "1k")
        #expect(!total.tokensIsEstimate)
        #expect(total.spend == "$2.00")
        // Kiro alone with Claude gone: one agent needs no total, and its cell is still the estimate.
        let alone = try all(usageReport(now: kiroNow, turns: kiroTurns))
        #expect(alone.total == nil)
        #expect(alone.rows.map(\.tokens) == ["ctx ~126k"])
    }

    @Test func kiroModelsShowTheirCreditsAndTheCreditsStatComesFirst() throws {
        let kiro = try agent(usageReport(now: kiroNow, turns: kiroTurns), .kiro, .today)
        // 60 of 72.5 credits were Opus's. Models are named as the agent names them: "auto".
        #expect(kiro.models == [
            ModelShareRowModel(name: "Opus 4.8", percent: "83%", credits: "60 cr"),
            ModelShareRowModel(name: "auto", percent: "17%", credits: "12.5 cr"),
        ])
        #expect(kiro.stats == [
            StatModel(label: "Credits", value: "72.5 cr"), StatModel(label: "Time", value: "5m"),
            StatModel(label: "Sessions", value: "1"), StatModel(label: "Prompts", value: "3"),
            StatModel(label: "Tool calls", value: "8"),
        ])
        #expect(kiro.note?.text == "Kiro doesn't share tokens or limits on this Mac, so this shows credits, time and activity.")
    }

    @Test func modelsOfAnAgentThatBillsNoCreditsShowNone() throws {
        let claude = try agent(usageReport(now: kiroNow, turns: [claudeTurn]), .claudeCode, .today)
        #expect(claude.models.map(\.credits) == [nil])
        #expect(!claude.stats.contains { $0.label == "Credits" })
    }

    @Test func theHeadlineSaysWhenALimitHasRunOut() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let full = LimitReport(
            kind: .fiveHour, usedPercent: 100, resetsAt: now + 3600, readAt: now, percentPerHour: nil, runsOutAt: nil,
            projectedLeftAtReset: nil, calendarDaysLeft: 0
        )
        let headline = presenter.headline(
            [.codex: AgentLimits(fiveHour: full, weekly: nil, monthly: nil)], now: now, period: .today
        )
        #expect(headline == "Codex has run out of its 5-hour window until 16:13.")
        #expect(presenter.headline([:], now: now) == nil)
    }

    // MARK: - Frame 5: Claude's week

    @Test func claudesWeekMatchesFrame5() async throws {
        let model = try agent(try await Self.fakeReportWithoutAccounts(), .claudeCode, .week)
        #expect(model.note == nil)
        // Week shows the weekly limit only, with when it frees up.
        #expect(model.limits.map(\.title) == ["Week limit 48%"])
        #expect(model.limits.map(\.detail) == ["Resets Thu 09:00 · in 2d 18h"])
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
        #expect(table.limits.isEmpty)
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
