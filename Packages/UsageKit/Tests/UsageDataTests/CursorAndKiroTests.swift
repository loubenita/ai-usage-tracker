import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// `Fixtures/cursor-chat` is a chat database with the tables of a real Cursor chat. Its root
/// entry holds only the real chat's context field, copied byte for byte: 140,454 tokens used
/// of 256,000, as Python read it from the original.
@Suite("Reading a Cursor chat")
struct CursorChatTests {
    static func chatDirectory() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "cursor-chat", withExtension: nil, subdirectory: "Fixtures"))
        return url.path
    }

    @Test func readsTheContextModelAndPrompts() throws {
        let chat = try #require(CursorChat.read(directory: try Self.chatDirectory()))
        #expect(chat.context == ContextUsage(used: 140_454, window: 256_000))
        #expect(chat.model == "grok-4.6")
        #expect(chat.name == "Fixture chat")
        #expect(chat.promptCount == 3)
    }

    @Test func theAutoModelIsNamedAsCursorShowsIt() {
        // A chat on Auto saves its model as "default"; Cursor's own screen says "Auto".
        #expect(CursorChat.modelName("default") == "Auto")
        #expect(CursorChat.modelName("grok-4.6") == "grok-4.6")
        #expect(CursorChat.modelName(nil) == nil)
    }

    @Test func chatsAreFiledUnderTheMD5OfTheirFolder() {
        // The real folder of the home directory's chats on the owner's Mac.
        #expect(CursorChat.chatsDirectory(for: "/Users/me", cursorDirectory: "/c")
            == "/c/chats/b9916cfe2e41b3507facb50b1add4874")
    }

    @Test func aMissingDatabaseReadsAsNothing() {
        #expect(CursorChat.read(directory: "/nonexistent/chat") == nil)
    }

    @Test func protobufStopsAtBrokenBytesInsteadOfCrashing() {
        // Field 5, length 200, but only 2 bytes follow.
        #expect(CursorChat.context(inRoot: Data([0x2A, 0xC8, 0x01, 0x08, 0x01])) == nil)
        // Field 5 holding {1: 50, 2: 100}.
        #expect(CursorChat.context(inRoot: Data([0x2A, 0x04, 0x08, 50, 0x10, 100])) == ContextUsage(used: 50, window: 100))
        #expect(Protobuf.fields(Data([0xFF])).isEmpty)
    }
}

/// Kiro was not installed on the Mac this was written on, so `json` is written by hand,
/// following the field names of tokscale's Kiro reader. It is not a real Kiro file. `currentJSON`
/// is also written by hand, with nothing of anyone's session in it, but it has the fields and
/// the shapes of a session file from a real Kiro install (1 October 2026).
@Suite("Reading a Kiro CLI session")
struct KiroSessionTests {
    static let json = #"""
    {
      "session_id": "kiro-1",
      "cwd": "/Users/me/app",
      "session_state": {
        "rts_model_state": { "model_info": { "model_id": "claude-sonnet-4.5", "context_window_tokens": 200000 } },
        "conversation_metadata": { "user_turn_metadatas": [
          { "input_token_count": 1200, "output_token_count": 300, "cache_read_input_token_count": 5000,
            "cache_write_input_token_count": 100, "end_timestamp": "2026-09-21T10:00:00.000Z", "context_usage_percentage": 3.2,
            "metering_usage": [ { "value": 0.25, "unit": "credit" }, { "value": 99, "unit": "second" } ] },
          { "input_token_count": 0, "output_token_count": 0, "end_timestamp": 1790071200, "context_usage_percentage": 4.5,
            "metering_usage": [ { "value": 0.5, "unit": "credit" } ] },
          { "input_token_count": 10, "end_timestamp": { "secs_since_epoch": 1790071260, "nanos_since_epoch": 0 } },
          { "input_token_count": 10 }
        ] }
      }
    }
    """#

    @Test func readsModelWindowAndRequests() throws {
        let session = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        #expect(session.sessionID == "kiro-1")
        #expect(session.folder == "/Users/me/app")
        #expect(session.model == "claude-sonnet-4.5")
        #expect(session.requests.count == 4)
        // 4.5% of 200,000, from the last request that reported it.
        #expect(session.context == ContextUsage(used: 9_000, window: 200_000))
    }

    @Test func zeroCountsAreUnknownNotZero() throws {
        let session = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        #expect(session.requests[0].tokens == TokenUsage(input: 1_200, output: 300, cacheRead: 5_000, cacheWrite: 100))
        #expect(session.requests[1].tokens == nil)
    }

    @Test func requestsWithATimeBecomeTurns() throws {
        let session = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        let turns = session.turns(sessionID: "kiro-9", work: CodexRolloutTests.work)
        #expect(turns.map(\.timestamp) == [
            Fixture.date("2026-09-21T10:00:00Z"),
            Date(timeIntervalSince1970: 1_790_071_200),
            Date(timeIntervalSince1970: 1_790_071_260),
        ])
        #expect(turns.first?.context == ContextUsage(used: 6_400, window: 200_000))
        #expect(turns.allSatisfy { $0.agent == .kiro && $0.cost.usd == nil })
    }

    @Test func creditsAddUpOnlyCreditUnitsSinceADate() throws {
        let session = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        #expect(session.credits(since: .distantPast) == 0.75)
        // 1790071200 is after the first request, so only the second's 0.5 counts.
        #expect(session.credits(since: Date(timeIntervalSince1970: 1_790_071_200)) == 0.5)
        #expect(session.credits(since: Date(timeIntervalSince1970: 1_790_071_201)) == nil)
    }

    @Test func timesInMillisecondsAreRecognised() {
        #expect(KiroSession.date(1_790_071_200_000) == Date(timeIntervalSince1970: 1_790_071_200))
        #expect(KiroSession.date("not a date") == nil)
        // Epoch seconds written as text, which tokscale also accepts.
        #expect(KiroSession.date("1790071200.5") == Date(timeIntervalSince1970: 1_790_071_200.5))
    }

    @Test func withoutAWindowTheContextIsOutOfKiros200k() throws {
        // tokscale: when Kiro leaves out `context_window_tokens`, its Auto agent's 200K window applies.
        let json = #"""
        { "session_id": "kiro-2", "session_state": { "conversation_metadata": { "user_turn_metadatas": [
          { "end_timestamp": 1790071200, "context_usage_percentage": 10 } ] } } }
        """#
        let session = try #require(KiroSession(json: Data(json.utf8), fallbackID: "file"))
        #expect(session.context == ContextUsage(used: 20_000, window: 200_000))
        #expect(session.turns(sessionID: "k", work: CodexRolloutTests.work).first?.context
            == ContextUsage(used: 20_000, window: 200_000))
    }

    @Test func aFileThatIsNotJSONIsSkipped() {
        #expect(KiroSession(json: Data("[".utf8), fallbackID: "file") == nil)
    }

    /// A current build's file: a million-token window, every token count 0, and two requests
    /// answered by different models, each billed in credits (the second in two parts).
    static let currentJSON = #"""
    {
      "session_id": "kiro-current",
      "cwd": "/Users/me/app",
      "session_created_reason": "user",
      "session_state": {
        "rts_model_state": { "model_info": {
          "model_id": "auto", "model_name": "Auto", "context_window_tokens": 1000000,
          "rate_multiplier": 1.0, "rate_unit": "credit" } },
        "conversation_metadata": { "user_turn_metadatas": [
          { "total_request_count": 62, "number_of_cycles": 61, "builtin_tool_uses": 62,
            "turn_duration": { "secs": 553, "nanos": 519031792 }, "end_reason": "UserTurnEnd",
            "end_timestamp": "2026-10-01T09:29:17.541473Z",
            "input_token_count": 0, "output_token_count": 0,
            "cache_read_input_token_count": 0, "cache_write_input_token_count": 0,
            "model": "auto", "assistant_response_length": 32738, "request_attempts": 62,
            "context_usage_percentage": 12.561899, "final_context_usage_percentage": 12.561899,
            "metering_usage": [ { "value": 0.0994317, "unit": "credit", "unitPlural": "credits" } ],
            "user_prompt_length": 1630 },
          { "total_request_count": 9, "number_of_cycles": 8, "builtin_tool_uses": 7,
            "turn_duration": { "secs": 90, "nanos": 500000000 }, "end_reason": "UserTurnEnd",
            "end_timestamp": "2026-10-01T10:15:00.250000Z",
            "input_token_count": 0, "output_token_count": 0,
            "cache_read_input_token_count": 0, "cache_write_input_token_count": 0,
            "model": "claude-opus-4.8", "assistant_response_length": 4100, "request_attempts": 9,
            "context_usage_percentage": 20.0, "final_context_usage_percentage": 20.0,
            "metering_usage": [
              { "value": 0.25, "unit": "credit", "unitPlural": "credits" },
              { "value": 0.5, "unit": "credit", "unitPlural": "credits" } ],
            "user_prompt_length": 212 }
        ] }
      }
    }
    """#

    func currentTurns() throws -> [Turn] {
        let session = try #require(KiroSession(json: Data(Self.currentJSON.utf8), fallbackID: "file"))
        return session.turns(sessionID: "kiro-9", work: CodexRolloutTests.work)
    }

    @Test func eachRequestKeepsTheModelThatAnsweredIt() throws {
        let turns = try currentTurns()
        // The session's model is "auto", but its second request was answered by Opus.
        #expect(turns.map(\.model) == ["auto", "claude-opus-4.8"])
        let session = try #require(KiroSession(json: Data(Self.currentJSON.utf8), fallbackID: "file"))
        #expect(session.model == "auto")
    }

    @Test func aRequestThatNamesNoModelTakesTheSessionsOrAuto() throws {
        // `json` has a session model and no model on its requests; the file below has neither.
        let session = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        #expect(session.turns(sessionID: "k", work: CodexRolloutTests.work).map(\.model)
            == ["claude-sonnet-4.5", "claude-sonnet-4.5", "claude-sonnet-4.5"])
        let bare = #"""
        { "session_id": "kiro-3", "session_state": { "conversation_metadata": { "user_turn_metadatas": [
          { "end_timestamp": 1790071200 } ] } } }
        """#
        let unnamed = try #require(KiroSession(json: Data(bare.utf8), fallbackID: "file"))
        #expect(unnamed.turns(sessionID: "k", work: CodexRolloutTests.work).map(\.model) == ["auto"])
    }

    @Test func eachTurnHasItsDurationToolCallsAndCredits() throws {
        let turns = try currentTurns()
        // `turn_duration` is seconds plus nanoseconds.
        let first = try #require(turns[0].duration)
        #expect(abs(first - 553.519031792) < 1e-9)
        #expect(turns[1].duration == 90.5)
        #expect(turns.map(\.toolCalls) == [62, 7])
        // A request's credits are the sum of its `metering_usage` entries.
        let billed = try #require(turns[0].credits)
        #expect(abs(billed - 0.0994317) < 1e-12)
        #expect(turns[1].credits == 0.75)
        // The lengths are read, though nothing shows them yet.
        let session = try #require(KiroSession(json: Data(Self.currentJSON.utf8), fallbackID: "file"))
        #expect(session.requests.map(\.responseLength) == [32_738, 4_100])
        #expect(session.requests.map(\.promptLength) == [1_630, 212])
    }

    @Test func requestsWithoutThoseFieldsLeaveThemUnknown() throws {
        let session = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        let turns = session.turns(sessionID: "k", work: CodexRolloutTests.work)
        #expect(turns.allSatisfy { $0.duration == nil && $0.toolCalls == nil })
        #expect(session.requests.allSatisfy { $0.responseLength == nil && $0.promptLength == nil })
        // `turn_duration` without its seconds says nothing.
        let broken = #"""
        { "session_id": "kiro-4", "session_state": { "conversation_metadata": { "user_turn_metadatas": [
          { "end_timestamp": 1790071200, "turn_duration": { "nanos": 5 } } ] } } }
        """#
        let unmeasured = try #require(KiroSession(json: Data(broken.utf8), fallbackID: "file"))
        #expect(unmeasured.requests.first?.duration == nil)
    }

    @Test func zeroTokenCountsLeaveTheTokensOfTheTurnsAndThePeriodUnknown() throws {
        let turns = try currentTurns()
        #expect(turns.allSatisfy { $0.tokens == nil })
        let usage = PeriodUsageBuilder.make(
            .month, turns: turns, start: .distantPast, bucketStarts: [], openAgents: []
        )
        let kiro = try #require(usage.usage(of: .kiro))
        #expect(kiro.tokens == nil)
        #expect(kiro.toolCalls == 69)
        let credits = try #require(kiro.credits)
        #expect(abs(credits - 0.8494317) < 1e-9)
    }

    @Test func creditsAreSplitByTheModelThatSpentThem() throws {
        let byModel = Breakdown.byModel(try currentTurns())
        // Neither model has tokens, so both stay for their credits, the bigger spender first.
        #expect(byModel.map(\.model) == ["claude-opus-4.8", "auto"])
        #expect(byModel.map(\.tokens) == [0, 0])
        #expect(byModel[0].credits == 0.75)
        let auto = try #require(byModel[1].credits)
        #expect(abs(auto - 0.0994317) < 1e-12)
    }

    @Test func aCurrentFileKeepsItsOwnMillionTokenWindow() throws {
        let session = try #require(KiroSession(json: Data(Self.currentJSON.utf8), fallbackID: "file"))
        #expect(session.contextWindow == 1_000_000)
        // 12.561899% of 1,000,000 is 125,618.99, which rounds to 125,619.
        let turns = try currentTurns()
        #expect(turns[0].context == ContextUsage(used: 125_619, window: 1_000_000))
        // The session's own reading is the latest request's: 20%.
        #expect(session.context == ContextUsage(used: 200_000, window: 1_000_000))
    }

    // MARK: - The transcript estimate and the sub-agent flag

    /// A hand-written transcript in the shape of a real `<id>.jsonl`. It carries every kind the
    /// estimate reads: a Prompt line and a ToolResults line (both counted as input by their
    /// whole-line length), and an AssistantMessage line (counted as output by its whole-line
    /// length). The nested shapes are realistic, but the estimate measures each line's raw
    /// length, not its inner text.
    static let transcript = #"""
    {"version":1,"kind":"Prompt","data":{"content":[{"kind":"text","data":"abcdefgh"}]}}
    {"version":1,"kind":"ToolResults","data":{"content":[{"data":{"content":[{"kind":"text","data":"0123456789"}]}}]}}
    {"version":1,"kind":"AssistantMessage","data":{"content":[{"kind":"text","data":"wxyz"},{"kind":"toolUse","data":{"name":"read","path":"a.txt"}},{"kind":"thinking","data":{"text":"hmm"}}]}}

    """#

    @Test func theTranscriptEstimateCountsPromptAndToolResultsAsInput() throws {
        let estimate = try #require(KiroSession.estimatedTokens(fromTranscript: Self.transcript))
        // 2.5 characters a token, rounded, over each matched line's full length. Input is the
        // 84-character Prompt line plus the 114-character ToolResults line: 198/2.5 = 79.2, so
        // 79 input tokens.
        #expect(estimate.input == 79)
        // Output is the 189-character AssistantMessage line: 189/2.5 = 75.6, so 76 output tokens.
        #expect(estimate.output == 76)
        #expect(estimate == TokenUsage(input: 79, output: 76, cacheRead: nil, cacheWrite: nil))
        // No cache tokens are ever fabricated.
        #expect(estimate.cacheRead == nil && estimate.cacheWrite == nil)
    }

    @Test func anEmptyOrUnparsableTranscriptEstimatesNothing() {
        #expect(KiroSession.estimatedTokens(fromTranscript: "") == nil)
        // Neither line parses as JSON with a top-level kind, so nothing is counted.
        #expect(KiroSession.estimatedTokens(fromTranscript: "not json\n{") == nil)
        // A line whose kind is not Prompt, ToolResults or AssistantMessage is ignored.
        let other = #"{"version":1,"kind":"ToolUseSummary","data":{"content":[]}}"#
        #expect(KiroSession.estimatedTokens(fromTranscript: other) == nil)
    }

    @Test func aToolResultsLineIsCountedAsInputNotOutput() throws {
        // A single ToolResults line is input, and there is no output. Its whole 118-character
        // line is measured, not just the inner text.
        let toolOnly = #"""
        {"version":1,"kind":"ToolResults","data":{"content":[{"data":{"content":[{"kind":"text","data":"abcdefghijklmn"}]}}]}}
        """#
        let estimate = try #require(KiroSession.estimatedTokens(fromTranscript: toolOnly))
        // 118 characters at 2.5 a token (118/2.5 = 47.2) give 47 input tokens, no output.
        #expect(estimate == TokenUsage(input: 47, output: nil, cacheRead: nil, cacheWrite: nil))
    }

    @Test func anAssistantMessageLineContributesToOutput() throws {
        // An AssistantMessage line of 117 characters: its whole length is output.
        let assistant = #"""
        {"version":1,"kind":"AssistantMessage","data":{"content":[{"kind":"toolUse","data":{"name":"read","path":"a.txt"}}]}}
        """#
        let estimate = try #require(KiroSession.estimatedTokens(fromTranscript: assistant))
        // 117 characters at 2.5 a token (117/2.5 = 46.8) give 47 output tokens, no input.
        #expect(estimate == TokenUsage(input: nil, output: 47, cacheRead: nil, cacheWrite: nil))
    }

    @Test func malformedLinesAreSkippedNotCrashed() {
        // Lines that do not parse as JSON, or that carry no top-level kind, are skipped. The
        // kind is read defensively, but the measure is each matched line's raw length regardless
        // of its inner shape. Here the Prompt line (63 chars) and the two ToolResults lines (95
        // and 67 chars) count as input, and the AssistantMessage line (49 chars) as output.
        let broken = #"""
        not json at all
        {"version":1,"kind":"Prompt","data":{"content":"not an array"}}
        {"version":1,"kind":"ToolResults","data":{"content":[{"data":"a plain string of tool text."}]}}
        {"version":1,"kind":"AssistantMessage","data":{}}
        {"version":1,"kind":"ToolResults","data":{"content":[{"data":{}}]}}
        """#
        // Input: (63 + 95 + 67)/2.5 = 225/2.5 = 90. Output: 49/2.5 = 19.6, so 20.
        #expect(KiroSession.estimatedTokens(fromTranscript: broken)
            == TokenUsage(input: 90, output: 20, cacheRead: nil, cacheWrite: nil))
    }

    @Test func onlyOneSideOfTheConversationStillEstimates() throws {
        let promptOnly = #"{"version":1,"kind":"Prompt","data":{"content":[{"kind":"text","data":"abcdefghijkl"}]}}"#
        let estimate = try #require(KiroSession.estimatedTokens(fromTranscript: promptOnly))
        // The 88-character line at 2.5 a token (88/2.5 = 35.2) gives 35 input tokens, no output.
        #expect(estimate == TokenUsage(input: 35, output: nil, cacheRead: nil, cacheWrite: nil))
    }

    @Test func theFactoryPopulatesTheEstimateFromTheTranscript() throws {
        let withText = try #require(
            KiroSession(json: Data(Self.currentJSON.utf8), transcript: Self.transcript, fallbackID: "file")
        )
        #expect(withText.estimatedTokens == TokenUsage(input: 79, output: 76))
        // Without a transcript the estimate is nil, and the old initializer keeps it nil.
        let withoutText = try #require(KiroSession(json: Data(Self.currentJSON.utf8), transcript: nil, fallbackID: "file"))
        #expect(withoutText.estimatedTokens == nil)
        #expect(KiroSession(json: Data(Self.currentJSON.utf8), fallbackID: "file")?.estimatedTokens == nil)
    }

    @Test func theEstimateNeverEntersThePreciseTokenPath() throws {
        // Current builds report every precise count as 0, so the session's precise tokens stay
        // unknown even though an estimate is available.
        let session = try #require(
            KiroSession(json: Data(Self.currentJSON.utf8), transcript: Self.transcript, fallbackID: "file")
        )
        #expect(session.turns(sessionID: "k", work: CodexRolloutTests.work).allSatisfy { $0.tokens == nil })
        #expect(session.estimatedTokens != nil)
    }

    @Test func kiroNeverMarksASessionAsASubagent() throws {
        // Kiro writes session_created_reason "subagent" on every CLI session, including the
        // app's own /usage probe, so the field cannot identify a real sub-agent. No session is
        // treated as one, whatever the field says.
        let user = try #require(KiroSession(json: Data(Self.currentJSON.utf8), fallbackID: "file"))
        #expect(user.isSubagent == false)
        let labelledSubagentJSON = #"""
        { "session_id": "kiro-sub", "session_created_reason": "subagent",
          "session_state": { "conversation_metadata": { "user_turn_metadatas": [
            { "end_timestamp": 1790071200 } ] } } }
        """#
        let labelled = try #require(KiroSession(json: Data(labelledSubagentJSON.utf8), fallbackID: "file"))
        #expect(labelled.isSubagent == false)
        let bare = try #require(KiroSession(json: Data(Self.json.utf8), fallbackID: "file"))
        #expect(bare.isSubagent == false)
    }
}

/// A Kiro V3 (ACP) session transcript, read line by line. `Fixtures/kiro-v3-messages.jsonl` is
/// written by hand in the shape of a real `messages.jsonl`: an `assistant` line carrying a
/// namespaced `reasoningModelId` and its `executionId`, a successful `usage_summary` with the
/// credits, tools and elapsed time, a second successful turn billed in two parts, an aborted
/// (`status` "error") `usage_summary` whose credits must still be counted, and malformed lines
/// that must never crash.
@Suite("Reading a Kiro V3 session")
struct KiroV3TranscriptTests {
    static let work = Work(tag: WorkTag(project: "app", concern: "main"))

    static func transcript() throws -> KiroV3Transcript {
        var transcript = KiroV3Transcript()
        for line in try Fixture.text("kiro-v3-messages.jsonl").split(whereSeparator: \.isNewline) {
            transcript.consume(Data(line.utf8))
        }
        return transcript
    }

    @Test func eachUsageSummaryBecomesATurnWhateverItsStatus() throws {
        let turns = try Self.transcript().turns(
            sessUUID: "sess_abc", sessionID: "kiro-sess_abc", work: Self.work, sessionModel: "auto"
        )
        // Three turns: two successful and one aborted; only the malformed lines add nothing.
        #expect(turns.count == 3)
        let first = try #require(turns.first)
        #expect(first.id == "kiroV3-sess_abc-exec-1")
        #expect(first.agent == .kiro)
        #expect(first.sessionID == "kiro-sess_abc")
        #expect(first.timestamp == KiroSession.date("2026-10-01T10:24:11.946Z"))
        // One credit entry of 1.06.
        #expect(first.credits == 1.06)
        // Two tools used.
        #expect(first.toolCalls == 2)
        // 38911 ms is 38.911 seconds.
        #expect(first.duration == 38.911)
        // Kiro bills in credits, so no dollar cost and no token counts.
        #expect(first.cost.usd == nil)
        #expect(first.tokens == nil)
    }

    @Test func modelComesFromTheMatchingAssistantLineNormalised() throws {
        let turns = try Self.transcript().turns(
            sessUUID: "sess_abc", sessionID: "kiro-sess_abc", work: Self.work, sessionModel: "auto"
        )
        // "qdev::auto" and "qdev::claude-opus-4.8" lose their namespace to match the V2 ids. The
        // aborted exec-3 has no assistant line, so it takes the session's model.
        #expect(turns.map(\.model) == [ModelName("auto"), ModelName("claude-opus-4.8"), ModelName("auto")])
    }

    @Test func creditsOfATurnAreSummedOverItsCreditEntries() throws {
        let turns = try Self.transcript().turns(
            sessUUID: "sess_abc", sessionID: "kiro-sess_abc", work: Self.work, sessionModel: "auto"
        )
        // The second turn is billed in two parts: 0.25 + 0.5.
        #expect(turns[1].credits == 0.75)
        #expect(turns[1].toolCalls == 3)
    }

    @Test func anAbortedUsageSummaryStillCountsItsCredits() throws {
        let turns = try Self.transcript().turns(
            sessUUID: "sess_abc", sessionID: "kiro-sess_abc", work: Self.work, sessionModel: "auto"
        )
        // exec-3 had status "error" and a credit of 9.99; an aborted or failed turn is still
        // billed, so it becomes a turn and its credits are counted.
        let aborted = try #require(turns.first { $0.id.hasSuffix("exec-3") })
        #expect(aborted.credits == 9.99)
    }

    @Test func anAbortedTurnContributesItsCreditsToTheTotal() throws {
        let transcript = try Self.transcript()
        // 1.06 + 0.75 + the aborted 9.99 = 11.80.
        #expect(transcript.credits(since: .distantPast) == 11.80)
    }

    @Test func statusIsKeptButDoesNotGateCredits() throws {
        let transcript = try Self.transcript()
        // The two successful turns and the one aborted turn are all read; status is kept for
        // display only, so the aborted turn is present with isSuccess false and its credits.
        let aborted = try #require(transcript.usages.first { $0.executionId == "exec-3" })
        #expect(aborted.isSuccess == false)
        #expect(aborted.credits == 9.99)
        #expect(transcript.usages.filter(\.isSuccess).count == 2)
    }

    @Test func creditsSinceADateCountOnlyLaterTurns() throws {
        let transcript = try Self.transcript()
        // All three turns: 1.06 + 0.75 + the aborted 9.99 = 11.80.
        #expect(transcript.credits(since: .distantPast) == 11.80)
        // After the first turn, the second's 0.75 and the aborted 9.99 at 10:40 count.
        #expect(transcript.credits(since: Fixture.date("2026-10-01T10:25:00Z")) == 10.74)
        #expect(transcript.credits(since: Fixture.date("2026-10-01T11:00:00Z")) == nil)
    }

    @Test func aTurnWithNoAssistantLineFallsBackToTheSessionModelThenAuto() {
        var transcript = KiroV3Transcript()
        let line = #"{"timestamp":"2026-10-01T10:00:00.000Z","payload":{"type":"usage_summary","status":"success","executionId":"x","promptTurnSummaries":[{"unit":"credit","usage":1.0,"usedTools":[]}],"elapsedTime":1000}}"#
        transcript.consume(Data(line.utf8))
        let withSession = transcript.turns(sessUUID: "s", sessionID: "kiro-s", work: Self.work, sessionModel: "auto")
        #expect(withSession.first?.model == ModelName("auto"))
        let withoutSession = transcript.turns(sessUUID: "s", sessionID: "kiro-s", work: Self.work, sessionModel: nil)
        #expect(withoutSession.first?.model == ModelName("auto"))
    }

    @Test func modelNormalisationMatchesTheV2AutoName() {
        // The core requirement: "qdev::auto" and "auto" must yield the same ModelName (and so
        // the same display name), so V3 turns group with V2 turns in the by-model views.
        #expect(ModelName(KiroV3Transcript.normalisedModel("qdev::auto")) == ModelName("auto"))
        #expect(KiroV3Transcript.normalisedModel("qdev::auto") == "auto")
        #expect(KiroV3Transcript.normalisedModel("qdev::claude-opus-4.8") == "claude-opus-4.8")
        // An id with no namespace is unchanged, and only the last "::" is the boundary.
        #expect(KiroV3Transcript.normalisedModel("auto") == "auto")
        #expect(KiroV3Transcript.normalisedModel("a::b::c") == "c")
    }

    @Test func partialOrNonJsonLinesNeverCrash() {
        var transcript = KiroV3Transcript()
        transcript.consume(Data("not json".utf8))
        transcript.consume(Data(#"{"payload":{"type":"usage_summary""#.utf8))
        transcript.consume(Data("".utf8))
        #expect(transcript.usages.isEmpty)
    }

    @Test func metadataReadsTheFolderModelAndTitle() throws {
        let json = #"""
        { "workspacePaths": ["/Users/me/app"], "title": "A session", "modelId": "auto",
          "createdAt": "2026-10-01T09:00:00Z", "agentMode": "chat", "status": "idle" }
        """#
        let metadata = try #require(KiroV3Files.metadata(json: Data(json.utf8)))
        #expect(metadata.folder == "/Users/me/app")
        #expect(metadata.model == "auto")
        #expect(metadata.title == "A session")
        #expect(metadata.createdAt == KiroSession.date("2026-10-01T09:00:00Z"))
        // A file that does not parse reads as nothing.
        #expect(KiroV3Files.metadata(json: Data("[".utf8)) == nil)
    }
}

@Suite("Claude's limits, as the status line script saves them")
struct ClaudeLimitsLogTests {
    static let log = """
    {"at":1790020000,"five_hour":{"used_percentage":40,"resets_at":1790031600},"seven_day":{"used_percentage":12.5,"resets_at":1790400000}}
    not json
    {"at":1790023600,"five_hour":{"used_percentage":55,"resets_at":1790031600}}
    {"at":1790023700}
    """

    @Test func separatesRegisteredProfiles() {
        let data = Data("""
        {"at":1790020000,"account_id":"/tmp/.claude-work","account_name":"Work","five_hour":{"used_percentage":40,"resets_at":1790031600}}
        {"at":1790020100,"account_id":"/tmp/.claude-personal","account_name":"Personal","five_hour":{"used_percentage":72,"resets_at":1790031600}}
        """.utf8)
        let readings = ClaudeLimitsLog.readings(in: data, since: .distantPast)
        #expect(readings.map(\.accountName) == ["Work", "Personal"])
        #expect(ClaudeLimitsLog.accounts(in: data) == [
            "/tmp/.claude-work": "Work", "/tmp/.claude-personal": "Personal"
        ])
    }

    @Test func readsExistingAccountPercentageCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent(".claude/orchestrator/usage")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let json = """
        {"config_dir":"\(root.path)/.claude-work","five_hour_pct":20,"weekly_pct":27,"as_of":1790000000}
        """
        try json.write(to: directory.appendingPathComponent("account-2.json"), atomically: true, encoding: .utf8)
        let snapshots = ClaudeAccountCache.read(homeDirectory: root.path, files: FileAccess(), now: now)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.name == "work")
        #expect(snapshots.first?.fiveHourPercent == 20)
        #expect(snapshots.first?.weeklyPercent == 27)
    }

    @Test func readsBothWindows() throws {
        let readings = ClaudeLimitsLog.readings(in: Data(Self.log.utf8), since: .distantPast)
        #expect(readings.count == 2)
        #expect(readings[0].agent == .claudeCode)
        #expect(readings[0].windows == [
            LimitWindowReading(kind: .fiveHour, usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_790_031_600)),
            LimitWindowReading(kind: .weekly, usedPercent: 12.5, resetsAt: Date(timeIntervalSince1970: 1_790_400_000)),
        ])
        #expect(readings[1].windows.map(\.kind) == [.fiveHour])
    }

    @Test func leavesOutOlderReadings() {
        let readings = ClaudeLimitsLog.readings(in: Data(Self.log.utf8), since: Date(timeIntervalSince1970: 1_790_020_001))
        #expect(readings.map(\.timestamp) == [Date(timeIntervalSince1970: 1_790_023_600)])
    }

    @Test func twoReadingsGiveTheFiveHourPace() throws {
        let readings = ClaudeLimitsLog.readings(in: Data(Self.log.utf8), since: .distantPast)
        let calendar = Calendar(identifier: .gregorian)
        let report = try #require(LimitForecast.report(.fiveHour, from: readings, calendar: calendar))
        // 15 points in one hour.
        #expect(report.percentPerHour == 15)
        #expect(report.usedPercent == 55)
    }
}

@Suite("Whether a Cursor or Kiro session is working")
struct QuietSessionTests {
    @Test func workingWhileItsFilesChangeThenWaitingThenResting() {
        let written = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(ProcessSessionRepository.state(lastWrite: written, now: written + 10) == .working)
        #expect(ProcessSessionRepository.state(lastWrite: written, now: written + 60) == .waiting)
        #expect(ProcessSessionRepository.state(lastWrite: written, now: written + 31 * 60) == .idle)
        #expect(ProcessSessionRepository.state(lastWrite: nil, now: written) == .working)
    }
}
