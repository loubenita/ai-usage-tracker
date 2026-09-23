import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// The week's history read from a temporary home folder holding:
/// - the Claude fixture transcript as one session, and again as that session's sub-agent;
/// - the Codex fixture rollout;
/// - a Claude limits log.
///
/// Numbers worked out with Python: the Claude transcript's 9 replies have 48,793 tokens without
/// cache reads in 35.923 working seconds; the Codex rollout's 4 replies have 28,267 in 15.871.
@Suite("Every agent's history for Today and This week")
struct UsageHistoryTests {
    static let now = Fixture.date("2026-09-21T21:30:00Z")

    static func home() throws -> String {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        let project = home.appendingPathComponent(".claude/projects/-Users-me-app")
        try manager.createDirectory(at: project.appendingPathComponent("session/subagents"), withIntermediateDirectories: true)
        let transcript = try Fixture.text("claude-transcript.jsonl")
        try transcript.write(to: project.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        // A sub-agent's own lines are all side chains, and have their own message ids.
        let subagent = transcript
            .replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
            .replacingOccurrences(of: #""id":"msg_"#, with: #""id":"msg_sub_"#)
        try subagent.write(to: project.appendingPathComponent("session/subagents/agent-1.jsonl"), atomically: true, encoding: .utf8)

        let day = home.appendingPathComponent(".codex/sessions/2026/09/17")
        try manager.createDirectory(at: day, withIntermediateDirectories: true)
        try Fixture.text("codex-rollout.jsonl").write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)

        let limits = home.appendingPathComponent("Library/Application Support/AIUsageTracker")
        try manager.createDirectory(at: limits, withIntermediateDirectories: true)
        try ClaudeLimitsLogTests.log.write(to: limits.appendingPathComponent("claude-limits.jsonl"), atomically: true, encoding: .utf8)
        return home.path
    }

    static func history(home: String, minimumWorkingTime: TimeInterval = 0) -> UsageHistory {
        UsageHistory(
            homeDirectory: home,
            claudeDirectory: home + "/.claude",
            codex: CodexFiles(directory: home + "/.codex"),
            kiro: KiroFiles(directory: home + "/.kiro/sessions/cli"),
            minimumWorkingTime: minimumWorkingTime
        )
    }

    @Test func countsSubagentsAndEveryAgent() throws {
        let snapshot = Self.history(home: try Self.home()).read(now: Self.now)
        let byAgent = Dictionary(grouping: snapshot.turns, by: \.agent).mapValues(\.count)
        #expect(byAgent[.claudeCode] == 18)
        #expect(byAgent[.codex] == 4)
        // A sub-agent's replies belong to its parent session.
        #expect(Set(snapshot.turns.filter { $0.agent == .claudeCode }.map(\.sessionID)) == ["claude-code-session"])
    }

    @Test func namesTheWorkFromTheFolderAndBranchTheAgentRecorded() throws {
        let snapshot = Self.history(home: try Self.home()).read(now: Self.now)
        let codex = try #require(snapshot.turns.first { $0.agent == .codex })
        #expect(codex.work.tag == WorkTag(project: "app", concern: "feat/codex-usage"))
        #expect(codex.work.folder == "/Users/me/app")
    }

    @Test func workInTheHomeFolderIsCalledHomeFolderNotTheUserName() {
        let namer = WorkNamer(files: FileAccess(), homeDirectory: "/Users/me")
        #expect(namer.work(folder: "/Users/me", branch: nil).tag == WorkTag(project: "Home folder", concern: "Home folder"))
        #expect(namer.work(folder: "/Users/me/", branch: nil).tag.project == "Home folder")
        // A folder outside git is named after itself.
        #expect(namer.work(folder: "/nonexistent/notes", branch: nil).tag == WorkTag(project: "notes", concern: "notes"))
        #expect(namer.work(folder: nil, branch: "main").tag == WorkTag(project: "Unknown folder", concern: "main"))
    }

    @Test func usualPaceIsPerAgentAndLeavesSubagentsOut() throws {
        let rates = Self.history(home: try Self.home()).read(now: Self.now).usualRates
        let claude = try #require(rates[.claudeCode])
        #expect(abs(claude.workingTime - 35.923) < 0.001)
        #expect(abs(claude.tokensPerHour - 48_793 / (35.923 / 3600)) < 1)
        let codex = try #require(rates[.codex])
        #expect(abs(codex.workingTime - 15.871) < 0.001)
        #expect(abs(codex.tokensPerHour - 28_267 / (15.871 / 3600)) < 1)
    }

    @Test func needsAnHourOfWorkForAUsualPace() throws {
        let history = Self.history(home: try Self.home(), minimumWorkingTime: UsualRate.minimumWorkingTime)
        #expect(history.read(now: Self.now).usualRates.isEmpty)
    }

    @Test func readsBothAgentsLimits() throws {
        let limits = Self.history(home: try Self.home()).read(now: Self.now).limits
        #expect(limits.filter { $0.agent == .codex }.count == 4)
        #expect(limits.filter { $0.agent == .claudeCode }.count == 2)
    }

    @Test func addsUpThisMonthsKiroCredits() throws {
        let home = try Self.home()
        let kiro = URL(fileURLWithPath: home + "/.kiro/sessions/cli")
        try FileManager.default.createDirectory(at: kiro, withIntermediateDirectories: true)
        try KiroSessionTests.json.write(to: kiro.appendingPathComponent("kiro-1.json"), atomically: true, encoding: .utf8)
        // A chat Kiro opened in the app's own folder, to answer its `/usage` question, is not counted.
        let own = KiroSessionTests.json
            .replacingOccurrences(of: "\"kiro-1\"", with: "\"own\"")
            .replacingOccurrences(of: "/Users/me/app", with: "/private/var/folders/x/T/" + KiroPlanReader.folderName)
        try own.write(to: kiro.appendingPathComponent("own.json"), atomically: true, encoding: .utf8)
        let snapshot = Self.history(home: home).read(now: Self.now)
        #expect(!snapshot.turns.contains { $0.sessionID == "kiro-own" })
        // Both requests with credits fall in September 2026: 0.25 + 0.5.
        #expect(snapshot.creditsThisMonth == [.kiro: 0.75])
        #expect(Self.history(home: home).read(now: Fixture.date("2026-10-02T12:00:00Z")).creditsThisMonth.isEmpty)
    }

    @Test func isIncompleteUntilTheFirstReadFinishes() throws {
        let history = Self.history(home: try Self.home())
        #expect(history.current(now: Self.now).isComplete == false)
        #expect(history.read(now: Self.now).isComplete)
    }

    @Test func leavesOutWhatIsOlderThanTheWeekAndTheMonth() throws {
        let home = try Self.home()
        // Eight days on, but still September: the Month view needs them.
        let september = Self.history(home: home).read(now: Fixture.date("2026-09-29T21:30:00Z"))
        #expect(!september.turns.isEmpty)
        // The usual pace still comes from the last week only.
        #expect(september.usualRates.isEmpty)
        let october = Self.history(home: home).read(now: Fixture.date("2026-10-29T21:30:00Z"))
        #expect(october.turns.isEmpty)
        #expect(october.usualRates.isEmpty)
    }
}
