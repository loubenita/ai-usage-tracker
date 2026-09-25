import Foundation
import Testing
import UsageData
import UsageDomain
@testable import UsagePresentation

/// The strip and the session panel, against the Paper frames 1 to 3. The strings are the
/// frames' own, worked out from the made-up data; where the data cannot reach the frame's
/// number, the test says why.
@Suite("The strip and the session panel match the Paper frames")
struct OverlayPresenterTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    var calendar: Calendar { Self.calendar }
    var presenter: OverlayPresenter { OverlayPresenter(formatter: UsageFormatter(calendar: calendar)) }

    static func fakeReport() async throws -> UsageReport {
        let repository = FakeUsageRepository(calendar: calendar)
        let generate = GenerateUsageReport(settings: try await repository.settings(), calendar: calendar)
        let range = generate.recordRange(endingAt: repository.anchor)
        return generate(try await repository.records(from: range.start, to: range.end), now: repository.anchor)
    }

    // MARK: - Frames 1 and 2: the strip

    @Test func theRingsShowCurrentContextInsteadOfCumulativeTokens() async throws {
        let strip = presenter.strip(try await Self.fakeReport(), hovered: nil, open: nil, acknowledged: [])
        // The text and the fill now describe the same reading. These sessions have accumulated
        // 640k, 280k and 1.1M tokens, while their live contexts are 142k, 68k and 184k.
        #expect(strip.items.map(\.ring.label) == ["142k", "68k", "184k"])
        #expect(strip.items.map(\.ring.fraction) == [0.71, 0.34, 0.92])
        // The panel keeps the cumulative number and names it as a total.
        #expect(presenter.panel(try await Self.fakeReport(), sessionID: "s_bug")?.stats
            .first { $0.label == "Total tokens" }?.value == "1.1M")
        // Short enough for the 30pt strip; the panel says "1h 47m" in full.
        #expect(strip.items.map(\.time) == ["1h47", "23m", "58m"])
        #expect(strip.items.map(\.ring.isNearlyFull) == [false, false, true])
        #expect(strip.items.map(\.ring.agent) == [.claudeCode, .claudeCode, .codex])
        #expect(strip.items.map(\.needsUser) == [false, true, false])
        #expect(strip.items.map(\.pulses) == [false, true, false])
        #expect(strip.items.allSatisfy { $0.highlight == .none })
    }

    @Test func theExpandedStripKeepsOnlyTheShortTaskIdentity() async throws {
        let strip = presenter.strip(try await Self.fakeReport(), hovered: nil, open: nil, acknowledged: [])
        #expect(strip.items.map(\.title) == ["Video generation", "Image generation", "Bug fixes"])
        // Provider, project and first ask remain available to assistive technology and in the
        // selected session panel without making every strip row tall and wide.
        #expect(strip.items[1].accessibilityLabel.contains("Claude"))
        #expect(strip.items[1].accessibilityLabel.contains("Marketing Studio"))
        #expect(strip.items[1].accessibilityLabel.contains("Add retry to the image generation call"))
    }

    @Test func theRestingStripListsTheSessionsThatWereBusyMostRecently() async throws {
        let strip = presenter.strip(try await Self.fakeReport(), hovered: nil, open: nil, acknowledged: [])
        // The strip keeps the order the sessions started in; each item says how recent it is.
        #expect(strip.items.map(\.id) == ["s_vid", "s_img", "s_bug"])
        // Bug fixes replied at 14:30, Image generation stopped at 14:28, Video at 13:20.
        #expect(strip.items.map(\.recency) == [2, 1, 0])
    }

    @Test func hoverAndOpenHighlights() async throws {
        let report = try await Self.fakeReport()
        let hovered = presenter.strip(report, hovered: "s_img", open: nil, acknowledged: ["s_img"])
        #expect(hovered.items.map(\.highlight) == [.none, .hovered, .none])
        #expect(hovered.items[1].pulses == false)
        let open = presenter.strip(report, hovered: "s_img", open: "s_img", acknowledged: [])
        #expect(open.items[1].highlight == .selected)
    }

    @Test func aSessionWithNoContextShowsItsLabelInTheRing() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tag = WorkTag(project: "ai-usage-tracker", concern: "main")
        let turn = Turn(
            id: "t", timestamp: start + 60, agent: .claudeCode, sessionID: "claude-code-3857",
            model: "claude-opus-5", work: Work(tag: tag), tokens: TokenUsage(cacheRead: 5_000_000),
            cost: Cost(usd: nil), context: nil
        )
        let report = detected(turns: [turn])
        let strip = presenter.strip(report, hovered: nil, open: nil, acknowledged: [])
        // Even with 5M cumulative tokens, a missing context never makes the ring say "5M".
        #expect(strip.items.map(\.ring.label) == ["MAI"])
        #expect(strip.items.map(\.time) == ["1h30"])
    }

    // MARK: - Frame 3: the session panel

    @Test func theSessionPanelMatchesFrame3() async throws {
        let panel = try #require(presenter.panel(try await Self.fakeReport(), sessionID: "s_img"))
        #expect(panel.subtitle == "Marketing Studio")
        #expect(panel.title == "Image generation")
        #expect(panel.agent == .claudeCode)
        #expect(panel.openAction == .terminal("Warp"))
        #expect(panel.status == StatusModel(kind: .waiting, text: "Waiting for your reply · 4m", place: "Warp"))
        #expect(panel.stats == [
            StatModel(label: "Total spent", value: "$1.10"), StatModel(label: "Total tokens", value: "280k"),
            StatModel(label: "Active", value: "23m"), StatModel(label: "Turns", value: "18"),
        ])
        #expect(panel.context?.title == "Context 34%")
        #expect(panel.context?.detail == "68k of 200k · full ~15:20")
        // The session's own replies and its sub-agents' together.
        #expect(panel.tokenMix.map(\.label) == ["Input", "Output", "Cache read", "Cache write"])
        #expect(panel.tokenMix.map(\.value) == ["52k", "14k", "200k", "14k"])
        #expect(panel.tokenMixNote == "Input is new, uncached text. Cache read is context reused from earlier turns.")
        #expect(panel.subagents == SubagentsModel(
            title: "SUB-AGENT RUNS · 6",
            inclusion: "Included in session totals",
            share: "31% of session spend",
            total: "137k · $0.34 · 15m combined",
            rows: [
                SubagentRowModel(id: "agent-1", model: "Sonnet 5", run: "Run 1", tokens: "24k", cost: "$0.08", time: "3m"),
                SubagentRowModel(id: "agent-2", model: "Sonnet 5", run: "Run 2", tokens: "24k", cost: "$0.07", time: "3m"),
                SubagentRowModel(id: "agent-3", model: "Sonnet 5", run: "Run 3", tokens: "24k", cost: "$0.07", time: "3m"),
                SubagentRowModel(id: "agent-4", model: "Sonnet 5", run: "Run 4", tokens: "24k", cost: "$0.07", time: "3m"),
                SubagentRowModel(id: "agent-5", model: "Haiku 4.5", run: "Run 5", tokens: "21k", cost: "$0.03", time: "1m"),
                SubagentRowModel(id: "agent-6", model: "Haiku 4.5", run: "Run 6", tokens: "21k", cost: "$0.02", time: "1m"),
            ]
        ))
        // The pace is the session's own replies only; the frame's 310k/h is not in the made-up data.
        #expect(panel.details == [
            DetailRowModel(label: "Pace", value: "100k/h · about your usual"),
            DetailRowModel(label: "Model", value: "Opus 5 · high effort"),
            DetailRowModel(label: "Started", value: "14:05 · open 27m"),
            DetailRowModel(label: "Work", value: "64 tool calls · 7 files changed"),
            DetailRowModel(label: "Branch", value: "feat/image-gen-v2"),
            DetailRowModel(label: "First ask", value: "\"Add retry to the image gener…\""),
        ])
    }

    /// A session detected in a terminal, with the given turns and no limits.
    func detected(turns: [Turn], terminal: TerminalApp = .warp, snapshot: SessionSnapshot? = nil) -> UsageReport {
        let origin = SessionOrigin(pid: 3857, tty: "ttys002", terminal: terminal, folder: "/Users/me/ai-usage-tracker")
        let tag = WorkTag(project: "ai-usage-tracker", concern: "main")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var events = [SessionEvent(
            timestamp: start, agent: .claudeCode, sessionID: "claude-code-3857", kind: .start, state: .working,
            activeDuration: 0, idleDuration: 0, work: tag,
            workDetail: Work(tag: tag, branch: "main", folder: origin.folder), origin: origin
        )]
        if let snapshot {
            events.append(SessionEvent(
                timestamp: start + 60, agent: .claudeCode, sessionID: "claude-code-3857", kind: .active,
                state: .working, activeDuration: 60, idleDuration: 0, work: tag, snapshot: snapshot
            ))
        }
        let records = UsageRecords(turns: turns, limits: [], sessionEvents: events, capturedAt: start)
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        return GenerateUsageReport(settings: settings, calendar: calendar)(records, now: start + 5400)
    }

    @Test func whatTheAgentDidNotReportIsLeftOutNotShownAsZero() throws {
        let panel = try #require(presenter.panel(detected(turns: []), sessionID: "claude-code-3857"))
        // On main, the branch says nothing about the task, so the folder names it.
        #expect(panel.title == "ai-usage-tracker")
        // No replies yet: no cost, tokens or turns; no context, token mix, pace or model.
        #expect(panel.stats == [StatModel(label: "Active", value: "1h 30m")])
        #expect(panel.context == nil)
        #expect(panel.tokenMix.isEmpty)
        #expect(panel.tokenMixNote == nil)
        #expect(panel.subagents == nil)
        #expect(panel.details == [
            DetailRowModel(label: "Started", value: "15:13 · open 1h 30m"),
            DetailRowModel(label: "Branch", value: "main"),
        ])
        #expect(panel.status == StatusModel(kind: .working, text: "Working", place: "Warp"))
    }

    @Test func aCountOfNoneIsLeftOutAndOneIsSingular() throws {
        let snapshot = SessionSnapshot(activity: SessionActivity(toolCalls: 1, filesChanged: 0, firstAsk: "Fix it"))
        let panel = try #require(presenter.panel(detected(turns: [], snapshot: snapshot), sessionID: "claude-code-3857"))
        #expect(panel.details.first { $0.label == "Work" }?.value == "1 tool call")
        #expect(panel.details.first { $0.label == "First ask" }?.value == "\"Fix it\"")
    }

    @Test func thePlaceSaysWhichTerminalAndTmuxSession() {
        func origin(_ terminal: TerminalApp, tmux: TmuxLocation? = nil, host: TerminalApp? = nil) -> SessionOrigin {
            SessionOrigin(pid: 1, tty: "ttys004", terminal: terminal, folder: "/", tmux: tmux, hostTerminal: host)
        }
        #expect(OverlayPresenter.place(origin(.warp)) == "Warp")
        #expect(OverlayPresenter.place(origin(.terminal)) == "Terminal · ttys004")
        #expect(OverlayPresenter.place(origin(.tmux, tmux: TmuxLocation(session: "lead"), host: .warp)) == "Warp · tmux lead")
        #expect(OverlayPresenter.place(origin(.tmux)) == "tmux")
        #expect(OverlayPresenter.place(origin(.unknown)) == nil)
    }

    @Test func aKiroSessionShowsItsCreditsWhereTheCostWouldBe() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tag = WorkTag(project: "shop", concern: "main")
        let turns = [0.5, 0.25].enumerated().map { index, credits in
            Turn(
                id: "k\(index)", timestamp: start + Double(index + 1) * 60, agent: .kiro, sessionID: "k", model: "auto",
                work: Work(tag: tag), tokens: nil, cost: Cost(usd: nil), context: nil, credits: credits
            )
        }
        let plan = PlanUsage(
            name: "KIRO POWER", creditsUsed: 2_100, creditsLimit: 5_000, usedPercent: 42,
            resetsAt: Date(timeIntervalSince1970: 1_790_809_200), readAt: start
        )
        let records = UsageRecords(
            turns: turns, limits: [],
            sessionEvents: [SessionEvent(
                timestamp: start, agent: .kiro, sessionID: "k", kind: .start, state: .working,
                activeDuration: 0, idleDuration: 0, work: tag
            )],
            capturedAt: start, plans: [.kiro: plan]
        )
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let report = GenerateUsageReport(settings: settings, calendar: calendar)(records, now: start + 600)
        let panel = try #require(presenter.panel(report, sessionID: "k"))
        #expect(panel.stats.first == StatModel(label: "Credits", value: "0.8"))
        #expect(!panel.stats.contains { $0.label == "Total tokens" })
        // Account plan limits are deliberately absent from a selected-session panel.
        #expect(panel.details.allSatisfy { !$0.label.localizedCaseInsensitiveContains("plan") })
    }

    @Test func aPanelDoesNotMixAccountLimitsIntoEitherSession() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tag = WorkTag(project: "app", concern: "main")
        let event = { (agent: Agent, id: String) in
            SessionEvent(
                timestamp: start, agent: agent, sessionID: id, kind: .start, state: .working,
                activeDuration: 0, idleDuration: 0, work: tag
            )
        }
        let claudeLimits = LimitReading(
            timestamp: start, agent: .claudeCode, plan: nil,
            windows: [
                LimitWindowReading(kind: .fiveHour, usedPercent: 62, resetsAt: start + 3600),
                LimitWindowReading(kind: .weekly, usedPercent: 71, resetsAt: start + 3 * 86_400),
            ]
        )
        let records = UsageRecords(
            turns: [], limits: [claudeLimits], sessionEvents: [event(.claudeCode, "a"), event(.codex, "b")],
            capturedAt: start
        )
        let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
        let report = GenerateUsageReport(settings: settings, calendar: calendar)(records, now: start + 60)
        let claude = try #require(presenter.panel(report, sessionID: "a"))
        let codex = try #require(presenter.panel(report, sessionID: "b"))
        for panel in [claude, codex] {
            let sessionText = ([panel.title, panel.subtitle, panel.status.text]
                + panel.stats.flatMap { [$0.label, $0.value] }
                + panel.details.flatMap { [$0.label, $0.value] })
                .joined(separator: " ").lowercased()
            #expect(!sessionText.contains("limit"))
            #expect(!sessionText.contains("reset"))
            #expect(!sessionText.contains("plan"))
        }
    }

    @Test func theSubagentShareIsOfTheSpendOrOfTheTokensWithoutACost() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let tag = WorkTag(project: "p", concern: "c")
        func report(ownCost: Decimal?, runs: [SubagentRun]) -> UsageReport {
            let turns = (0..<3).map { index in
                Turn(
                    id: "t\(index)", timestamp: start + Double(index) * 60, agent: .claudeCode, sessionID: "s",
                    model: "claude-opus-5", work: Work(tag: tag), tokens: TokenUsage(input: 1_000, output: 1_000),
                    cost: Cost(usd: ownCost), context: nil
                )
            }
            let events = [
                SessionEvent(
                    timestamp: start, agent: .claudeCode, sessionID: "s", kind: .start, state: .working,
                    activeDuration: 0, idleDuration: 0, work: tag
                ),
                SessionEvent(
                    timestamp: start + 180, agent: .claudeCode, sessionID: "s", kind: .active, state: .working,
                    activeDuration: 180, idleDuration: 0, work: tag, snapshot: SessionSnapshot(subagents: runs)
                ),
            ]
            let settings = UsageSettings(dailyCostBudget: nil, dailyTokenBudget: nil, workdayEndHour: 20)
            let records = UsageRecords(turns: turns, limits: [], sessionEvents: events, capturedAt: start + 180)
            return GenerateUsageReport(settings: settings, calendar: calendar)(records, now: start + 180)
        }
        // $1 of the session's $4.
        let priced = try #require(presenter.panel(report(ownCost: 1, runs: [
            SubagentRun(id: "a", model: "claude-sonnet-5", tokens: TokenUsage(input: 3_000), costUSD: 1, workingTime: 60),
        ]), sessionID: "s"))
        #expect(priced.subagents?.share == "25% of session spend")
        #expect(priced.subagents?.title == "SUB-AGENT RUNS · 1")
        #expect(priced.subagents?.inclusion == "Included in session totals")
        #expect(priced.subagents?.total == "3k · $1.00 · 1m combined")
        // Without a cost, their share of the tokens: 4,000 of 10,000. A run under a minute
        // says so rather than "0m".
        let unpriced = try #require(presenter.panel(report(ownCost: nil, runs: [
            SubagentRun(id: "a", model: "gpt-5.6", tokens: TokenUsage(input: 4_000), costUSD: nil, workingTime: 20),
        ]), sessionID: "s"))
        #expect(unpriced.subagents?.share == "40% of session tokens")
        #expect(unpriced.subagents?.total == "4k · <1m combined")
        #expect(unpriced.subagents?.rows == [
            SubagentRowModel(id: "a", model: "gpt-5.6", run: "Run 1", tokens: "4k", cost: nil, time: "<1m")
        ])
        // A session with no sub-agents has no section at all.
        #expect(presenter.panel(report(ownCost: 1, runs: []), sessionID: "s")?.subagents == nil)
    }

    @Test func aLongFirstAskIsCutSoItsClosingQuoteShows() {
        #expect(presenter.quoted("Add retry to the image generation call") == "\"Add retry to the image gener…\"")
        #expect(presenter.quoted("Short") == "\"Short\"")
    }
}
