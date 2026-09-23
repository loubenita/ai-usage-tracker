import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// The fake data must add up to the Paper frames' numbers, so the panels agree with each other.
@Suite("Fake data agrees with the brief")
struct FakeUsageRepositoryTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    func report() async throws -> UsageReport {
        let repository = FakeUsageRepository(calendar: calendar)
        let generate = GenerateUsageReport(settings: try await repository.settings(), calendar: calendar)
        let range = generate.recordRange(endingAt: repository.anchor)
        let records = try await repository.records(from: range.start, to: range.end)
        return generate(records, now: repository.anchor)
    }

    @Test func threeSessionsInStripOrder() async throws {
        let sessions = try await report().sessions
        #expect(sessions.map(\.code) == ["VID", "IMG", "BUG"])
        #expect(sessions.map(\.summary.agent) == [.claudeCode, .claudeCode, .codex])
        #expect(sessions.map { $0.summary.tokens?.total } == [640_000, 280_000, 1_100_000])
        #expect(sessions.map { Int($0.summary.activeDuration / 60) } == [107, 23, 58])
        #expect(sessions.map { $0.summary.context?.used } == [142_000, 68_000, 184_000])
        #expect(sessions.map(\.isContextNearlyFull) == [false, false, true])
        #expect(sessions.map(\.summary.needsUser) == [false, true, false])
    }

    @Test func imageGenerationDetails() async throws {
        let sessions = try await report().sessions
        let image = try #require(sessions.first { $0.code == "IMG" })
        let summary = image.summary
        #expect(summary.costUSD == Decimal(string: "1.10"))
        #expect(summary.tokens == TokenUsage(input: 52_000, output: 14_000, cacheRead: 200_000, cacheWrite: 14_000))
        #expect(summary.tokens?.total == 280_000)
        #expect(summary.turnCount == 18)
        #expect(summary.model?.displayName == "Opus 5")
        #expect(summary.work.branch == "feat/image-gen-v2")
        #expect(summary.idleDuration == 4 * 60)
        let started = calendar.dateComponents([.hour, .minute], from: summary.startedAt)
        #expect(started.hour == 14 && started.minute == 5)
    }

    @Test func todayTotals() async throws {
        let report = try await report()
        let today = report.today
        // Claude's $4.20 and Codex's $1.35; Cursor reports no cost or tokens.
        #expect(today.costUSD == Decimal(string: "5.55"))
        #expect(today.costBudget == 9)
        #expect(today.totalTokens == 1_610_000)
        #expect(today.tokenBudget == 2_600_000)
        #expect(today.byWork.map(\.costUSD) == [Decimal(string: "2.10")!, Decimal(string: "2.10")!, Decimal(string: "1.35")!, 0])
        #expect(today.byModel.map(\.tokens) == [613_000, 546_000, 410_000, 41_000])
        let claude = try #require(report.periods[.today]?.usage(of: .claudeCode))
        #expect(claude.tokens == 1_200_000)
        #expect(claude.costUSD == Decimal(string: "4.20"))
        #expect(claude.workingTime == (4 * 60 + 10) * 60)
    }

    @Test func aSessionOnWorkOfItsOwnCostsWhatItsRowDoes() async throws {
        let report = try await report()
        // Video generation had no other session today; Image generation had one this morning.
        let video = try #require(report.sessions.first { $0.code == "VID" })
        let row = try #require(report.today.byWork.first { $0.tag == video.summary.work.tag })
        #expect(row.costUSD == video.summary.costUSD)
        #expect(row.shareOfSpend == video.shareOfTodaysSpend)
    }

    @Test func weekTotals() async throws {
        let report = try await report()
        // Every agent: Claude's 12.2M and $31.40, and Codex's 1.1M and $3.60 since last night.
        let week = report.week
        #expect(week.totalTokens == 13_300_000)
        #expect(week.costUSD == Decimal(string: "35.00"))
        #expect(week.days.map(\.tokens) == [
            1_800_000, 2_400_000, 3_100_000, 2_200_000, 600_000, 1_590_000, 1_610_000,
        ])
        // Claude alone, as frame 5 shows it.
        let claude = try #require(report.periods[.week]?.usage(of: .claudeCode))
        #expect(claude.tokens == 12_200_000)
        #expect(claude.costUSD == Decimal(string: "31.40"))
        #expect(claude.sessionCount == 14)
        #expect(report.periods[.week]?.byAgent[.claudeCode]?.buckets.map(\.tokens) == [
            1_800_000, 2_400_000, 3_100_000, 2_200_000, 600_000, 900_000, 1_200_000,
        ])
    }

    @Test func cursorsMonthIsPromptsAndToolCallsWithNoTokens() async throws {
        let cursor = try #require(try await report().periods[.month]?.usage(of: .cursor))
        #expect(cursor.tokens == nil)
        #expect(cursor.costUSD == nil)
        #expect(cursor.turnCount == 212)
        #expect(cursor.toolCalls == 1_480)
        #expect(cursor.sessionCount == 9)
    }

    @Test func limits() async throws {
        let report = try await report()
        #expect(report.fiveHour?.usedPercent == 62)
        #expect(report.fiveHour?.percentPerHour == 23)
        #expect(report.weekly?.usedPercent == 48)
        #expect(report.weekly?.calendarDaysLeft == 3)
        // Claude has no monthly window; Codex's week is at 95%.
        #expect(report.monthly == nil)
        #expect(report.limits(for: .codex).weekly?.usedPercent == 95)
    }

    @Test func recordsOutsideTheRangeAreLeftOut() async throws {
        let repository = FakeUsageRepository(calendar: calendar)
        let records = try await repository.records(from: repository.anchor.addingTimeInterval(-3600), to: repository.anchor)
        #expect(records.turns.allSatisfy { $0.timestamp >= repository.anchor.addingTimeInterval(-3600) })
        // Claude's 5-hour reading an hour ago, and Claude's and Codex's now.
        #expect(records.limits.count == 3)
    }

    @Test func fakeClockStartsAtTheAnchorAndRuns() {
        let anchor = FakeUsageRepository(calendar: calendar).anchor
        let clock = FakeTimeSource(start: anchor, launchedAt: Date().addingTimeInterval(-90))
        #expect(abs(clock.now.timeIntervalSince(anchor) - 90) < 1)
    }
}
