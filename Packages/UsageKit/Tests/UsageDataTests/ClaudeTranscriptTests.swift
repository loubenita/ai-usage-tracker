import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// The fixture is the first 41 conversation lines of a real transcript on this Mac, with the
/// message text removed. Expected totals were worked out separately with a Python script.
@Suite("Usage from a Claude Code transcript")
struct ClaudeTranscriptTests {
    func transcript() throws -> ClaudeTranscript {
        var transcript = ClaudeTranscript()
        for line in try Fixture.text("claude-transcript.jsonl").split(separator: "\n") {
            transcript.consume(line)
        }
        return transcript
    }

    @Test func countsEachReplyOnceByMessageID() throws {
        // 20 assistant lines, but only 9 replies.
        let replies = try transcript().replies
        #expect(replies.count == 9)
        #expect(Set(replies.map(\.id)).count == 9)
    }

    @Test func addsUpTokensWithoutCountingRepeatsTwice() throws {
        let replies = try transcript().replies
        #expect(replies.reduce(0) { $0 + $1.input } == 18)
        // Counting every line would give 5,511.
        #expect(replies.reduce(0) { $0 + $1.output } == 2_718)
        #expect(replies.reduce(0) { $0 + $1.cacheRead } == 737_212)
        #expect(replies.reduce(0) { $0 + $1.cacheWriteOneHour } == 46_057)
        #expect(replies.reduce(0) { $0 + $1.cacheWriteFiveMinute } == 0)
    }

    @Test func costsTheSessionAtOpus5Prices() throws {
        let turns = try transcript().turns(sessionID: "s", work: Work(tag: WorkTag(project: "p", concern: "c")))
        let total = turns.compactMap(\.cost.usd).reduce(0, +)
        #expect(total == Decimal(string: "0.897216"))
    }

    @Test func contextIsEverythingTheLastReplyRead() throws {
        let turns = try transcript().turns(sessionID: "s", work: Work(tag: WorkTag(project: "p", concern: "c")))
        #expect(turns.last?.context == ContextUsage(used: 288_208, window: 1_000_000))
        #expect(turns.last?.model.displayName == "Opus 5")
    }

    @Test func remembersWhoSpokeLast() throws {
        #expect(try transcript().lastSpeaker == .agent(stopReason: "end_turn"))
    }

    @Test func leavesOutSubAgentLinesAndJunk() {
        var transcript = ClaudeTranscript()
        transcript.consume(#"{"type":"assistant","isSidechain":true,"timestamp":"2026-09-21T21:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":5}}}"#)
        transcript.consume("not json")
        #expect(transcript.replies.isEmpty)
    }

    @Test func aUnknownModelHasNoCostRatherThanAGuess() {
        var transcript = ClaudeTranscript()
        transcript.consume(#"{"type":"assistant","timestamp":"2026-09-21T21:00:00.000Z","message":{"id":"m1","model":"<synthetic>","usage":{"input_tokens":5,"output_tokens":5}}}"#)
        let turns = transcript.turns(sessionID: "s", work: Work(tag: WorkTag(project: "p", concern: "c")))
        #expect(turns.first?.cost.usd == nil)
        #expect(turns.first?.context == nil)
    }
}

@Suite("Model prices")
struct ModelPriceTests {
    @Test func pricesEachKindOfToken() throws {
        let opus = try #require(ClaudePrices.price(for: "claude-opus-5"))
        // 1M of each: $5 input, $25 output, $0.50 read, $6.25 5-minute write, $10 1-hour write.
        let million = 1_000_000
        #expect(opus.cost(input: million, output: 0, cacheRead: 0, cacheWriteFiveMinute: 0, cacheWriteOneHour: 0) == 5)
        #expect(opus.cost(input: 0, output: million, cacheRead: 0, cacheWriteFiveMinute: 0, cacheWriteOneHour: 0) == 25)
        #expect(opus.cost(input: 0, output: 0, cacheRead: million, cacheWriteFiveMinute: 0, cacheWriteOneHour: 0) == Decimal(string: "0.5"))
        #expect(opus.cost(input: 0, output: 0, cacheRead: 0, cacheWriteFiveMinute: million, cacheWriteOneHour: 0) == Decimal(string: "6.25"))
        #expect(opus.cost(input: 0, output: 0, cacheRead: 0, cacheWriteFiveMinute: 0, cacheWriteOneHour: million) == 10)
    }

    @Test func picksTheRightModel() {
        #expect(ClaudePrices.price(for: "claude-fable-5-1")?.cacheRead == Decimal(string: "0.25"))
        #expect(ClaudePrices.price(for: "claude-fable-5")?.cacheRead == 1)
        #expect(ClaudePrices.price(for: "claude-haiku-4-5-20251001")?.contextWindow == 200_000)
        #expect(ClaudePrices.price(for: "gpt-5") == nil)
    }
}

@Suite("Working, waiting for you, or idle")
struct ClaudeSessionStateTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func busyIsWorking() {
        #expect(ClaudeSessionState.make(fileStatus: "busy", statusChangedAt: now - 3600, lastSpeaker: nil, lastActivity: nil, now: now) == .working)
    }

    @Test func recentlyStoppedIsWaitingForYou() {
        #expect(ClaudeSessionState.make(fileStatus: "idle", statusChangedAt: now - 60, lastSpeaker: nil, lastActivity: nil, now: now) == .waiting)
    }

    @Test func stoppedForHalfAnHourIsIdle() {
        #expect(ClaudeSessionState.make(fileStatus: "idle", statusChangedAt: now - 30 * 60, lastSpeaker: nil, lastActivity: nil, now: now) == .idle)
    }

    @Test func withoutAStatusTheTranscriptDecides() {
        let finished = ClaudeTranscript.LastSpeaker.agent(stopReason: "end_turn")
        #expect(ClaudeSessionState.make(fileStatus: nil, statusChangedAt: nil, lastSpeaker: finished, lastActivity: now - 60, now: now) == .waiting)
        #expect(ClaudeSessionState.make(fileStatus: nil, statusChangedAt: nil, lastSpeaker: .agent(stopReason: "tool_use"), lastActivity: now, now: now) == .working)
        #expect(ClaudeSessionState.make(fileStatus: nil, statusChangedAt: nil, lastSpeaker: .person, lastActivity: now, now: now) == .working)
    }
}

@Suite("Reading only what a transcript added")
struct TranscriptStoreTests {
    @Test func readsNewLinesAndFinishesAHalfWrittenOne() throws {
        let path = NSTemporaryDirectory() + "transcript-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = #"{"type":"assistant","timestamp":"2026-09-21T21:00:00.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":10}}}"#
        let second = #"{"type":"assistant","timestamp":"2026-09-21T21:01:00.000Z","message":{"id":"m2","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":20}}}"#
        let store = TranscriptStore()

        try Data((first + "\n" + second.prefix(40)).utf8).write(to: URL(fileURLWithPath: path))
        #expect(store.transcript(at: path)?.replies.map(\.id) == ["m1"])

        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((second.dropFirst(40) + "\n").utf8))
        try handle.close()
        #expect(store.transcript(at: path)?.replies.map(\.output) == [10, 20])
    }
}
