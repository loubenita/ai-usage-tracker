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

    @Test func tmuxUsesTheClientAlreadyShowingTheTargetSession() {
        let lead = origin(.tmux, tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        // The other tab was used more recently, but the target is already visible in the first
        // tab. Selecting that client keeps Open from silently moving a different terminal tab.
        let clients = [
            TmuxClient(tty: "/dev/ttys001", session: "lead", activity: 100),
            TmuxClient(tty: "/dev/ttys009", session: "other", activity: 200),
        ]
        #expect(TerminalFocus.plan(for: lead, clients: clients) == [
            .activate(bundleID: "dev.warp.Warp-Stable"),
            .run(program: "tmux", arguments: ["switch-client", "-c", "/dev/ttys001", "-t", "=lead"]),
            .run(program: "tmux", arguments: ["select-window", "-t", "@24"]),
            .run(program: "tmux", arguments: ["select-pane", "-t", "%24"]),
        ])
        #expect(TerminalFocus.canOpen(lead))
        #expect(TerminalFocus.action(for: lead) == .session)
    }

    @Test func tmuxFallsBackToTheMostRecentClientOnlyWhenNoClientShowsTheSession() {
        let clients = [
            TmuxClient(tty: "/dev/ttys001", session: "lead", activity: 100),
            TmuxClient(tty: "/dev/ttys009", session: "other", activity: 100),
            TmuxClient(tty: "/dev/ttys012", session: "third", activity: 90),
        ]
        // A matching client always wins, even if another client was used more recently.
        #expect(TerminalFocus.mostRecent(clients, showing: "lead")?.tty == "/dev/ttys001")
        // With no matching client, the most recently used one is the deterministic fallback.
        let newer = clients + [TmuxClient(tty: "/dev/ttys020", session: "fourth", activity: 300)]
        #expect(TerminalFocus.mostRecent(newer, showing: "missing")?.tty == "/dev/ttys020")
        // Session names must match exactly: "lead-west" is not the "lead" session.
        let similarlyNamed = [
            TmuxClient(tty: "/dev/ttys003", session: "lead-west", activity: 400),
            TmuxClient(tty: "/dev/ttys002", session: "lead", activity: 1),
        ]
        #expect(TerminalFocus.mostRecent(similarlyNamed, showing: "lead")?.tty == "/dev/ttys002")
        let tiedFallback = [
            TmuxClient(tty: "/dev/ttys009", session: "other", activity: 10),
            TmuxClient(tty: "/dev/ttys001", session: "third", activity: 10),
        ]
        #expect(TerminalFocus.mostRecent(tiedFallback, showing: "missing")?.tty == "/dev/ttys001")
        #expect(TerminalFocus.mostRecent([], showing: "lead") == nil)
    }

    @Test func aTmuxPaneNotRecordedIsFoundByItsTTY() {
        let codex = origin(.tmux, tty: "ttys012", host: .terminal)
        let panes = TerminalFocus.panes(fromListPanes: """
        /dev/ttys003\tlead\t@1\t%1
        /dev/ttys012\twork\t@7\t%9
        """)
        let clients = [TmuxClient(tty: "/dev/ttys001", session: "lead", activity: 100)]
        #expect(TerminalFocus.plan(for: codex, panes: panes, clients: clients) == [
            .activate(bundleID: "com.apple.Terminal"),
            .run(program: "tmux", arguments: ["switch-client", "-c", "/dev/ttys001", "-t", "=work"]),
            .run(program: "tmux", arguments: ["select-window", "-t", "@7"]),
            .run(program: "tmux", arguments: ["select-pane", "-t", "%9"]),
        ])
        // No pane with that TTY: the terminal comes forward and tmux is left as it is.
        #expect(TerminalFocus.plan(for: codex, panes: []) == [.activate(bundleID: "com.apple.Terminal")])
        // With no attached tmux client, tmux has nowhere to show the session.
        #expect(TerminalFocus.plan(for: codex, panes: panes) == [.activate(bundleID: "com.apple.Terminal")])
    }

    func tmux(_ arguments: String...) -> TerminalFocusStep { .run(program: "tmux", arguments: arguments) }

    // The owner's Mac: the client showing OKIOS-393-Catalogue (ttys011) runs in a pane of
    // agent-streams (window 3), and agent-streams is shown by ttys033, a Warp tab.
    let nestedPanes = TerminalFocus.panes(fromListPanes: """
    /dev/ttys009\tOKIOS-393-Catalogue\t@1\t%1
    /dev/ttys008\tagent-streams\t@2\t%2
    /dev/ttys011\tagent-streams\t@3\t%3
    /dev/ttys000\tlead\t@0\t%0
    """)
    let nestedClients = TerminalFocus.clients(fromListClients: """
    /dev/ttys033\tagent-streams\t300
    /dev/ttys011\tOKIOS-393-Catalogue\t200
    /dev/ttys018\tlead\t100
    /dev/ttys008\tMSTUD-117-ImageJudge\t150
    """)

    @Test func aSessionShownInsideAnotherTmuxSessionSelectsTheOuterPaneToo() {
        let okios = origin(.tmux, tty: "ttys009", tmux: TmuxLocation(session: "OKIOS-393-Catalogue", window: "@1", pane: "%1"), host: .warp)
        #expect(TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClients) == [
            .activate(bundleID: "dev.warp.Warp-Stable"),
            tmux("switch-client", "-c", "/dev/ttys011", "-t", "=OKIOS-393-Catalogue"),
            tmux("select-window", "-t", "@1"),
            tmux("select-pane", "-t", "%1"),
            // ttys011 is the pane agent-streams:3, so agent-streams is moved to that window...
            tmux("select-window", "-t", "@3"),
            tmux("select-pane", "-t", "%3"),
            // ...and shown by the client that is in the Warp tab.
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
        ])
    }

    @Test func aSessionNotShownInsideAnotherTmuxSessionKeepsTheSameSteps() {
        // The client showing lead (ttys018) is a Warp tab: no pane has its tty.
        let lead = origin(.tmux, tty: "ttys000", tmux: TmuxLocation(session: "lead", window: "@0", pane: "%0"), host: .warp)
        #expect(TerminalFocus.plan(for: lead, panes: nestedPanes, clients: nestedClients) == [
            .activate(bundleID: "dev.warp.Warp-Stable"),
            tmux("switch-client", "-c", "/dev/ttys018", "-t", "=lead"),
            tmux("select-window", "-t", "@0"),
            tmux("select-pane", "-t", "%0"),
        ])
    }

    @Test func twoSessionsShownInsideEachOtherAreWalkedOnlyOnce() {
        // alpha's client runs in a pane of beta, and beta's client runs in a pane of alpha.
        let panes = TerminalFocus.panes(fromListPanes: """
        /dev/ttys001\talpha\t@1\t%1
        /dev/ttys002\tbeta\t@2\t%2
        /dev/ttys005\talpha\t@5\t%5
        """)
        let clients = [
            TmuxClient(tty: "/dev/ttys002", session: "alpha", activity: 10),
            TmuxClient(tty: "/dev/ttys001", session: "beta", activity: 20),
        ]
        let agent = origin(.tmux, tty: "ttys005", tmux: TmuxLocation(session: "alpha", window: "@5", pane: "%5"), host: .warp)
        #expect(TerminalFocus.plan(for: agent, panes: panes, clients: clients) == [
            .activate(bundleID: "dev.warp.Warp-Stable"),
            tmux("switch-client", "-c", "/dev/ttys002", "-t", "=alpha"),
            tmux("select-window", "-t", "@5"),
            tmux("select-pane", "-t", "%5"),
            tmux("select-window", "-t", "@2"),
            tmux("select-pane", "-t", "%2"),
            tmux("switch-client", "-c", "/dev/ttys001", "-t", "=beta"),
            // The next client is in a pane of alpha, which is done already: the walk ends.
        ])
    }

    @Test func anOuterSessionWithNoClientStopsAfterItsPaneIsSelected() {
        let clients = [TmuxClient(tty: "/dev/ttys011", session: "OKIOS-393-Catalogue", activity: 200)]
        let okios = origin(.tmux, tty: "ttys009", tmux: TmuxLocation(session: "OKIOS-393-Catalogue", window: "@1", pane: "%1"), host: .warp)
        // Nothing shows agent-streams, so only the pane is selected. The only client there is
        // must not be switched to agent-streams, which it runs inside.
        #expect(TerminalFocus.plan(for: okios, panes: nestedPanes, clients: clients) == [
            .activate(bundleID: "dev.warp.Warp-Stable"),
            tmux("switch-client", "-c", "/dev/ttys011", "-t", "=OKIOS-393-Catalogue"),
            tmux("select-window", "-t", "@1"),
            tmux("select-pane", "-t", "%1"),
            tmux("select-window", "-t", "@3"),
            tmux("select-pane", "-t", "%3"),
        ])
    }

    @Test func aLongChainOfNestedSessionsIsFollowedForFourLevelsOnly() {
        // s0 is shown inside s1, which is shown inside s2, and so on up to s6 in a Warp tab.
        let panes = (1...6).map { level in
            TmuxPane(tty: "/dev/ttys10\(level - 1)", location: TmuxLocation(session: "s\(level)", window: "@\(level)", pane: "%\(level)"))
        } + [TmuxPane(tty: "/dev/ttys200", location: TmuxLocation(session: "s0", window: "@0", pane: "%0"))]
        let clients = (0...6).map { TmuxClient(tty: "/dev/ttys10\($0)", session: "s\($0)", activity: Double($0)) }
        let agent = origin(.tmux, tty: "ttys200", tmux: TmuxLocation(session: "s0", window: "@0", pane: "%0"))
        let switches = TerminalFocus.plan(for: agent, panes: panes, clients: clients).filter {
            if case .run(_, let arguments) = $0 { return arguments.first == "switch-client" }
            return false
        }
        // The session itself, then four outer sessions: s1 to s4. s5 is not reached.
        #expect(switches == (0...4).map { tmux("switch-client", "-c", "/dev/ttys10\($0)", "-t", "=s\($0)") })
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
        let clients = [TmuxClient(tty: "/dev/ttys004", session: "lead", activity: 1)]
        #expect(TerminalFocus.plan(for: lead, panes: panes, clients: clients).contains(.run(program: "tmux", arguments: ["select-pane", "-t", "%24"])))
    }

    @Test func aRecordedPaneThatHasGoneIsFoundByTheSessionsTTY() {
        // The agent recorded %24, but that pane was closed; its process now sits in %31.
        let lead = origin(.tmux, tty: "ttys004", tmux: TmuxLocation(session: "lead", window: "@24", pane: "%24"), host: .warp)
        let panes = TerminalFocus.panes(fromListPanes: "/dev/ttys004\tlead\t@30\t%31")
        let found = TerminalFocus.location(for: lead, panes: panes)
        #expect(found.route == .byTTY)
        #expect(found.location == TmuxLocation(session: "lead", window: "@30", pane: "%31"))
        let clients = [TmuxClient(tty: "/dev/ttys004", session: "lead", activity: 1)]
        let steps = TerminalFocus.plan(for: lead, panes: panes, clients: clients)
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

    @Test func iTermSelectsTheSessionTabAndWindowByTTY() {
        let plan = TerminalFocus.plan(for: origin(.iterm))
        #expect(plan.count == 2)
        guard case .run(let program, let arguments) = plan.first else { Issue.record("no script"); return }
        #expect(program == "osascript")
        #expect(arguments.first == "-e")
        let script = arguments.last ?? ""
        #expect(script.contains("tell application \"iTerm2\""))
        #expect(script.contains("if tty of s is \"/dev/ttys004\" then"))
        #expect(script.contains("select w"))
        #expect(script.contains("select t"))
        #expect(script.contains("select s"))
        // It selects existing iTerm objects. It never sends text, keys, or mouse events.
        #expect(!script.contains("write text") && !script.contains("keystroke") && !script.contains("System Events"))
        #expect(plan.last == .activate(bundleID: "com.googlecode.iterm2"))
        #expect(TerminalFocus.action(for: origin(.iterm)) == .session)
    }

    @Test func aTTYThatIsNotOneNeverReachesTheScript() {
        let odd = origin(.terminal, tty: "ttys004\" & do shell script \"x")
        #expect(TerminalFocus.plan(for: odd) == [.activate(bundleID: "com.apple.Terminal")])
        #expect(TerminalFocus.action(for: odd) == .application(.terminal))
        let iTermOdd = origin(.iterm, tty: odd.tty)
        #expect(TerminalFocus.plan(for: iTermOdd) == [.activate(bundleID: "com.googlecode.iterm2")])
        #expect(TerminalFocus.action(for: iTermOdd) == .application(.iterm))
        #expect(TerminalFocus.safeTTY("/dev/ttys004") == "/dev/ttys004")
        #expect(TerminalFocus.safeTTY("ttys004") == "/dev/ttys004")
        #expect(TerminalFocus.safeTTY("console") == nil)
    }

    @Test func warpAndGhosttyAreOnlyBroughtForward() {
        #expect(TerminalFocus.plan(for: origin(.warp)) == [.activate(bundleID: "dev.warp.Warp-Stable")])
        #expect(TerminalFocus.plan(for: origin(.ghostty)) == [.activate(bundleID: "com.mitchellh.ghostty")])
        #expect(TerminalFocus.action(for: origin(.warp)) == .application(.warp))
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
