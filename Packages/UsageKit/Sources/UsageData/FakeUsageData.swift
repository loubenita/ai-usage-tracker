import Foundation
import UsageDomain

/// The made-up month behind the overlay. Every total is chosen so the calculated numbers
/// match the Paper frames (Overlay page, frames 1 to 7) and agree across the panels:
///
/// | Today | Agent | Tokens | Cost | Time |
/// |---|---|---|---|---|
/// | MS · Video generation | Claude | 640k | $2.10 | 2h 38m |
/// | MS · Image generation (two sessions) | Claude | 280k + 280k | $1.10 + $1.00 | 22m + 1h 10m |
///
/// The open Image generation session's 280k and $1.10 include its six sub-agents: 137k and $0.34.
/// | OpenKitchen · Bug fixes | Codex | 410k (1.1M with yesterday) | $1.35 | 1h 20m |
/// | OpenKitchen · iOS | Cursor | not reported | not reported | 30m |
///
/// So Claude has 1.2M tokens, $4.20 and 4h 10m today. The six days before add 11.0M tokens,
/// $27.20 and 17h 55m over 11 Claude sessions, so Claude's week is 12.2M, $31.40, 22h 05m and
/// 14 sessions. Cursor reports no tokens or cost, only its prompts, tool calls and times.
struct FakeUsageData {
    static let settings = UsageSettings(
        dailyCostBudget: 9,
        dailyTokenBudget: 2_600_000,
        workdayEndHour: 20,
        concernLabels: ["Video generation": "VID", "Image generation": "IMG", "Bug fixes": "BUG"]
    )

    static let opus: ModelName = "claude-opus-5"
    static let sonnet: ModelName = "claude-sonnet-5"
    static let haiku: ModelName = "claude-haiku-4-5-20251001"
    static let gpt: ModelName = "gpt-5.6"
    static let cursorAuto: ModelName = "Auto"
    static let contextWindow = 200_000

    static let video = WorkTag(project: "Marketing Studio", concern: "Video generation")
    static let image = WorkTag(project: "Marketing Studio", concern: "Image generation")
    static let bugs = WorkTag(project: "OpenKitchen", concern: "Bug fixes")

    static let videoWork = Work(
        tag: video,
        taggedBy: "rule:ms-video",
        repoRemote: "github.com/acme/marketing-studio",
        branch: "feat/render-retry",
        folder: "/Users/me/wt/ms-render-retry"
    )
    static let imageWork = Work(
        tag: image,
        taggedBy: "rule:ms-image",
        repoRemote: "github.com/acme/marketing-studio",
        // No folder, so the session keeps the design's title, "Image generation".
        branch: "feat/image-gen-v2"
    )
    static let bugsWork = Work(
        tag: bugs,
        taggedBy: "rule:ok-bugs",
        repoRemote: "github.com/acme/openkitchen",
        branch: "fix/checkout-rounding",
        folder: "/Users/me/wt/ok-bug-fixes"
    )
    static let cursorWork = [
        Work(tag: WorkTag(project: "OpenKitchen", concern: "iOS")),
        Work(tag: WorkTag(project: "Website", concern: "Website")),
        Work(tag: WorkTag(project: "OpenKitchen", concern: "Docs")),
        Work(tag: WorkTag(project: "OpenKitchen", concern: "Payments")),
    ]

    let calendar: Calendar

    /// Monday 21 September 2026, 14:32 in the calendar's time zone.
    var now: Date { at(dayOffset: 0, 14, 32) }

    func records() -> UsageRecords {
        UsageRecords(
            turns: todaysTurns() + codexTurns() + earlierTurns() + cursorTurns(),
            limits: limits(),
            sessionEvents: sessionEvents(),
            capturedAt: now,
            usualRates: [.claudeCode: Self.usualRate]
        )
    }

    /// A made-up usual pace, half the Image generation session's 218k tokens a working hour.
    static let usualRate = UsualRate(tokensPerHour: 110_000, workingTime: 20 * 3600)

    // MARK: - Today

    private func todaysTurns() -> [Turn] {
        // 10:42 to 13:20 with a reply at most 5 minutes apart: 2h 38m of work.
        let video = withGrowingContext(
            TurnBatch(
                sessionID: "s_vid", work: Self.videoWork, model: Self.opus, count: 40,
                from: at(dayOffset: 0, 10, 42), to: at(dayOffset: 0, 13, 20),
                tokens: TokenUsage(input: 80_000, output: 25_000, cacheRead: 335_000, cacheWrite: 30_000),
                cost: Decimal(string: "1.90")!
            ).turns(calendar: calendar)
            + TurnBatch(
                sessionID: "s_vid", work: Self.videoWork, model: Self.sonnet, count: 10,
                from: at(dayOffset: 0, 11, 0), to: at(dayOffset: 0, 13, 0),
                tokens: TokenUsage(input: 30_000, output: 5_000, cacheRead: 125_000, cacheWrite: 10_000),
                cost: Decimal(string: "0.20")!
            ).turns(calendar: calendar),
            finalContext: 142_000
        )

        // Its own replies; its sub-agents' are in `subagentTurns`.
        let image = withGrowingContext(
            TurnBatch(
                sessionID: "s_img", work: Self.imageWork, model: Self.opus, count: 18,
                from: at(dayOffset: 0, 14, 5), to: at(dayOffset: 0, 14, 27),
                tokens: TokenUsage(input: 23_000, output: 6_000, cacheRead: 106_000, cacheWrite: 8_000),
                cost: Decimal(string: "0.76")!
            ).turns(calendar: calendar),
            finalContext: 68_000
        )

        // A session this morning on the same work, closed since.
        let morning = TurnBatch(
            sessionID: "s_img_morning", work: Self.imageWork, model: Self.sonnet, count: 20,
            from: at(dayOffset: 0, 9, 0), to: at(dayOffset: 0, 10, 10),
            tokens: TokenUsage(input: 50_000, output: 14_000, cacheRead: 200_000, cacheWrite: 16_000),
            cost: Decimal(string: "1.00")!
        ).turns(calendar: calendar)

        return video + image + morning + subagentTurns().flatMap(\.turns)
    }

    /// The Image generation session's six sub-agents: four on Sonnet (96k, $0.29, 12 minutes)
    /// and two on Haiku (41k, $0.05, 3 minutes). Their replies count in today's totals, as the
    /// history counts a real session's sub-agents, and their runs show in the session's panel.
    private func subagentTurns() -> [(run: SubagentRun, turns: [Turn])] {
        let runs: [(ModelName, TokenUsage, String, TimeInterval)] = [
            (Self.sonnet, TokenUsage(input: 5_000, output: 1_500, cacheRead: 16_500, cacheWrite: 1_000), "0.08", 180),
            (Self.sonnet, TokenUsage(input: 5_000, output: 1_500, cacheRead: 16_500, cacheWrite: 1_000), "0.07", 180),
            (Self.sonnet, TokenUsage(input: 5_000, output: 1_500, cacheRead: 16_500, cacheWrite: 1_000), "0.07", 180),
            (Self.sonnet, TokenUsage(input: 5_000, output: 1_500, cacheRead: 16_500, cacheWrite: 1_000), "0.07", 180),
            (Self.haiku, TokenUsage(input: 4_500, output: 1_000, cacheRead: 14_000, cacheWrite: 1_000), "0.03", 90),
            (Self.haiku, TokenUsage(input: 4_500, output: 1_000, cacheRead: 14_000, cacheWrite: 1_000), "0.02", 90),
        ]
        return runs.enumerated().map { index, run in
            let (model, tokens, cost, time) = run
            let id = "agent-\(index + 1)"
            // One reply each, filed under a closed session on the same work, so they add no
            // session and no working time of their own to the week's (the history files a real
            // session's sub-agents under the session that started them).
            let turns = TurnBatch(
                sessionID: "s_img_morning", work: Self.imageWork, model: model, count: 1,
                // Six minutes apart, more than the gap that counts as work.
                from: at(dayOffset: 0, 14, index * 6), to: at(dayOffset: 0, 14, index * 6),
                tokens: tokens, cost: Decimal(string: cost)!
            ).turns(calendar: calendar)
            return (
                SubagentRun(id: id, model: model, tokens: tokens, costUSD: Decimal(string: cost)!, workingTime: time),
                turns
            )
        }
    }

    /// The Codex session on Bug fixes: 690k tokens last night and 410k today, 1.1M in all.
    private func codexTurns() -> [Turn] {
        let yesterday = TurnBatch(
            sessionID: "s_bug", work: Self.bugsWork, model: Self.gpt, count: 12, agent: .codex,
            from: at(dayOffset: -1, 20, 0), to: at(dayOffset: -1, 20, 55),
            tokens: TokenUsage(input: 90_000, output: 30_000, cacheRead: 550_000, cacheWrite: 20_000),
            cost: Decimal(string: "2.25")!
        ).turns(calendar: calendar)
        let today = TurnBatch(
            sessionID: "s_bug", work: Self.bugsWork, model: Self.gpt, count: 20, agent: .codex,
            from: at(dayOffset: 0, 13, 10), to: at(dayOffset: 0, 14, 30),
            tokens: TokenUsage(input: 60_000, output: 20_000, cacheRead: 320_000, cacheWrite: 10_000),
            cost: Decimal(string: "1.35")!
        ).turns(calendar: calendar)
        return withGrowingContext(yesterday + today, finalContext: 184_000)
    }

    private func sessionEvents() -> [SessionEvent] {
        func event(
            _ id: String, _ tag: WorkTag, _ kind: SessionEvent.Kind, _ state: SessionState,
            at time: Date, active: TimeInterval, idle: TimeInterval, agent: Agent = .claudeCode,
            origin: SessionOrigin? = nil, snapshot: SessionSnapshot? = nil
        ) -> SessionEvent {
            SessionEvent(
                timestamp: time, agent: agent, sessionID: id, kind: kind, state: state,
                activeDuration: active, idleDuration: idle, work: tag, origin: origin, snapshot: snapshot
            )
        }
        let minute: TimeInterval = 60
        // Listed in the order the strip shows them.
        return [
            event("s_vid", Self.video, .start, .working, at: at(dayOffset: 0, 10, 42), active: 0, idle: 0),
            // Active 1:35 and idle 2:03 at 14:20, so 1:47 active at 14:32.
            event("s_vid", Self.video, .active, .working, at: at(dayOffset: 0, 14, 20),
                  active: 95 * minute, idle: 123 * minute),
            event("s_img", Self.image, .start, .working, at: at(dayOffset: 0, 14, 5), active: 0, idle: 0,
                  origin: SessionOrigin(pid: 0, tty: "ttys003", terminal: .warp, folder: "/Users/me/wt/ms-image-gen")),
            // Stopped at 14:28 to wait for a reply: 0:23 active, then 0:04 idle by 14:32.
            event("s_img", Self.image, .idle, .waiting, at: at(dayOffset: 0, 14, 28), active: 23 * minute, idle: 0,
                  snapshot: SessionSnapshot(
                      effort: "high",
                      activity: SessionActivity(
                          toolCalls: 64, filesChanged: 7, firstAsk: "Add retry to the image generation call"
                      ),
                      subagents: subagentTurns().map(\.run)
                  )),
            event("s_bug", Self.bugs, .start, .working, at: at(dayOffset: 0, 13, 20), active: 0, idle: 0, agent: .codex),
            // Active 0:51 and idle 0:14 at 14:25, so 0:58 active at 14:32.
            event("s_bug", Self.bugs, .active, .working, at: at(dayOffset: 0, 14, 25),
                  active: 51 * minute, idle: 14 * minute, agent: .codex),
        ]
    }

    // MARK: - Earlier this week

    /// One line per piece of work, model and day: (days before today, work, model, tokens, cost).
    /// Lines on the same day and work are one session.
    private static let earlierDays: [(Int, Work, ModelName, Int, String)] = [
        (6, videoWork, opus, 1_200_000, "3.60"),    // Tuesday 1.8M
        (6, bugsWork, sonnet, 600_000, "0.80"),
        (5, imageWork, opus, 1_700_000, "5.10"),    // Wednesday 2.4M
        (5, bugsWork, sonnet, 700_000, "0.90"),
        (4, videoWork, opus, 2_300_000, "6.90"),    // Thursday 3.1M, over the daily budget
        (4, bugsWork, sonnet, 800_000, "1.10"),
        (3, imageWork, opus, 1_400_000, "4.15"),    // Friday 2.2M
        (3, bugsWork, opus, 100_000, "0.35"),
        (3, bugsWork, sonnet, 700_000, "0.90"),
        (2, bugsWork, opus, 300_000, "0.90"),       // Saturday 0.6M
        (2, bugsWork, sonnet, 300_000, "0.40"),
        (1, videoWork, opus, 100_000, "0.30"),      // Sunday 0.9M
        (1, bugsWork, opus, 400_000, "1.20"),
        (1, bugsWork, sonnet, 400_000, "0.60"),
    ]

    /// Each session works 1h 37m 43s, with a reply every 5 minutes at most: 11 sessions make
    /// the week's 17h 55m before today.
    private static let earlierSessionLength: TimeInterval = 1075 * 60 / 11

    private func earlierTurns() -> [Turn] {
        Self.earlierDays.flatMap { line in
            let (daysBefore, work, model, tokens, cost) = line
            let start = at(dayOffset: -daysBefore, 10, 0)
            let batch = TurnBatch(
                sessionID: "s_earlier_\(daysBefore)_\(work.tag.concern)", work: work, model: model, count: 21,
                from: start, to: start.addingTimeInterval(Self.earlierSessionLength),
                tokens: TokenUsage(
                    input: tokens / 5,
                    output: tokens / 20,
                    cacheRead: tokens - tokens / 5 - tokens / 20 - tokens / 20,
                    cacheWrite: tokens / 20
                ),
                cost: Decimal(string: cost)!
            )
            return batch.turns(calendar: calendar)
        }
    }

    // MARK: - Cursor

    /// Cursor's month: prompts with no tokens or cost, each with its tool calls. (days before
    /// today, work, model, prompts, tool calls). A prompt every 5 minutes, so each session's
    /// time is 5 minutes a prompt after the first: 16h 55m in all.
    private static let cursorSessions: [(Int, Int, ModelName, Int, Int)] = [
        (20, 0, cursorAuto, 20, 140),   // 1 Sep
        (18, 1, gpt, 14, 100),
        (13, 0, cursorAuto, 28, 190),   // 8 Sep
        (11, 2, cursorAuto, 22, 150),
        (7, 0, cursorAuto, 40, 280),    // 14 Sep
        (6, 1, gpt, 30, 210),
        (4, 3, cursorAuto, 22, 150),
        (2, 0, cursorAuto, 29, 210),
        (0, 0, cursorAuto, 7, 50),      // today, 30 minutes
    ]

    private func cursorTurns() -> [Turn] {
        Self.cursorSessions.enumerated().flatMap { index, line in
            let (daysBefore, work, model, prompts, toolCalls) = line
            let start = at(dayOffset: -daysBefore, daysBefore == 0 ? 11 : 15, 0)
            return TurnBatch(
                sessionID: "s_cursor_\(index)", work: Self.cursorWork[work], model: model, count: prompts,
                agent: .cursor, from: start, to: start.addingTimeInterval(TimeInterval((prompts - 1) * 5 * 60)),
                tokens: nil, cost: nil, toolCalls: toolCalls
            ).turns(calendar: calendar)
        }
    }

    // MARK: - Limits

    private func limits() -> [LimitReading] {
        let fiveHourReset = at(dayOffset: 0, 16, 40)
        let weeklyReset = at(dayOffset: 3, 9, 0)      // Thursday 24 September, 09:00
        let codexReset = at(dayOffset: 3, 6, 57)      // Thursday 24 September, 06:57
        return [
            // 33% a day ago and 48% now: 15 points a day.
            LimitReading(timestamp: at(dayOffset: -1, 14, 32), agent: .claudeCode, plan: "max", windows: [
                LimitWindowReading(kind: .weekly, usedPercent: 33, resetsAt: weeklyReset),
            ]),
            // 39% an hour ago and 62% now: 23 points an hour.
            LimitReading(timestamp: at(dayOffset: 0, 13, 32), agent: .claudeCode, plan: "max", windows: [
                LimitWindowReading(kind: .fiveHour, usedPercent: 39, resetsAt: fiveHourReset),
            ]),
            LimitReading(timestamp: now, agent: .claudeCode, plan: "max", windows: [
                LimitWindowReading(kind: .fiveHour, usedPercent: 62, resetsAt: fiveHourReset),
                LimitWindowReading(kind: .weekly, usedPercent: 48, resetsAt: weeklyReset),
            ]),
            LimitReading(timestamp: now, agent: .codex, plan: "plus", windows: [
                LimitWindowReading(kind: .weekly, usedPercent: 95, resetsAt: codexReset),
            ]),
        ]
    }

    // MARK: - Helpers

    private func at(dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21))!
        let day = calendar.date(byAdding: .day, value: dayOffset, to: monday)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    /// Gives a session's turns a context that grows steadily to `finalContext` at the last turn.
    private func withGrowingContext(_ turns: [Turn], finalContext: Int) -> [Turn] {
        let sorted = turns.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first?.timestamp, let last = sorted.last?.timestamp else { return [] }
        let span = max(last.timeIntervalSince(first), 1)
        return sorted.map { turn in
            let progress = turn.timestamp.timeIntervalSince(first) / span
            let used = Int((Double(finalContext) * (0.1 + 0.9 * progress)).rounded())
            return Turn(
                id: turn.id, timestamp: turn.timestamp, agent: turn.agent, sessionID: turn.sessionID,
                model: turn.model, work: turn.work, tokens: turn.tokens, cost: turn.cost,
                context: ContextUsage(used: used, window: Self.contextWindow), duration: turn.duration
            )
        }
    }
}

/// Splits a total across `count` evenly spaced turns. Remainders go to the last turn,
/// so the turns add up to the total exactly.
struct TurnBatch {
    let sessionID: String
    let work: Work
    let model: ModelName
    let count: Int
    var agent: Agent = .claudeCode
    let from: Date
    let to: Date
    /// Nil for an agent that reports no tokens (Cursor).
    let tokens: TokenUsage?
    let cost: Decimal?
    var toolCalls: Int?

    func turns(calendar: Calendar) -> [Turn] {
        guard count > 0 else { return [] }
        let step = count > 1 ? to.timeIntervalSince(from) / Double(count - 1) : 0
        let rounded: Decimal? = cost.map { cost in
            var each = cost / Decimal(count)
            var result = Decimal()
            NSDecimalRound(&result, &each, 4, .plain)
            return result
        }

        return (0..<count).map { index in
            let isLast = index == count - 1
            let turnCost = cost.map { cost in isLast ? cost - rounded! * Decimal(count - 1) : rounded! }
            let messageID = "msg_\(sessionID)_\(model.id)_\(index)"
            return Turn(
                id: "\(agent.rawValue):\(messageID)",
                timestamp: from.addingTimeInterval(step * Double(index)),
                agent: agent,
                sessionID: sessionID,
                model: model,
                work: work,
                tokens: tokens.map { tokens in
                    TokenUsage(
                        input: share(of: tokens.input, index: index),
                        output: share(of: tokens.output, index: index),
                        cacheRead: share(of: tokens.cacheRead, index: index),
                        cacheWrite: share(of: tokens.cacheWrite, index: index),
                        reasoning: share(of: tokens.reasoning, index: index)
                    )
                },
                cost: Cost(usd: turnCost, basis: .apiListPrice),
                context: nil,
                duration: 8,
                toolCalls: toolCalls.map { share(of: $0, index: index) ?? 0 }
            )
        }
    }

    private func share(of total: Int?, index: Int) -> Int? {
        guard let total else { return nil }
        let each = total / count
        return index == count - 1 ? total - each * (count - 1) : each
    }
}
