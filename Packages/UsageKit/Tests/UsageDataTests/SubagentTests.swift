import Foundation
import Testing
@testable import UsageData
@testable import UsageDomain

/// A session's sub-agents: read from their own transcripts, counted once per reply, folded
/// into the session's spend and tokens, and never into its pace.
@Suite("Sub-agents")
struct SubagentTests {
    let work = Work(tag: WorkTag(project: "p", concern: "c"))
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// One assistant line of a sub-agent's transcript: every line of a reply repeats its usage.
    func line(_ id: String, second: Int, model: String = "claude-sonnet-5", input: Int = 1_000, output: Int = 100) -> String {
        let time = ISO8601DateFormatter.string(
            from: start + Double(second), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        return #"{"type":"assistant","isSidechain":true,"agentId":"a1","timestamp":"\#(time)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"content":[{"type":"text"}]}}"#
    }

    @Test func aReplySplitAcrossLinesIsCountedOnce() throws {
        var transcript = ClaudeTranscript(includeSidechains: true)
        // Three lines of one reply, then a second reply two minutes later.
        for text in [line("m1", second: 0), line("m1", second: 0), line("m1", second: 0), line("m2", second: 120)] {
            transcript.consume(Substring(text))
        }
        let run = try #require(SubagentRun.make(id: "agent-a1", turns: transcript.turns(sessionID: "agent-a1", work: work)))
        #expect(run.tokens?.total == 2_200)
        #expect(run.model == "claude-sonnet-5")
        #expect(run.workingTime == 120)
        // Sonnet 5 at API prices: priced, not left blank.
        #expect(run.costUSD != nil)
        #expect(SubagentRun.make(id: "empty", turns: []) == nil)
    }

    /// A session with three of its own replies and the given sub-agent runs.
    func summary(ownCost: Decimal?, runs: [SubagentRun]) throws -> SessionSummary {
        let tag = work.tag
        let turns = (0..<3).map { index in
            Turn(
                id: "t\(index)", timestamp: start + Double(index) * 60, agent: .claudeCode, sessionID: "s",
                model: "claude-opus-5", work: work, tokens: TokenUsage(input: 1_000, output: 1_000),
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
        return try #require(SessionSummaries.make(turns: turns, events: events, now: start + 180).first)
    }

    @Test func theSessionsSpendAndTokensIncludeItsSubagents() throws {
        let runs = [
            SubagentRun(id: "a", model: "claude-sonnet-5", tokens: TokenUsage(input: 3_000), costUSD: 1, workingTime: 60),
            SubagentRun(id: "b", model: "claude-haiku-4-5", tokens: TokenUsage(input: 1_000), costUSD: 0.5, workingTime: 30),
        ]
        let with = try summary(ownCost: 1, runs: runs)
        // Its own three replies at $1 and 2,000 tokens each, and the two runs.
        #expect(with.costUSD == Decimal(string: "4.5"))
        #expect(with.tokens?.total == 10_000)
        #expect(with.subagentCostUSD == Decimal(string: "1.5"))
        #expect(with.subagentTokens == 4_000)
        #expect(with.turnCount == 3)

        let without = try summary(ownCost: 1, runs: [])
        #expect(without.costUSD == 3)
        #expect(without.subagents.isEmpty)
        #expect(without.subagentCostUSD == nil)
    }
}
