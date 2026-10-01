import Foundation
import Synchronization
import Testing
import UsageDomain
@testable import UsageData

/// Where a tmux client runs is read from the processes above it, over a made-up process table
/// with the shapes seen on the owner's Mac, never from live processes.
@Suite("Finding where a tmux client runs")
struct TmuxClientHostReaderTests {
    let tabLink = "warp://session/68e41dbb3b9145cd8714ffffcae1a24e"
    let otherTabLink = "warp://session/0123456789abcdef0123456789abcdef"

    /// - 45000: a client in a Warp tab, attached to agent-streams.
    /// - 903, 952, 962: clients in Terminal, iTerm and Ghostty windows.
    /// - 65001, 65011: clients in panes of the agent-streams server (64347), watching ticket sessions.
    /// - 70001: a client with no terminal app above it.
    static let table = """
      PID  PPID TTY      STARTED                      COMMAND
        1     0 ??       Mon Aug 24 12:00:00 2026     /sbin/launchd
      736     1 ??       Mon Aug 24 12:00:01 2026     /Applications/Warp.app/Contents/MacOS/stable
      839   736 ??       Mon Aug 24 12:00:02 2026     /Applications/Warp.app/Contents/MacOS/stable terminal-server --parent-pid=736
    44522   839 ttys033  Mon Aug 24 12:01:00 2026     -zsh -g --no_rcs
    45000 44522 ttys033  Mon Aug 24 12:01:05 2026     tmux attach-session -t agent-streams
      900     1 ??       Mon Aug 24 12:02:00 2026     /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
      901   900 ttys040  Mon Aug 24 12:02:01 2026     login -pf me
      902   901 ttys040  Mon Aug 24 12:02:01 2026     -zsh
      903   902 ttys040  Mon Aug 24 12:02:05 2026     tmux attach-session -t lead
      950     1 ??       Mon Aug 24 12:03:00 2026     /Applications/iTerm.app/Contents/MacOS/iTerm2
      951   950 ttys041  Mon Aug 24 12:03:01 2026     -zsh
      952   951 ttys041  Mon Aug 24 12:03:05 2026     tmux attach-session -t work
      960     1 ??       Mon Aug 24 12:03:30 2026     /Applications/Ghostty.app/Contents/MacOS/ghostty
      961   960 ttys042  Mon Aug 24 12:03:31 2026     -zsh
      962   961 ttys042  Mon Aug 24 12:03:35 2026     tmux attach-session -t play
    64347     1 ??       Mon Aug 24 12:00:30 2026     tmux new-session -d -s agent-streams
    65000 64347 ttys011  Mon Aug 24 12:04:00 2026     -zsh
    65001 65000 ttys011  Mon Aug 24 12:04:05 2026     tmux attach-session -t OKIOS-393-Catalogue
    65010 64347 ttys008  Mon Aug 24 12:05:00 2026     -zsh
    65011 65010 ttys008  Mon Aug 24 12:05:05 2026     tmux attach-session -t MSTUD-117-ImageJudge
    70001     1 ttys060  Mon Aug 24 12:06:00 2026     tmux attach-session -t orphan
    """

    /// The table above, with `WARP_FOCUS_URL` set to these links in these processes.
    func tableSource(_ links: [Int32: String] = [:]) -> ProcessSessionRepositoryTests.TabLinkSource {
        ProcessSessionRepositoryTests.TabLinkSource(Self.table, links: links)
    }

    @Test func aClientUnderWarpRunsInWarpWithItsTabLink() {
        let source = tableSource([45000: tabLink])
        #expect(TmuxClientHostReader(source: source).hosts(of: [45000])
            == [45000: TmuxClientHost(terminal: .warp, warpFocusURL: tabLink)])
    }

    @Test func aClientUnderTerminalRunsInTerminalWhateverLinkItCarries() {
        // The Terminal window was opened from a shell in a Warp tab, so its processes carry that
        // tab's link. The link is not even asked for.
        let source = tableSource([903: otherTabLink])
        #expect(TmuxClientHostReader(source: source).hosts(of: [903]) == [903: TmuxClientHost(terminal: .terminal)])
        #expect(source.asked.withLock { $0 }.isEmpty)
    }

    @Test func clientsUnderITermAndGhosttyRunThere() {
        let source = tableSource([952: tabLink, 962: tabLink])
        #expect(TmuxClientHostReader(source: source).hosts(of: [952, 962]) == [
            952: TmuxClientHost(terminal: .iterm),
            962: TmuxClientHost(terminal: .ghostty),
        ])
        #expect(source.asked.withLock { $0 }.isEmpty)
    }

    @Test func aClientInsideATmuxPaneRunsInTmuxWithNoLink() {
        // The server was first started in a Warp tab, so every pane carries that tab's link.
        let source = tableSource([65001: otherTabLink, 65011: otherTabLink])
        #expect(TmuxClientHostReader(source: source).hosts(of: [65001, 65011]) == [
            65001: TmuxClientHost(terminal: .tmux),
            65011: TmuxClientHost(terminal: .tmux),
        ])
        #expect(source.asked.withLock { $0 }.isEmpty)
    }

    @Test func aClientWithNoTerminalAboveItIsUnknown() {
        #expect(TmuxClientHostReader(source: tableSource()).hosts(of: [70001]) == [70001: TmuxClientHost(terminal: .unknown)])
    }

    @Test func aLinkThatIsNotAWarpTabLinkIsDropped() {
        let id = "68e41dbb3b9145cd8714ffffcae1a24e"
        for bad in ["warp://session/" + id.uppercased(), "warp://session/\(id)\"; open -a Calculator", "https://example.com/" + id, ""] {
            #expect(TmuxClientHostReader(source: tableSource([45000: bad])).hosts(of: [45000]) == [45000: TmuxClientHost(terminal: .warp)])
        }
        // A source that cannot read environments finds no link either.
        let blind = ProcessSessionRepositoryTests.RecordedSource(text: Self.table)
        #expect(TmuxClientHostReader(source: blind).hosts(of: [45000]) == [45000: TmuxClientHost(terminal: .warp)])
    }

    @Test func aProcessNotInTheTableIsLeftOutAndOnlyTheAskedOnesAreRead() {
        let source = tableSource([45000: tabLink, 65001: otherTabLink])
        let hosts = TmuxClientHostReader(source: source).hosts(of: [45000, 99999])
        #expect(Set(hosts.keys) == [45000])
        #expect(source.asked.withLock { $0 } == [45000])
        #expect(TmuxClientHostReader(source: source).hosts(of: []).isEmpty)
    }

    @Test func aProcessListThatCannotBeReadGivesNothing() {
        struct Broken: ProcessSource {
            func processList() throws -> String { throw CocoaError(.fileReadUnknown) }
            func workingDirectory(of pid: Int32) -> String? { nil }
        }
        #expect(TmuxClientHostReader(source: Broken()).hosts(of: [45000]).isEmpty)
    }

    // MARK: - From the clients to the steps

    func tmux(_ arguments: String...) -> TerminalFocusStep { .run(program: "tmux", arguments: arguments) }

    func origin(_ location: TmuxLocation, tty: String) -> SessionOrigin {
        // The app guessed for tmux is Warp, as the process-table repository would for this Mac.
        SessionOrigin(pid: 1, tty: tty, terminal: .tmux, folder: "/", tmux: location, hostTerminal: .warp)
    }

    /// The owner's setup: one tmux session, agent-streams, shown in one Warp tab, with each ticket
    /// session attached in a pane of it as a watcher; and lead, shown in a Terminal window.
    @Test func theAgentStreamsTabWithItsWatchersOpensThatTabAndLeadOpensTerminal() {
        let panes = TerminalFocus.panes(fromListPanes: """
        /dev/ttys011\tagent-streams\t@3\t%3
        /dev/ttys008\tagent-streams\t@2\t%2
        /dev/ttys009\tOKIOS-393-Catalogue\t@1\t%1
        /dev/ttys015\tMSTUD-117-ImageJudge\t@5\t%5
        /dev/ttys000\tlead\t@0\t%0
        """)
        let clients = TerminalFocus.clients(fromListClients: """
        /dev/ttys033\tagent-streams\t300\t45000
        /dev/ttys011\tOKIOS-393-Catalogue\t200\t65001
        /dev/ttys008\tMSTUD-117-ImageJudge\t150\t65011
        /dev/ttys040\tlead\t100\t903
        """)
        // Every client carries a Warp link, but only the one in the Warp tab carries its own.
        let source = tableSource([45000: tabLink, 65001: otherTabLink, 65011: otherTabLink, 903: otherTabLink])
        let hosts = TmuxClientHostReader(source: source).hosts(of: clients.compactMap(\.pid))
        #expect(hosts[45000] == TmuxClientHost(terminal: .warp, warpFocusURL: tabLink))
        #expect(hosts[903] == TmuxClientHost(terminal: .terminal))

        let okios = origin(TmuxLocation(session: "OKIOS-393-Catalogue", window: "@1", pane: "%1"), tty: "ttys009")
        #expect(TerminalFocus.plan(for: okios, panes: panes, clients: clients, hosts: hosts) == [
            tmux("switch-client", "-c", "/dev/ttys011", "-t", "=OKIOS-393-Catalogue"),
            tmux("select-window", "-t", "@1"),
            tmux("select-pane", "-t", "%1"),
            tmux("select-window", "-t", "@3"),
            tmux("select-pane", "-t", "%3"),
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
            .openURL(tabLink),
        ])

        let mstud = origin(TmuxLocation(session: "MSTUD-117-ImageJudge", window: "@5", pane: "%5"), tty: "ttys015")
        #expect(TerminalFocus.plan(for: mstud, panes: panes, clients: clients, hosts: hosts) == [
            tmux("switch-client", "-c", "/dev/ttys008", "-t", "=MSTUD-117-ImageJudge"),
            tmux("select-window", "-t", "@5"),
            tmux("select-pane", "-t", "%5"),
            tmux("select-window", "-t", "@2"),
            tmux("select-pane", "-t", "%2"),
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
            .openURL(tabLink),
        ])

        // lead is shown in Terminal: that window is chosen by the client's TTY, and no Warp tab
        // is opened, though the client carries a Warp link and Warp is what the app guessed.
        let lead = origin(TmuxLocation(session: "lead", window: "@0", pane: "%0"), tty: "ttys000")
        let steps = TerminalFocus.plan(for: lead, panes: panes, clients: clients, hosts: hosts)
        #expect(steps.count == 5)
        guard case .run("osascript", let arguments) = steps.first else { Issue.record("no script"); return }
        #expect(arguments.last?.contains("tell application \"Terminal\"") == true)
        #expect(arguments.last?.contains("if tty of t is \"/dev/ttys040\" then") == true)
        #expect(Array(steps.dropFirst()) == [
            .activate(bundleID: "com.apple.Terminal"),
            tmux("switch-client", "-c", "/dev/ttys040", "-t", "=lead"),
            tmux("select-window", "-t", "@0"),
            tmux("select-pane", "-t", "%0"),
        ])
        #expect(!steps.contains(.openURL(tabLink)) && !steps.contains(.openURL(otherTabLink)))
    }
}
