import Foundation
import Testing
@testable import UsageDomain

/// What the Open button does for each terminal, as a plan that is checked and never run.
@Suite("Open brings each kind of terminal to the front")
struct TerminalFocusTests {
    func origin(
        _ terminal: TerminalApp, tty: String = "ttys004", tmux: TmuxLocation? = nil, host: TerminalApp? = nil
    ) -> SessionOrigin {
        SessionOrigin(pid: 1, tty: tty, terminal: terminal, folder: "/", tmux: tmux, hostTerminal: host)
    }

    @Test func tmuxBringsItsTerminalForwardThenMovesToThePane() {
        let lead = origin(.tmux, tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        // Two terminal tabs, each with a tmux client; the second was used more recently.
        let clients = [
            TmuxClient(tty: "/dev/ttys001", session: "lead", activity: 100),
            TmuxClient(tty: "/dev/ttys009", session: "other", activity: 200),
        ]
        #expect(TerminalFocus.plan(for: lead, clients: clients) == [
            .activate(bundleID: "dev.warp.Warp-Stable"),
            // The tab the person is looking at is where the session is brought, since no
            // terminal lets a tab be chosen from outside.
            .run(program: "tmux", arguments: ["switch-client", "-c", "/dev/ttys009", "-t", "=lead"]),
            .run(program: "tmux", arguments: ["select-window", "-t", "@24"]),
            .run(program: "tmux", arguments: ["select-pane", "-t", "%24"]),
        ])
        #expect(TerminalFocus.canOpen(lead))
        #expect(TerminalFocus.action(for: lead) == .session)
    }

    @Test func theTabToMoveIsTheOneUsedLastAndTiesGoToTheOneAlreadyThere() {
        let clients = [
            TmuxClient(tty: "/dev/ttys001", session: "lead", activity: 100),
            TmuxClient(tty: "/dev/ttys009", session: "other", activity: 100),
            TmuxClient(tty: "/dev/ttys012", session: "third", activity: 90),
        ]
        // Used at the same moment: the tab already showing the session, so nothing moves needlessly.
        #expect(TerminalFocus.mostRecent(clients, showing: "lead")?.tty == "/dev/ttys001")
        // A tab used more recently wins.
        let newer = clients + [TmuxClient(tty: "/dev/ttys020", session: "fourth", activity: 300)]
        #expect(TerminalFocus.mostRecent(newer, showing: "lead")?.tty == "/dev/ttys020")
        #expect(TerminalFocus.mostRecent([], showing: "lead") == nil)
    }

    @Test func aTmuxPaneNotRecordedIsFoundByItsTTY() {
        let codex = origin(.tmux, tty: "ttys012", host: .terminal)
        let panes = TerminalFocus.panes(fromListPanes: """
        /dev/ttys003\tlead\t@1\t%1
        /dev/ttys012\twork\t@7\t%9
        """)
        #expect(TerminalFocus.plan(for: codex, panes: panes) == [
            .activate(bundleID: "com.apple.Terminal"),
            .run(program: "tmux", arguments: ["switch-client", "-t", "=work"]),
            .run(program: "tmux", arguments: ["select-window", "-t", "@7"]),
            .run(program: "tmux", arguments: ["select-pane", "-t", "%9"]),
        ])
        // No pane with that TTY: the terminal comes forward and tmux is left as it is.
        #expect(TerminalFocus.plan(for: codex, panes: []) == [.activate(bundleID: "com.apple.Terminal")])
    }

    @Test func aRecordedPaneThatIsStillThereIsUsed() {
        let lead = origin(.tmux, tty: "ttys004", tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        let panes = TerminalFocus.panes(fromListPanes: """
        /dev/ttys004\tlead\t@24\t%24
        /dev/ttys009\twork\t@7\t%9
        """)
        let found = TerminalFocus.location(for: lead, panes: panes)
        #expect(found.route == .recorded)
        #expect(found.location?.pane == "%24")
        #expect(TerminalFocus.plan(for: lead, panes: panes).contains(.run(program: "tmux", arguments: ["select-pane", "-t", "%24"])))
    }

    @Test func aRecordedPaneThatHasGoneIsFoundByTheSessionsTTY() {
        // The agent recorded %24, but that pane was closed; its process now sits in %31.
        let lead = origin(.tmux, tty: "ttys004", tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        let panes = TerminalFocus.panes(fromListPanes: "/dev/ttys004\tlead\t@30\t%31")
        let found = TerminalFocus.location(for: lead, panes: panes)
        #expect(found.route == .byTTY)
        #expect(found.location == TmuxLocation(session: "lead", window: "@30", pane: "%31"))
        let steps = TerminalFocus.plan(for: lead, panes: panes)
        #expect(steps.contains(.run(program: "tmux", arguments: ["select-window", "-t", "@30"])))
        #expect(steps.contains(.run(program: "tmux", arguments: ["select-pane", "-t", "%31"])))
        #expect(!steps.contains(.run(program: "tmux", arguments: ["select-pane", "-t", "%24"])))
    }

    @Test func withNeitherTheRecordedPaneNorTheTTYTmuxIsLeftAlone() {
        let lead = origin(.tmux, tty: "ttys004", tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        // tmux knows nothing of that session or that TTY any more.
        let panes = TerminalFocus.panes(fromListPanes: "/dev/ttys009\twork\t@7\t%9")
        let found = TerminalFocus.location(for: lead, panes: panes)
        #expect(found.route == .none)
        #expect(found.location == nil)
        // Only the terminal is brought forward; no tmux command is run.
        #expect(TerminalFocus.plan(for: lead, panes: panes) == [.activate(bundleID: "dev.warp.Warp-Stable")])
    }

    @Test func withNoListOfPanesTheRecordedOneIsAllThereIs() {
        let lead = origin(.tmux, tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        #expect(TerminalFocus.location(for: lead, panes: []).route == .recorded)
    }

    @Test func terminalSelectsTheTabByItsTTYWithItsOwnScripting() {
        let plan = TerminalFocus.plan(for: origin(.terminal))
        #expect(plan.count == 2)
        guard case .run(let program, let arguments) = plan.first else { Issue.record("no script"); return }
        #expect(program == "osascript")
        #expect(arguments.first == "-e")
        let script = arguments.last ?? ""
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("if tty of t is \"/dev/ttys004\" then"))
        #expect(script.contains("set selected of t to true"))
        // It chooses a tab. It never types or presses keys.
        #expect(!script.contains("keystroke") && !script.contains("System Events") && !script.contains("do script"))
        #expect(plan.last == .activate(bundleID: "com.apple.Terminal"))
    }

    @Test func aTTYThatIsNotOneNeverReachesTheScript() {
        let odd = origin(.terminal, tty: "ttys004\" & do shell script \"x")
        #expect(TerminalFocus.plan(for: odd) == [.activate(bundleID: "com.apple.Terminal")])
        #expect(TerminalFocus.action(for: odd) == .application(.terminal))
        #expect(TerminalFocus.safeTTY("/dev/ttys004") == "/dev/ttys004")
        #expect(TerminalFocus.safeTTY("ttys004") == "/dev/ttys004")
        #expect(TerminalFocus.safeTTY("console") == nil)
    }

    @Test func warpITermAndGhosttyAreOnlyBroughtForward() {
        #expect(TerminalFocus.plan(for: origin(.warp)) == [.activate(bundleID: "dev.warp.Warp-Stable")])
        #expect(TerminalFocus.plan(for: origin(.iterm)) == [.activate(bundleID: "com.googlecode.iterm2")])
        #expect(TerminalFocus.plan(for: origin(.ghostty)) == [.activate(bundleID: "com.mitchellh.ghostty")])
        #expect(TerminalFocus.action(for: origin(.warp)) == .application(.warp))
        #expect(TerminalFocus.action(for: origin(.iterm)) == .application(.iterm))
        #expect(TerminalFocus.action(for: origin(.ghostty)) == .application(.ghostty))
    }

    @Test func anUnknownTerminalHasNoOpenButton() {
        #expect(TerminalFocus.plan(for: origin(.unknown)).isEmpty)
        #expect(!TerminalFocus.canOpen(origin(.unknown)))
        #expect(TerminalFocus.action(for: origin(.unknown)) == nil)
        // tmux with neither a known pane nor a known terminal has nothing to open either.
        #expect(!TerminalFocus.canOpen(origin(.tmux)))
    }

    @Test func claudeCodesTmuxFieldIsReadAsSessionWindowAndPane() {
        #expect(TmuxLocation.parse("ai-usage-tracker:@24.%24")
            == TmuxLocation(session: "ai-usage-tracker", window: "@24", pane: "%24"))
        #expect(TmuxLocation.parse("lead") == TmuxLocation(session: "lead"))
        #expect(TmuxLocation.parse("") == nil)
        #expect(TmuxLocation.parse(":@1.%1") == nil)
    }

    @Test func tmuxsListsAreRead() {
        #expect(TerminalFocus.clients(fromListClients: "/dev/ttys009\tlead\t1790102753\n\n")
            == [TmuxClient(tty: "/dev/ttys009", session: "lead", activity: 1_790_102_753)])
        // An older tmux, which does not say when a client was last used.
        #expect(TerminalFocus.clients(fromListClients: "/dev/ttys009\tlead") == [TmuxClient(tty: "/dev/ttys009", session: "lead")])
        #expect(TerminalFocus.panes(fromListPanes: "garbage\n").isEmpty)
    }
}
