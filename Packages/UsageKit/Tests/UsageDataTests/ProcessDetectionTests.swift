import Foundation
import Synchronization
import Testing
import UsageDomain
@testable import UsageData

/// Detection is tested on output recorded from `ps -ww -Ao pid,ppid,tty,lstart,command` on the
/// owner's Mac on 21 September 2026 (long lines trimmed), never on live processes.
enum Fixture {
    static let london = TimeZone(identifier: "Europe/London")!

    static func text(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func rows() throws -> [ProcessRow] {
        ProcessTable.parse(try text("ps-2026-09-21.txt"), timeZone: london)
    }

    static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }
}

@Suite("Reading the process list")
struct ProcessTableTests {
    @Test func readsEveryRowAndSkipsTheHeader() throws {
        let rows = try Fixture.rows()
        #expect(rows.count == 25)
        #expect(rows.first?.pid == 1)
    }

    @Test func readsPidParentTerminalStartAndCommand() throws {
        let row = try #require(try Fixture.rows().first { $0.pid == 35056 })
        #expect(row.parentPID == 35040)
        #expect(row.tty == "ttys006")
        // 22:00:49 British Summer Time is 21:00:49 UTC.
        #expect(row.startedAt == Fixture.date("2026-09-21T21:00:49Z"))
        #expect(row.command.hasPrefix("claude --dangerously-skip-permissions --fallback-model"))
        #expect(row.executableName == "claude")
    }

    @Test func noTerminalIsNil() throws {
        let row = try #require(try Fixture.rows().first { $0.pid == 91865 })
        #expect(row.tty == nil)
        #expect(row.executableName == "claude")
    }

    @Test func readsSingleDigitDaysAndLoginShells() throws {
        let rows = try Fixture.rows()
        #expect(rows.first { $0.pid == 16443 }?.startedAt == Fixture.date("2026-09-06T08:28:35Z"))
        #expect(rows.first { $0.pid == 3399 }?.executableName == "zsh")
    }

    @Test func readsTheDayFirstOrderOfOtherLocales() {
        let rows = ProcessTable.parse(
            " 3857  3399 ttys002  Sun 20 Sep 16:39:20 2026     claude --dangerously-skip-permissions",
            timeZone: Fixture.london
        )
        #expect(rows.first?.startedAt == Fixture.date("2026-09-20T15:39:20Z"))
    }

    @Test func skipsMalformedLines() {
        #expect(ProcessTable.parse("garbage\n  12 x ?? Mon Sep 21 22:00:49 2026 claude", timeZone: .gmt).isEmpty)
    }
}

@Suite("Finding sessions and dropping sub-agents")
struct TerminalAgentFinderTests {
    @Test func findsTheSixClaudeSessionsInTerminals() throws {
        let found = TerminalAgentFinder.find(in: try Fixture.rows())
        // Oldest first, as the strip lists them.
        #expect(found.map(\.process.pid) == [3857, 48718, 84087, 45226, 52454, 35056])
        #expect(found.allSatisfy { $0.agent == .claudeCode })
    }

    @Test func aClaudeWhoseParentIsAShellIsKept() throws {
        let found = TerminalAgentFinder.find(in: try Fixture.rows())
        let session = try #require(found.first { $0.process.pid == 3857 })
        #expect(session.tty == "ttys002")
        #expect(session.terminal == .warp)
    }

    @Test func aClaudeStartedByAnotherClaudeIsDropped() throws {
        // 91894 has a terminal of its own, but its parent chain runs through the
        // `claude daemon` that session 48718 started.
        let found = TerminalAgentFinder.find(in: try Fixture.rows())
        #expect(!found.contains { $0.process.pid == 91894 })
    }

    @Test func aProcessWithNoTerminalIsDropped() throws {
        let found = TerminalAgentFinder.find(in: try Fixture.rows())
        #expect(!found.contains { [91865, 91889, 91902, 91921].contains($0.process.pid) })
    }

    @Test func sessionsInsideTmuxBelongToTmux() throws {
        let found = TerminalAgentFinder.find(in: try Fixture.rows())
        #expect(found.first { $0.process.pid == 35056 }?.terminal == .tmux)
        #expect(found.first { $0.process.pid == 45226 }?.terminal == .warp)
    }

    @Test func aWrapperThatMentionsClaudeInItsArgumentsIsNotAnAgent() throws {
        let wrapper = try #require(try Fixture.rows().first { $0.pid == 35040 })
        #expect(TerminalAgentFinder.agent(of: wrapper) == nil)
    }

    @Test func recognisesEveryAgentAndScriptLaunchers() {
        func agent(_ command: String) -> Agent? {
            TerminalAgentFinder.agent(of: ProcessRow(pid: 2, parentPID: 1, tty: "ttys001", startedAt: .now, command: command))
        }
        #expect(agent("/opt/homebrew/bin/codex") == .codex)
        #expect(agent("node /opt/homebrew/bin/codex") == .codex)
        #expect(agent("cursor-agent") == .cursor)
        #expect(agent("/Users/me/.opencode/bin/opencode") == .opencode)
        #expect(agent("kiro-cli chat") == .kiro)
        // Kiro's installer puts its chat program in "Kiro CLI.app", a folder with a space in it.
        #expect(agent("kiro-cli-chat") == .kiro)
        #expect(agent("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat chat --resume") == .kiro)
        #expect(agent("/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli") == .kiro)
        #expect(agent("/Applications/Some App.app/Contents/MacOS/Some App --flag") == nil)
        #expect(agent("/Applications/Claude.app/Contents/MacOS/Claude") == nil)
        #expect(agent("node bin/serve.js") == nil)
    }

    @Test func kiroAndTheChatProgramItStartsCountOnce() {
        let rows = [
            ProcessRow(pid: 11, parentPID: 1, tty: "ttys001", startedAt: .now, command: "-zsh"),
            ProcessRow(pid: 12, parentPID: 11, tty: "ttys001", startedAt: .now, command: "kiro-cli chat"),
            ProcessRow(
                pid: 13, parentPID: 12, tty: "ttys001", startedAt: .now,
                command: "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat chat"
            ),
        ]
        #expect(TerminalAgentFinder.find(in: rows).map(\.process.pid) == [12])
    }

    @Test func aNodeLauncherCountsOnceNotTwice() {
        // `codex` from npm is a Node script that starts the native binary as its child.
        let rows = [
            ProcessRow(pid: 10, parentPID: 1, tty: nil, startedAt: .now, command: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            ProcessRow(pid: 11, parentPID: 10, tty: "ttys001", startedAt: .now, command: "-zsh"),
            ProcessRow(pid: 12, parentPID: 11, tty: "ttys001", startedAt: .now, command: "node /opt/homebrew/bin/codex"),
            ProcessRow(pid: 13, parentPID: 12, tty: "ttys001", startedAt: .now,
                       command: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/codex/codex"),
        ]
        let found = TerminalAgentFinder.find(in: rows)
        #expect(found.map(\.process.pid) == [12])
        #expect(found.first?.terminal == .ghostty)
    }

    @Test func aParentLoopDoesNotHang() {
        let rows = [
            ProcessRow(pid: 20, parentPID: 21, tty: "ttys001", startedAt: .now, command: "claude"),
            ProcessRow(pid: 21, parentPID: 20, tty: "ttys001", startedAt: .now, command: "zsh"),
        ]
        #expect(TerminalAgentFinder.find(in: rows).map(\.process.pid) == [20])
    }
}

@Suite("Repository and branch from .git")
struct GitLocatorTests {
    @Test func readsTheBranchFromHEAD() {
        #expect(GitLocator.branch(fromHEAD: "ref: refs/heads/feat/image-gen-v2\n") == "feat/image-gen-v2")
        #expect(GitLocator.branch(fromHEAD: "42000dd8a1c3\n") == nil)
    }

    @Test func findsTheRepositoryAboveASubfolder() {
        let files: [String: String] = ["/r/ai-usage-tracker/.git/HEAD": "ref: refs/heads/feat/session-detection\n"]
        let locator = GitLocator(
            readFile: { files[$0] },
            isDirectory: { $0 == "/r/ai-usage-tracker/.git" ? true : nil }
        )
        let location = locator.locate(folder: "/r/ai-usage-tracker/Packages/UsageKit")
        #expect(location == GitLocation(repositoryName: "ai-usage-tracker", branch: "feat/session-detection"))
    }

    @Test func aWorktreeIsNamedAfterItsMainRepository() {
        let files: [String: String] = [
            "/wt/ms-image-gen/.git": "gitdir: /src/marketing-studio/.git/worktrees/ms-image-gen\n",
            "/src/marketing-studio/.git/worktrees/ms-image-gen/HEAD": "ref: refs/heads/feat/image-gen-v2\n",
        ]
        let locator = GitLocator(
            readFile: { files[$0] },
            isDirectory: { $0 == "/wt/ms-image-gen/.git" ? false : nil }
        )
        let location = locator.locate(folder: "/wt/ms-image-gen")
        #expect(location == GitLocation(repositoryName: "marketing-studio", branch: "feat/image-gen-v2"))
    }

    @Test func aFolderOutsideAnyRepositoryHasNone() {
        let locator = GitLocator(readFile: { _ in nil }, isDirectory: { _ in nil })
        #expect(locator.locate(folder: "/Users/me") == nil)
    }
}

@Suite("Linking a Claude session to its transcript")
struct ClaudeSessionIndexTests {
    let file = ClaudeSessionFile(
        pid: 35056,
        sessionId: "0f3c1d52-8a41-4a37-9d0e-6b2c5d7e1a90",
        cwd: "/Users/me/Development/ai-usage-tracker",
        startedAt: 1_790_024_450_474
    )

    @Test func readsTheRecordedSessionFile() throws {
        let data = Data(try Fixture.text("claude-session-35056.json").utf8)
        let parsed = try #require(ClaudeSessionIndex.parse(data))
        #expect(parsed.sessionId == file.sessionId && parsed.pid == file.pid && parsed.cwd == file.cwd)
        #expect(parsed.chosenName == "ai-usage-tracker")
        #expect(ClaudeSessionIndex.parse(Data("not json".utf8)) == nil)
    }

    @Test func onlyANameThePersonChoseIsUsed() {
        let derived = ClaudeSessionFile(pid: 3857, sessionId: "s", cwd: "/", startedAt: nil, name: "me-92", nameSource: "derived")
        let auto = ClaudeSessionFile(pid: 1, sessionId: "s", cwd: "/", startedAt: nil, name: "Extract tool", nameSource: "auto")
        #expect(derived.chosenName == nil)
        #expect(auto.chosenName == nil)
    }

    @Test func matchesTheProcessByPidAndStartTime() throws {
        let process = try #require(try Fixture.rows().first { $0.pid == 35056 })
        #expect(ClaudeSessionIndex.file(forPID: 35056, startedAt: process.startedAt, in: [file]) == file)
    }

    @Test func ignoresAStaleFileFromAnEarlierProcessWithTheSamePid() {
        let laterProcess = Fixture.date("2026-09-22T09:00:00Z")
        #expect(ClaudeSessionIndex.file(forPID: 35056, startedAt: laterProcess, in: [file]) == nil)
        #expect(ClaudeSessionIndex.file(forPID: 3857, startedAt: .distantPast, in: [file]) == nil)
    }

    @Test func namesTheProjectFolderAsClaudeCodeDoes() {
        #expect(ClaudeSessionIndex.projectFolderName(forCWD: "/Users/me/Development/ai-usage-tracker")
            == "-Users-me-Development-ai-usage-tracker")
        #expect(ClaudeSessionIndex.projectFolderName(forCWD: "/Users/me/Development/loubenita/tooling/.fleet")
            == "-Users-me-Development-loubenita-tooling--fleet")
    }

    @Test func findsTheTranscriptWhereTheWorkingDirectoryPoints() {
        let expected = "/p/-Users-me-Development-ai-usage-tracker/0f3c1d52-8a41-4a37-9d0e-6b2c5d7e1a90.jsonl"
        let path = ClaudeSessionIndex.transcriptPath(
            for: file, projectsDirectory: "/p", projectFolders: { [] }, fileExists: { $0 == expected }
        )
        #expect(path == expected)
    }

    @Test func searchesOtherProjectFoldersWhenItMoved() {
        let moved = "/p/-Users-me/0f3c1d52-8a41-4a37-9d0e-6b2c5d7e1a90.jsonl"
        let path = ClaudeSessionIndex.transcriptPath(
            for: file, projectsDirectory: "/p", projectFolders: { ["-a", "-Users-me"] }, fileExists: { $0 == moved }
        )
        #expect(path == moved)
    }

    @Test func noTranscriptYetIsNil() {
        let path = ClaudeSessionIndex.transcriptPath(
            for: file, projectsDirectory: "/p", projectFolders: { ["-a"] }, fileExists: { _ in false }
        )
        #expect(path == nil)
    }
}

/// The whole repository over the recorded process list, with no live system calls.
@Suite("Process session repository")
struct ProcessSessionRepositoryTests {
    struct RecordedSource: ProcessSource {
        let text: String
        func processList() throws -> String { text }
        func workingDirectory(of pid: Int32) -> String? { pid == 35056 ? "/nonexistent/ai-usage-tracker" : nil }
    }

    @Test func servesOneStartRecordPerSession() async throws {
        let repository = ProcessSessionRepository(
            source: RecordedSource(text: try Fixture.text("ps-2026-09-21.txt")),
            claudeDirectory: "/nonexistent",
            timeZone: Fixture.london
        )
        let records = try await repository.records(from: .distantPast, to: .distantFuture)
        #expect(records.turns.isEmpty && records.limits.isEmpty)
        #expect(records.sessionEvents.map(\.sessionID)
            == ["claude-code-3857", "claude-code-48718", "claude-code-84087", "claude-code-45226",
                "claude-code-52454", "claude-code-35056"])
        let mine = try #require(records.sessionEvents.last)
        #expect(mine.kind == .start && mine.state == .working)
        #expect(mine.timestamp == Fixture.date("2026-09-21T21:00:49Z"))
        #expect(mine.origin?.tty == "ttys006")
        #expect(mine.origin?.terminal == .tmux)
        #expect(mine.origin?.folder == "/nonexistent/ai-usage-tracker")
        #expect(mine.work == WorkTag(project: "ai-usage-tracker", concern: "ai-usage-tracker"))
    }

    /// Counts how often each session's folder is looked up, which happens once per read of its files.
    final class CountingSource: ProcessSource {
        let text: Mutex<String>
        let lookups = Mutex(0)
        init(_ text: String) { self.text = Mutex(text) }
        func processList() throws -> String { text.withLock { $0 } }
        func workingDirectory(of pid: Int32) -> String? {
            lookups.withLock { $0 += 1 }
            return nil
        }
    }

    @Test func aSessionsFilesAreReadAtMostEverySixSeconds() async throws {
        let text = try Fixture.text("ps-2026-09-21.txt")
        let source = CountingSource(text)
        let repository = ProcessSessionRepository(source: source, claudeDirectory: "/nonexistent", timeZone: Fixture.london)
        let first = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(source.lookups.withLock { $0 } == 6)
        // A couple of seconds later the process list is read again, but not the six sessions' files.
        let second = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(source.lookups.withLock { $0 } == 6)
        #expect(second.sessionEvents.map(\.sessionID) == first.sessionEvents.map(\.sessionID))
        #expect(second.sessionEvents.map(\.origin?.folder) == first.sessionEvents.map(\.origin?.folder))
        // A session that ends is forgotten; one that starts is read straight away.
        let withoutLast = text.split(separator: "\n").filter { !$0.hasPrefix("35056 ") }.joined(separator: "\n")
        source.text.withLock { $0 = withoutLast }
        let third = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(!third.sessionEvents.contains { $0.sessionID == "claude-code-35056" })
        source.text.withLock { $0 = text }
        _ = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(source.lookups.withLock { $0 } == 7)
    }

    @Test func onceTheIntervalHasPassedTheFilesAreReadAgain() async throws {
        let source = CountingSource(try Fixture.text("ps-2026-09-21.txt"))
        // An interval of zero has always passed, so each call reads every session's files.
        let repository = ProcessSessionRepository(
            source: source, claudeDirectory: "/nonexistent", timeZone: Fixture.london, filesInterval: 0
        )
        _ = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        _ = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(source.lookups.withLock { $0 } == 12)
    }

    @Test func reportsRunningTimeAndFolderLabel() async throws {
        let repository = ProcessSessionRepository(
            source: RecordedSource(text: try Fixture.text("ps-2026-09-21.txt")),
            claudeDirectory: "/nonexistent",
            timeZone: Fixture.london
        )
        let generate = GenerateUsageReport(settings: try await repository.settings(), calendar: .current)
        let now = Fixture.date("2026-09-21T21:30:49Z")
        let report = generate(try await repository.records(from: .distantPast, to: now), now: now)
        let mine = try #require(report.sessions.last)
        #expect(mine.code == "AIUT")
        #expect(mine.summary.activeDuration == 30 * 60)
        #expect(mine.summary.origin?.pid == 35056)
    }
}
