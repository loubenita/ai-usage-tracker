import Foundation
import Testing
@testable import UsageDomain

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private let video = WorkTag(project: "Marketing Studio", concern: "Video generation")
private let image = WorkTag(project: "Marketing Studio", concern: "Image generation")
private let bugs = WorkTag(project: "OpenKitchen", concern: "Bug fixes")

private func turn(
    _ tag: WorkTag,
    _ cost: String?,
    tokens: TokenUsage? = TokenUsage(input: 100),
    model: ModelName = "claude-opus-5",
    at date: Date = base
) -> Turn {
    Turn(
        id: UUID().uuidString, timestamp: date, agent: .claudeCode, sessionID: tag.concern, model: model,
        work: Work(tag: tag), tokens: tokens, cost: Cost(usd: cost.flatMap { Decimal(string: $0) }),
        context: nil
    )
}

@Suite("Shares and percentages")
struct ShareTests {
    @Test func everyPercentageInTheDesign() throws {
        // Today's spend: $4.20 of a $9 budget, tokens 1.2M of 2.6M.
        #expect(abs(try #require(Share.of(Decimal(string: "4.20")!, in: 9)) - 0.46667) < 0.00001)
        #expect(abs(try #require(Share.of(1_200_000, in: 2_600_000)) - 0.46154) < 0.00001)
        // Context: 68k of a 200k window.
        #expect(try #require(Share.of(68_000, in: 200_000)) == 0.34)
        // The image session's $1.10 of today's $4.20.
        #expect(abs(try #require(Share.of(Decimal(string: "1.10")!, in: Decimal(string: "4.20")!)) - 0.26190) < 0.00001)
    }

    @Test func isUnknownForAnEmptyWhole() {
        #expect(Share.of(Decimal(1), in: 0) == nil)
        #expect(Share.of(1, in: 0) == nil)
    }
}

@Suite("Each session's share of spend")
struct BreakdownTests {
    @Test func groupsSpendByWorkBiggestFirst() {
        let turns = [
            turn(image, "0.60"), turn(video, "2.10"), turn(image, "0.50"), turn(bugs, "1.00"),
        ]
        let spends = Breakdown.byWork(turns)
        #expect(spends.map(\.tag) == [video, image, bugs])
        #expect(spends.map(\.costUSD) == [Decimal(string: "2.10")!, Decimal(string: "1.10")!, 1])
        #expect(spends.map { ($0.shareOfSpend * 1000).rounded() / 1000 } == [0.5, 0.262, 0.238])
        #expect(abs(spends.map(\.shareOfSpend).reduce(0, +) - 1) < 1e-12)
    }

    @Test func unpricedTurnsCountAsNoSpend() {
        let spends = Breakdown.byWork([turn(video, nil), turn(bugs, "1.00")])
        #expect(spends.first { $0.tag == video }?.shareOfSpend == 0)
        #expect(spends.first { $0.tag == bugs }?.shareOfSpend == 1)
    }

    @Test func groupsByModelMostTokensFirst() {
        let turns = [
            turn(video, "0.60", tokens: TokenUsage(input: 300_000), model: "claude-sonnet-5"),
            turn(video, "3.60", tokens: TokenUsage(input: 900_000), model: "claude-opus-5"),
        ]
        let models = Breakdown.byModel(turns)
        #expect(models.map(\.model.displayName) == ["Opus 5", "Sonnet 5"])
        #expect(models.map(\.tokens) == [900_000, 300_000])
    }

    @Test func modelsWithNoTokensAreLeftOutAndUnknownCostStaysUnknown() {
        let turns = [
            turn(video, nil, tokens: TokenUsage(input: 500), model: "gpt-5.6-sol"),
            turn(video, nil, tokens: TokenUsage(input: 0, output: 0), model: "<synthetic>"),
            turn(video, "1.00", tokens: TokenUsage(input: 100), model: "claude-opus-5"),
        ]
        let models = Breakdown.byModel(turns)
        #expect(models.map(\.model.id) == ["gpt-5.6-sol", "claude-opus-5"])
        #expect(models.map(\.costUSD) == [nil, Decimal(1)])
    }

    @Test func dailyTotalsIncludeEmptyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: base).addingTimeInterval(12 * 3600)
        let twoDaysAgo = today.addingTimeInterval(-2 * 86_400)
        let days = Breakdown.daily(
            [turn(video, "1.00", tokens: TokenUsage(input: 5), at: twoDaysAgo), turn(video, "2.00", at: today)],
            days: 3, endingAt: today, calendar: calendar
        )
        #expect(days.map(\.tokens) == [5, 0, 100])
        #expect(days.map(\.costUSD) == [1, 0, 2])
    }
}

@Suite("Tokens")
struct TokenUsageTests {
    @Test func nullIsNotZero() {
        #expect(TokenUsage().total == nil)
        #expect(TokenUsage(input: 0).total == 0)
        let sum = TokenUsage(input: 5, reasoning: nil) + TokenUsage(input: 1, output: 2)
        #expect(sum == TokenUsage(input: 6, output: 2))
        #expect(TokenUsage.sum(nil, nil) == nil)
        #expect(TokenUsage.sum(nil, TokenUsage(output: 3)) == TokenUsage(output: 3))
    }

    @Test func sessionTotalAddsEveryField() {
        #expect(TokenUsage(input: 52_000, output: 14_000, cacheRead: 200_000, cacheWrite: 14_000).total == 280_000)
    }
}

@Suite("Names")
struct NamingTests {
    @Test func shortNames() {
        #expect(video.projectShortName == "MS")
        #expect(bugs.projectShortName == "OpenKitchen")
        #expect(video.concernCode() == "VID")
        #expect(bugs.concernCode() == "BUG")
        #expect(image.concernCode() == "IMA")
        #expect(image.concernCode(labels: ["Image generation": "IMG"]) == "IMG")
        #expect(ModelName("claude-opus-5").displayName == "Opus 5")
        #expect(ModelName("gpt-5.6-sol").displayName == "gpt-5.6-sol")
        #expect(ModelName("claude-haiku-4-5-20251001").displayName == "Haiku 4.5")
        #expect(ModelName("claude-opus-4-8").displayName == "Opus 4.8")
        #expect(ModelName("claude-fable-5-1").displayName == "Fable 5.1")
        #expect(ModelName("<synthetic>").displayName == "<synthetic>")
    }
}
