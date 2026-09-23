import Foundation
import Testing
@testable import UsageDomain

private let minute: TimeInterval = 60
private let hour: TimeInterval = 3600
private let now = Date(timeIntervalSince1970: 1_790_000_000)

@Suite("Tokens per hour")
struct TokenRateTests {
    @Test func dividesTokensByActiveHours() throws {
        // 280k tokens in 23 active minutes is about 730k an hour.
        let rate = try #require(TokenRate.perHour(tokens: 280_000, over: 23 * minute))
        #expect(abs(rate - 730_434.78) < 0.01)
    }

    @Test func isUnknownWithoutActiveTime() {
        #expect(TokenRate.perHour(tokens: 1_000, over: 0) == nil)
        #expect(TokenRate.perHour(tokens: 1_000, over: -5) == nil)
    }

    @Test func comparesWithTheUsualRate() throws {
        let ratio = try #require(TokenRate.comparedWithUsual(730_000, usual: 365_000))
        #expect(ratio == 2)
        #expect(TokenRate.comparedWithUsual(730_000, usual: 0) == nil)
    }
}

/// A reply `minutes` before `now`, with the tokens and context given.
private func reply(
    _ minutesBefore: Double, tokens: TokenUsage? = nil, context: Int? = nil, window: Int = 200_000
) -> Turn {
    Turn(
        id: "r\(minutesBefore)", timestamp: now.addingTimeInterval(-minutesBefore * minute), agent: .claudeCode,
        sessionID: "s", model: "claude-opus-5", work: Work(tag: WorkTag(project: "p", concern: "c")),
        tokens: tokens, cost: Cost(usd: nil), context: context.map { ContextUsage(used: $0, window: window) }
    )
}

@Suite("Working time")
struct WorkingTimeTests {
    @Test func addsTheGapsBetweenRepliesAndSkipsLongPauses() {
        // 0, 1 and 3 minutes, then a 20-minute pause, then 2 minutes more: 3 + 2 = 5 minutes.
        let times = [0.0, 1, 3, 23, 25].map { now.addingTimeInterval($0 * minute) }
        #expect(WorkingTime.of(times.shuffled()) == 5 * minute)
    }

    @Test func isZeroForOneReply() {
        #expect(WorkingTime.of([now]) == 0)
        #expect(WorkingTime.of([]) == 0)
    }
}

@Suite("A session's pace")
struct TokenPaceTests {
    @Test func leavesCacheReadsOut() throws {
        // Three replies a minute apart; cache reads of 10M are left out of the pace, so
        // 3 × (1k input + 2k output + 1k cache write) = 12k tokens in 2 working minutes is 360k an hour.
        let usage = TokenUsage(input: 1_000, output: 2_000, cacheRead: 10_000_000, cacheWrite: 1_000)
        let rate = try #require(TokenPace.perWorkingHour([reply(2, tokens: usage), reply(1, tokens: usage), reply(0, tokens: usage)]))
        #expect(rate == 360_000)
    }

    @Test func pausesDoNotSlowThePace() throws {
        let usage = TokenUsage(input: 1_000, output: 1_000)
        // Two working stretches of 2 minutes each, an hour apart: 12k tokens in 4 working minutes.
        let turns = [64.0, 63, 62, 2, 1, 0].map { reply($0, tokens: usage) }
        let rate = try #require(TokenPace.perWorkingHour(turns))
        #expect(rate == 180_000)
    }

    @Test func isUnknownWithUnderTwoWorkingMinutes() {
        #expect(TokenPace.perWorkingHour([reply(1, tokens: TokenUsage(output: 5)), reply(0, tokens: TokenUsage(output: 5))]) == nil)
    }
}

@Suite("The owner's usual pace")
struct UsualRateTests {
    @Test func weighsSessionsByTheirWorkingTime() throws {
        // One session: 60 working minutes at 1k tokens a minute. Another: 30 minutes at 4k.
        // Together 180k tokens in 1.5 hours is 120k an hour, not the 150k average of the two paces.
        let long = (0...60).map { reply(Double($0), tokens: TokenUsage(output: $0 == 60 ? 0 : 1_000)) }
        let short = (0...30).map { reply(Double(200 + $0), tokens: TokenUsage(output: $0 == 30 ? 0 : 4_000)) }
        let usual = try #require(UsualRate.make(sessions: [long, short]))
        #expect(usual.tokensPerHour == 120_000)
        #expect(usual.workingTime == 90 * minute)
    }

    @Test func needsAnHourOfWork() {
        let turns = (0...30).map { reply(Double($0), tokens: TokenUsage(output: 1_000)) }
        #expect(UsualRate.make(sessions: [turns]) == nil)
        #expect(UsualRate.make(sessions: []) == nil)
    }
}

@Suite("When context will be full")
struct ContextForecastTests {
    @Test func projectsTheContextsGrowthForward() throws {
        // 20k to 80k in 10 working minutes is 360k an hour; the 120k left takes 20 minutes.
        let turns = (0...10).map { reply(Double(10 - $0), context: 20_000 + $0 * 6_000) }
        let full = try #require(ContextForecast.timeFull(turns, now: now))
        #expect(abs(full.timeIntervalSince(now) - 20 * minute) < 0.001)
    }

    @Test func ignoresTotalTokens() throws {
        // Huge token counts with a context that grows as above: the same 20 minutes.
        let turns = (0...10).map {
            reply(Double(10 - $0), tokens: TokenUsage(cacheRead: 5_000_000), context: 20_000 + $0 * 6_000)
        }
        let full = try #require(ContextForecast.timeFull(turns, now: now))
        #expect(abs(full.timeIntervalSince(now) - 20 * minute) < 0.001)
    }

    @Test func measuresAgainAfterACompaction() throws {
        // Grew 10k a minute to 190k, compacted to 30k, then grew 6k a minute for 5 minutes to 60k:
        // 360k an hour since the compaction, so the 140k left takes about 23 minutes, where the
        // growth before it would have given 14.
        let before = (0...5).map { reply(Double(30 - $0), context: 140_000 + $0 * 10_000) }
        let after = (0...5).map { reply(Double(5 - $0), context: 30_000 + $0 * 6_000) }
        let full = try #require(ContextForecast.timeFull(before + after, now: now))
        #expect(abs(full.timeIntervalSince(now) - 140_000.0 / 360_000 * hour) < 0.001)
    }

    @Test func isNowWhenAlreadyFull() {
        #expect(ContextForecast.timeFull([reply(0, context: 200_000)], now: now) == now)
    }

    @Test func isUnknownWhenTheContextHasNotGrownOrThereIsTooLittleWork() {
        let flat = (0...10).map { reply(Double($0), context: 50_000) }
        #expect(ContextForecast.timeFull(flat, now: now) == nil)
        #expect(ContextForecast.timeFull([reply(1, context: 10_000), reply(0, context: 20_000)], now: now) == nil)
        #expect(ContextForecast.timeFull([], now: now) == nil)
    }

    @Test func fractionIsClampedToTheWindow() {
        #expect(ContextUsage(used: 68_000, window: 200_000).fraction == 0.34)
        #expect(ContextUsage(used: 250_000, window: 200_000).fraction == 1)
        #expect(ContextUsage(used: 5, window: 0).fraction == 0)
    }
}

@Suite("How far over budget the day will end")
struct DayProjectionTests {
    @Test func projectsTodaysRateToTheEndOfTheDay() throws {
        // 1.2M tokens between 10:42 and 14:32, carried on to 20:00, against a 2.6M budget.
        let firstActivity = now.addingTimeInterval(-(3 * hour + 50 * minute))
        let dayEnd = now.addingTimeInterval(5 * hour + 28 * minute)
        let projection = try #require(
            DayProjection.make(
                tokensSoFar: 1_200_000, firstActivity: firstActivity, now: now, dayEnd: dayEnd, budget: 2_600_000
            )
        )
        #expect(abs(projection.tokensPerHour - 313_043.48) < 0.01)
        #expect(projection.projectedTokens == 2_911_304)
        #expect(abs(try #require(projection.overBudgetFraction) - 0.11973) < 0.0001)
        #expect(projection.isOverBudget)
    }

    @Test func withoutABudgetStillProjectsButComparesNothing() throws {
        let projection = try #require(
            DayProjection.make(
                tokensSoFar: 100_000, firstActivity: now.addingTimeInterval(-hour), now: now,
                dayEnd: now.addingTimeInterval(hour), budget: nil
            )
        )
        #expect(projection.projectedTokens == 200_000)
        #expect(projection.overBudgetFraction == nil)
        #expect(!projection.isOverBudget)
        let zero = DayProjection.make(
            tokensSoFar: 100_000, firstActivity: now.addingTimeInterval(-hour), now: now,
            dayEnd: now.addingTimeInterval(hour), budget: 0
        )
        #expect(zero?.overBudgetFraction == nil)
    }

    @Test func isNegativeWhenUnderBudget() throws {
        let projection = try #require(
            DayProjection.make(
                tokensSoFar: 100_000, firstActivity: now.addingTimeInterval(-hour), now: now,
                dayEnd: now.addingTimeInterval(hour), budget: 1_000_000
            )
        )
        #expect(projection.projectedTokens == 200_000)
        #expect(abs(try #require(projection.overBudgetFraction) - -0.8) < 1e-9)
        #expect(!projection.isOverBudget)
    }

    @Test func stopsAtTheEndOfTheDay() throws {
        let projection = try #require(
            DayProjection.make(
                tokensSoFar: 500_000, firstActivity: now.addingTimeInterval(-hour), now: now,
                dayEnd: now.addingTimeInterval(-hour), budget: 1_000_000
            )
        )
        #expect(projection.projectedTokens == 500_000)
    }

    @Test func isUnknownWithoutElapsedTime() {
        #expect(DayProjection.make(tokensSoFar: 1, firstActivity: now, now: now, dayEnd: now, budget: 10) == nil)
    }
}
