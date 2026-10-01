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
