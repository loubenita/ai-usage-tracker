import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// `Fixtures/codex-rollout.jsonl` is a real Codex rollout from 17 September 2026, cut down to the
/// lines the app reads, with instructions and messages removed and the folder renamed. Every
/// number expected here was worked out from it with Python.
@Suite("Reading a Codex rollout")
struct CodexRolloutTests {
    static func rollout(extraLines: [String] = []) throws -> CodexRollout {
        var rollout = CodexRollout()
        let lines = try Fixture.text("codex-rollout.jsonl").split(separator: "\n") + extraLines.map { Substring($0) }
        for line in lines { rollout.consume(Data(line.utf8)) }
        return rollout
    }

    static let work = Work(tag: WorkTag(project: "app", concern: "feat/codex-usage"))

    @Test func readsTheSessionFromTheFirstLine() throws {
        let rollout = try Self.rollout()
        #expect(rollout.sessionID == "01a0afa0-09aa-71e2-a26c-21e6dd4ce1fe")
        #expect(rollout.folder == "/Users/me/app")
        #expect(rollout.branch == "feat/codex-usage")
        #expect(rollout.isSubagent == false)
        #expect(rollout.model == "gpt-5.6-sol")
        #expect(rollout.effort == "medium")
    }

    @Test func eachTokenCountIsOneReplyWithCachedInputTakenOutOfInput() throws {
        let turns = try Self.rollout().turns(sessionID: "codex-1", work: Self.work)
        #expect(turns.count == 4)
        let first = try #require(turns.first)
        #expect(first.tokens == TokenUsage(input: 20_514, output: 209, cacheRead: 0, cacheWrite: 0))
        #expect(first.context == ContextUsage(used: 20_723, window: 258_400))
        #expect(first.model == "gpt-5.6-sol")
        #expect(first.agent == .codex)
        #expect(first.cost.usd == nil)
        let total = try #require(Breakdown.totalTokens(turns))
        #expect(total.input == 27_557)
        #expect(total.cacheRead == 67_840)
        #expect(total.output == 710)
        // Reasoning is inside output_tokens already, so it is never counted a second time.
        #expect(total.reasoning == nil)
    }

    @Test func anEventWhoseTotalDidNotMoveAddsNoReply() throws {
        let lines = try Fixture.text("codex-rollout.jsonl").split(separator: "\n")
        let lastTokenCount = try #require(lines.last { $0.contains(#""type":"token_count""#) })
        let rollout = try Self.rollout(extraLines: [String(lastTokenCount)])
        #expect(rollout.replies.count == 4)
        #expect(rollout.limits.count == 5)
    }

    @Test func readsTheLimitsByTheLengthOfTheirWindow() throws {
        let limits = try Self.rollout().limits
        #expect(limits.count == 4)
        let last = try #require(limits.last)
        #expect(last.agent == .codex)
        #expect(last.plan == "prolite")
        #expect(last.windows == [
            LimitWindowReading(kind: .weekly, usedPercent: 87, resetsAt: Date(timeIntervalSince1970: 1_790_229_429)),
        ])

        let fiveHour = #"{"timestamp":"2026-09-17T14:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_at":1790000000},"secondary":{"used_percent":3,"window_minutes":43200,"resets_at":1791000000}}}}"#
        let windows = try #require(try Self.rollout(extraLines: [fiveHour]).limits.last).windows
        // A 30-day window is not one the app shows, so it is left out.
        #expect(windows == [
            LimitWindowReading(kind: .fiveHour, usedPercent: 12.5, resetsAt: Date(timeIntervalSince1970: 1_790_000_000)),
        ])
    }

    @Test func aModelsOwnLimitIsNotThePlans() throws {
        // Seen on this Mac on 17 September: GPT-5.3-Codex-Spark reports a limit of its own.
        let spark = #"{"timestamp":"2026-09-17T14:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1789625641}}}}"#
        #expect(try Self.rollout(extraLines: [spark]).limits.count == 4)
    }

    @Test func workingUntilTheTaskCompletesThenWaitingThenResting() throws {
        let rollout = try Self.rollout()
        let completed = Date(timeIntervalSince1970: 1_789_653_000.890) // 2026-09-17T13:50:00.890Z
        #expect(rollout.state(now: completed + 60) == .waiting)
        #expect(rollout.state(now: completed + 31 * 60) == .idle)

        let started = #"{"timestamp":"2026-09-17T13:55:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
        #expect(try Self.rollout(extraLines: [started]).state(now: completed + 600) == .working)
        #expect(CodexRollout().state(now: completed) == .working)
    }

    @Test func recognisesASubagentsRollout() {
        var rollout = CodexRollout()
        rollout.consume(Data(#"{"timestamp":"2026-09-17T13:49:37.427Z","type":"session_meta","payload":{"id":"s","cwd":"/a","source":{"subagent":{"thread_spawn":{"parent_thread_id":"p"}}}}}"#.utf8))
        #expect(rollout.isSubagent)
    }
}

@Suite("Finding a Codex process's rollout")
struct CodexFilesTests {
    /// A temporary `~/.codex` with the fixture rollout in its day folder.
    static func codexDirectory(extra: [(folder: String, name: String, text: String)] = []) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        let text = try Fixture.text("codex-rollout.jsonl")
        for (folder, name, content) in [("sessions/2026/09/17", "rollout-a.jsonl", text)] + extra {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try content.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return root.path
    }

    static let processStart = Date(timeIntervalSince1970: 1_789_652_880) // 2026-09-17T13:48:00Z

    @Test func findsTheRolloutInTheProcessFolder() throws {
        let directory = try Self.codexDirectory()
        let files = CodexFiles(directory: directory)
        let path = files.rollout(startedAt: Self.processStart, folder: "/Users/me/app", excluding: [], now: Date())
        #expect(path == directory + "/sessions/2026/09/17/rollout-a.jsonl")
        #expect(files.rollout(startedAt: Self.processStart, folder: "/Users/me/other", excluding: [], now: Date()) == nil)
        #expect(files.rollout(startedAt: Self.processStart, folder: "/Users/me/app", excluding: [path!], now: Date()) == nil)
    }

    @Test func skipsSubagentRollouts() throws {
        let subagent = #"{"timestamp":"2026-09-17T13:49:40.000Z","type":"session_meta","payload":{"id":"sub","timestamp":"2026-09-17T13:49:40.000Z","cwd":"/Users/me/app","source":{"subagent":{}}}}"#
        let directory = try Self.codexDirectory(extra: [("sessions/2026/09/17", "rollout-sub.jsonl", subagent + "\n")])
        let path = CodexFiles(directory: directory)
            .rollout(startedAt: Self.processStart, folder: "/Users/me/app", excluding: [], now: Date())
        #expect(path?.hasSuffix("rollout-a.jsonl") == true)
    }
}
