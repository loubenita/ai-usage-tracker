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

    @Test func findsSessionsFromBothClaudeProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for profile in [".claude", ".claude-loubenita"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(profile + "/sessions"), withIntermediateDirectories: true
            )
        }
        try """
        {"pid":3857,"sessionId":"main-profile","cwd":"/tmp"}
        """.write(
            to: root.appendingPathComponent(".claude/sessions/3857.json"),
            atomically: true, encoding: .utf8
        )
        try """
        {"pid":35056,"sessionId":"second-profile","cwd":"/tmp"}
        """.write(
            to: root.appendingPathComponent(".claude-loubenita/sessions/35056.json"),
            atomically: true, encoding: .utf8
        )
        let repository = ProcessSessionRepository(
            source: RecordedSource(text: try Fixture.text("ps-2026-09-21.txt")),
            homeDirectory: root.path, timeZone: Fixture.london
        )
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(records.sessionEvents.first { $0.origin?.pid == 3857 }?.origin?.accountName == "Default")
        #expect(records.sessionEvents.first { $0.origin?.pid == 35056 }?.origin?.accountName == "loubenita")
        #expect(records.sessionEvents.first { $0.origin?.pid == 35056 }?.origin?.accountID
            == root.path + "/.claude-loubenita")
    }

    /// Claude Code's background sessions run under its daemon, with no terminal app above them.
    /// A claimed one has a session file; an idle spare kept warm for the next one does not.
    @Test func findsBackgroundClaudeSessionsButNotIdleSpares() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/sessions"), withIntermediateDirectories: true
        )
        try """
        {"pid":81303,"sessionId":"bg-lead","cwd":"/tmp","name":"lead","kind":"bg","status":"busy"}
        """.write(to: root.appendingPathComponent(".claude/sessions/81303.json"), atomically: true, encoding: .utf8)
        let table = """
          PID  PPID TTY      STARTED                      COMMAND
            1     0 ??       Mon Aug 24 20:16:04 2026     /sbin/launchd
        48744     1 ??       Sun Sep 27 09:00:00 2026     /Users/me/.local/bin/claude daemon run --json-path /Users/me/.claude/daemon.json
        81290     1 ??       Sun Sep 27 09:01:00 2026     claude bg-pty-host --bg-pty-host /tmp/cc/a.pty.sock 200 50 -- /Users/me/.local/share/claude/versions/2.1.283
        81303 81290 ttys000  Sun Sep 27 09:01:00 2026     claude bg-spare --bg-spare /tmp/cc/a.claim.sock
        48968 48744 ??       Sun Sep 27 09:02:00 2026     claude bg-pty-host --bg-pty-host /tmp/cc/b.pty.sock 200 50 -- /Users/me/.local/share/claude/versions/2.1.284
        49053 48968 ??       Sun Sep 27 09:02:00 2026     claude bg-spare --bg-spare /tmp/cc/b.claim.sock
        """
        let repository = ProcessSessionRepository(
            source: RecordedSource(text: table), homeDirectory: root.path, timeZone: Fixture.london
        )
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(records.sessionEvents.compactMap(\.origin?.pid) == [81303])
        let lead = try #require(records.sessionEvents.first?.origin)
        #expect(lead.terminal == .background)
        #expect(lead.sessionName == "lead")
    }

    /// `claude attach <id>` shows a background session in a terminal. It is a window onto that
    /// session, not a session of its own, so it must not be counted twice.
    @Test func aWindowAttachedToABackgroundSessionIsNotASessionOfItsOwn() {
        let rows = ProcessTable.parse("""
          PID  PPID TTY      STARTED                      COMMAND
            1     0 ??       Mon Aug 24 20:16:04 2026     /sbin/launchd
        34833     1 ttys002  Wed Sep 30 09:00:00 2026     -zsh
        35334 34833 ttys002  Wed Sep 30 09:00:01 2026     claude attach 8ea55422
        """, timeZone: Fixture.london)
        #expect(TerminalAgentFinder.find(in: rows).isEmpty)
    }

    /// Any agent started without a terminal, by a script or a scheduler, is a background session.
    /// Servers other apps talk to are not sessions, and neither is anything another agent started.
    @Test func findsBackgroundSessionsOfEveryAgentButNotServers() {
        let rows = ProcessTable.parse("""
          PID  PPID TTY      STARTED                      COMMAND
            1     0 ??       Mon Aug 24 20:16:04 2026     /sbin/launchd
          500     1 ??       Sun Sep 27 09:00:00 2026     /bin/sh /Users/me/nightly.sh
          501   500 ??       Sun Sep 27 09:00:01 2026     codex exec tidy the changelog
          502   500 ??       Sun Sep 27 09:00:02 2026     opencode run write the release notes
          503     1 ??       Sun Sep 27 09:00:03 2026     cursor-agent -p review the diff
        27805 27063 ??       Sun Sep 27 09:00:04 2026     /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
        84161     1 ??       Sun Sep 27 09:00:05 2026     /Users/me/.codex/bin/codex app-server daemon pid-update-loop
          600     1 ??       Sun Sep 27 09:00:06 2026     opencode serve --port 4096
          700     1 ??       Sun Sep 27 09:00:07 2026     claude -p plan the week
          701   700 ??       Sun Sep 27 09:00:08 2026     codex exec a sub-agent's task
        """, timeZone: Fixture.london)
        let found = TerminalAgentFinder.find(in: rows)
        #expect(found.map(\.process.pid) == [501, 502, 503, 700])
        #expect(found.allSatisfy { $0.terminal == .background })
    }

    /// A process list with the working directory of each process given by the test.
    struct FolderSource: ProcessSource {
        let text: String
        let folders: [Int32: String]
        func processList() throws -> String { text }
        func workingDirectory(of pid: Int32) -> String? { folders[pid] }
    }

    /// The app asks `kiro-cli` for the plan with no terminal, in a folder of its own. That is the
    /// app's question, not a session, so it is not listed; a Kiro run from a script is.
    @Test func theAppsOwnKiroPlanQuestionIsNotASession() async throws {
        let table = """
          PID  PPID TTY      STARTED                      COMMAND
            1     0 ??       Mon Aug 24 20:16:04 2026     /sbin/launchd
          700     1 ??       Sun Sep 27 09:00:00 2026     kiro-cli chat --no-interactive /usage
          701   700 ??       Sun Sep 27 09:00:01 2026     /Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat chat --no-interactive /usage
          800     1 ??       Sun Sep 27 09:00:02 2026     kiro-cli chat --no-interactive tidy the changelog
          900     1 ??       Sun Sep 27 09:00:03 2026     kiro-cli chat --no-interactive review the diff
        """
        let source = FolderSource(text: table, folders: [
            700: "/private/var/folders/x/T/" + KiroPlanReader.folderName,
            701: "/private/var/folders/x/T/" + KiroPlanReader.folderName,
            800: "/Users/me/shop",
            // Only a folder whose last name is the app's is the app's.
            900: "/Users/me/" + KiroPlanReader.folderName + "-notes",
        ])
        let repository = ProcessSessionRepository(
            source: source, homeDirectory: "/nonexistent/home", claudeDirectory: "/nonexistent",
            timeZone: Fixture.london
        )
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(records.sessionEvents.compactMap(\.origin?.pid) == [800, 900])
        #expect(!records.sessionEvents.contains { $0.sessionID == "kiro-700" })
        #expect(records.sessionEvents.allSatisfy { $0.agent == .kiro })
    }

    // MARK: - Session start from the session file

    @Test func theSessionStartHelperPrefersAGoodFileTimeAndGuardsBadOnes() {
        let now = Fixture.date("2026-10-02T12:00:00Z")
        let processStart = Fixture.date("2026-10-02T11:15:00Z")
        let realStart = Fixture.date("2026-10-02T07:51:00Z")
        // A file time hours before the process start, but not in the future or absurdly old, is used.
        #expect(ProcessSessionRepository.sessionStart(fileStart: realStart, processStart: processStart, now: now) == realStart)
        // No file time: the process start stands.
        #expect(ProcessSessionRepository.sessionStart(fileStart: nil, processStart: processStart, now: now) == processStart)
        // A file time in the future is not trusted.
        let future = now.addingTimeInterval(60 * 60)
        #expect(ProcessSessionRepository.sessionStart(fileStart: future, processStart: processStart, now: now) == processStart)
        // A file time older than the sane bound is not trusted.
        let ancient = now.addingTimeInterval(-ProcessSessionRepository.maxSessionAge - 1)
        #expect(ProcessSessionRepository.sessionStart(fileStart: ancient, processStart: processStart, now: now) == processStart)
    }

    /// A Kiro CLI session open for hours, whose `kiro-cli` process re-exec'd recently (so `ps`
    /// shows a start only minutes back). The session file's `created_at` is the true start, hours
    /// before, and the live `start` event must take it, so the strip's active time counts from
    /// the real start, not from the process restart.
    @Test func aKiroSessionStartsFromItsFileNotTheRestartedProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.path + "/shop"
        let sessions = root.appendingPathComponent(".kiro/sessions/cli")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // Times are set relative to the real clock the repository reads as `now`, so the guards
        // (not in the future, not absurdly old) pass whenever the test runs. The true start is
        // five hours ago; the process is a recent re-exec. The `ps` table is written in the
        // local zone so the parsed process start matches the intended minutes-ago time.
        let now = Date()
        let realStart = now.addingTimeInterval(-5 * 60 * 60)
        let processStart = now.addingTimeInterval(-45 * 60)
        let psFormatter = DateFormatter()
        psFormatter.locale = Locale(identifier: "en_US_POSIX")
        psFormatter.timeZone = Fixture.london
        psFormatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        // created_at is written in epoch seconds, which KiroSession.date reads the same as ISO text.
        try """
        {"session_id":"s-morning","cwd":"\(folder)","created_at":\(Int(realStart.timeIntervalSince1970))}
        """.write(to: sessions.appendingPathComponent("s-morning.json"), atomically: true, encoding: .utf8)
        let table = """
          PID  PPID TTY      STARTED                      COMMAND
            1     0 ??       Mon Aug 24 20:16:04 2026     /sbin/launchd
          800   700 ttys003  \(psFormatter.string(from: processStart))     kiro-cli chat
        """
        let source = FolderSource(text: table, folders: [800: folder])
        let repository = ProcessSessionRepository(
            source: source, homeDirectory: root.path, claudeDirectory: "/nonexistent", timeZone: Fixture.london
        )
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        let start = try #require(records.sessionEvents.first { $0.sessionID == "kiro-800" && $0.kind == .start })
        // The start takes the file time (five hours back), not the recent process start.
        #expect(abs(start.timestamp.timeIntervalSince(realStart)) < 1)
        #expect(start.timestamp.timeIntervalSince(processStart) < -60 * 60)
    }

    /// Other agents expose no session start, so their live start keeps the process start. Claude
    /// Code's start on the recorded list still reads from `ps`, unchanged by Fix B.
    @Test func otherAgentsKeepTheProcessStart() async throws {
        let repository = ProcessSessionRepository(
            source: RecordedSource(text: try Fixture.text("ps-2026-09-21.txt")),
            claudeDirectory: "/nonexistent", timeZone: Fixture.london
        )
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        let mine = try #require(records.sessionEvents.first { $0.sessionID == "claude-code-35056" && $0.kind == .start })
        #expect(mine.timestamp == Fixture.date("2026-09-21T21:00:49Z"))
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

    // MARK: - Warp tab links

    let tabLink = "warp://session/68e41dbb3b9145cd8714ffffcae1a24e"
    let otherTabLink = "warp://session/0123456789abcdef0123456789abcdef"

    /// Gives a Warp tab's `WARP_FOCUS_URL` to the processes it is told about, and remembers which
    /// processes were asked.
    final class TabLinkSource: ProcessSource {
        let text: String
        let links: [Int32: String]
        let asked = Mutex<[Int32]>([])
        init(_ text: String, links: [Int32: String]) {
            self.text = text
            self.links = links
        }
        func processList() throws -> String { text }
        func workingDirectory(of pid: Int32) -> String? { nil }
        func environmentValue(_ name: String, of pid: Int32) -> String? {
            asked.withLock { $0.append(pid) }
            return name == "WARP_FOCUS_URL" ? links[pid] : nil
        }
    }

    @Test func aWarpSessionCarriesTheLinkOfItsTab() async throws {
        // 3857 and 45226 run in Warp tabs, 35056 in tmux. The tmux one is given a link too, to
        // show that only Warp sessions are looked up.
        let source = TabLinkSource(
            try Fixture.text("ps-2026-09-21.txt"), links: [3857: tabLink, 45226: otherTabLink, 35056: tabLink]
        )
        let repository = ProcessSessionRepository(source: source, claudeDirectory: "/nonexistent", timeZone: Fixture.london)
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        func origin(_ pid: Int32) -> SessionOrigin? { records.sessionEvents.first { $0.origin?.pid == pid }?.origin }
        #expect(origin(3857)?.terminal == .warp)
        #expect(origin(3857)?.warpFocusURL == tabLink)
        #expect(origin(45226)?.warpFocusURL == otherTabLink)
        // In Warp, but that process had no link.
        #expect(origin(48718)?.terminal == .warp)
        #expect(origin(48718)?.warpFocusURL == nil)
        #expect(origin(35056)?.terminal == .tmux)
        #expect(origin(35056)?.warpFocusURL == nil)
        #expect(!source.asked.withLock { $0 }.contains(35056))
    }

    @Test func aLinkThatIsNotAWarpTabLinkIsDropped() async throws {
        let id = "68e41dbb3b9145cd8714ffffcae1a24e"
        let source = TabLinkSource(try Fixture.text("ps-2026-09-21.txt"), links: [
            3857: "warp://session/" + id.uppercased(),
            45226: "warp://session/\(id)\"; open -a Calculator",
            48718: "https://example.com/session/" + id,
            84087: "warp://session/" + id + "?x=1",
        ])
        let repository = ProcessSessionRepository(source: source, claudeDirectory: "/nonexistent", timeZone: Fixture.london)
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        for pid: Int32 in [3857, 45226, 48718, 84087] {
            let found = records.sessionEvents.first { $0.origin?.pid == pid }?.origin
            #expect(found?.terminal == .warp)
            #expect(found?.warpFocusURL == nil, "kept the value of \(pid)")
        }
    }

    @Test func aTabLinkIsReadWithTheSessionsFilesNotOnEveryRefresh() async throws {
        let source = TabLinkSource(try Fixture.text("ps-2026-09-21.txt"), links: [3857: tabLink])
        let repository = ProcessSessionRepository(source: source, claudeDirectory: "/nonexistent", timeZone: Fixture.london)
        let first = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        let warpPIDs = Set(first.sessionEvents.compactMap(\.origin).filter { $0.terminal == .warp }.map(\.pid))
        #expect(warpPIDs.contains(3857))
        #expect(Set(source.asked.withLock { $0 }) == warpPIDs)
        #expect(source.asked.withLock { $0 }.count == warpPIDs.count)
        // A couple of seconds later the link comes from what was read, and is still on the origin.
        let second = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(source.asked.withLock { $0 }.count == warpPIDs.count)
        #expect(second.sessionEvents.first { $0.origin?.pid == 3857 }?.origin?.warpFocusURL == tabLink)
    }

    @Test func aSourceThatCannotReadEnvironmentsLeavesTheLinkOut() async throws {
        let repository = ProcessSessionRepository(
            source: RecordedSource(text: try Fixture.text("ps-2026-09-21.txt")),
            claudeDirectory: "/nonexistent", timeZone: Fixture.london
        )
        let records = try await repository.sessionRecords(from: .distantPast, to: .distantFuture)
        #expect(records.sessionEvents.compactMap(\.origin).allSatisfy { $0.warpFocusURL == nil })
    }
}
