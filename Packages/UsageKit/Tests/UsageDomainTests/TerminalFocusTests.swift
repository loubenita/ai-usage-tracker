import Foundation
import Testing
@testable import UsageDomain

/// What the Open button does for each terminal, as a plan that is checked and never run.
@Suite("Open brings each kind of terminal to the front")
struct TerminalFocusTests {
    func origin(
        _ terminal: TerminalApp, tty: String = "ttys004", tmux: TmuxLocation? = nil, host: TerminalApp? = nil,
        warpFocusURL: String? = nil
    ) -> SessionOrigin {
        SessionOrigin(
            pid: 1, tty: tty, terminal: terminal, folder: "/", tmux: tmux, hostTerminal: host, warpFocusURL: warpFocusURL
        )
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

    func opensALink(_ steps: [TerminalFocusStep]) -> Bool {
        steps.contains { step in
            if case .openURL = step { return true }
            return false
        }
    }

    func runsAScript(_ steps: [TerminalFocusStep]) -> Bool {
        steps.contains { step in
            if case .run("osascript", _) = step { return true }
            return false
        }
    }

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

    @Test func ghosttyIsOnlyBroughtForward() {
        #expect(TerminalFocus.plan(for: origin(.ghostty)) == [.activate(bundleID: "com.mitchellh.ghostty")])
        #expect(TerminalFocus.action(for: origin(.ghostty)) == .application(.ghostty))
        // Ghostty has no tab link, so one that happens to be on the origin changes nothing.
        let withLink = origin(.ghostty, warpFocusURL: warpLink)
        #expect(TerminalFocus.plan(for: withLink) == [.activate(bundleID: "com.mitchellh.ghostty")])
    }

    // MARK: - Warp tabs

    /// A real one: what `WARP_FOCUS_URL` held in a Warp tab on the owner's Mac.
    let warpLink = "warp://session/68e41dbb3b9145cd8714ffffcae1a24e"
    let otherWarpLink = "warp://session/0123456789abcdef0123456789abcdef"

    @Test func aWarpSessionOpensItsOwnTabThroughTheLinkWarpGivesIt() {
        let session = origin(.warp, warpFocusURL: warpLink)
        // Opening the link makes Warp come forward by itself, so there is nothing to activate.
        #expect(TerminalFocus.plan(for: session) == [.openURL(warpLink)])
        // It reaches the session itself, so the button says Open, not Bring forward.
        #expect(TerminalFocus.action(for: session) == .session)
        #expect(TerminalFocus.canOpen(session))
    }

    @Test func aWarpSessionWithoutALinkIsOnlyBroughtForward() {
        #expect(TerminalFocus.plan(for: origin(.warp)) == [.activate(bundleID: "dev.warp.Warp-Stable")])
        #expect(TerminalFocus.action(for: origin(.warp)) == .application(.warp))
        #expect(TerminalFocus.canOpen(origin(.warp)))
    }

    @Test func aWarpLinkThatIsNotOneIsNeverPlanned() {
        for bad in ["warp://session/ABC", "warp://session/\(String(repeating: "A", count: 32))", "x\"; rm -rf ~", ""] {
            let session = origin(.warp, warpFocusURL: bad)
            #expect(TerminalFocus.plan(for: session) == [.activate(bundleID: "dev.warp.Warp-Stable")])
            #expect(TerminalFocus.action(for: session) == .application(.warp))
        }
    }

    /// The owner's layout from the nested test, with the process of each client as tmux names it.
    /// ttys033 is the client in the Warp tab; ttys011 runs inside a pane of agent-streams.
    let nestedClientsWithPids = TerminalFocus.clients(fromListClients: """
    /dev/ttys033\tagent-streams\t300\t4001
    /dev/ttys011\tOKIOS-393-Catalogue\t200\t4002
    /dev/ttys018\tlead\t100\t4003
    /dev/ttys008\tMSTUD-117-ImageJudge\t150\t4004
    """)

    func warp(_ link: String? = nil) -> TmuxClientHost { TmuxClientHost(terminal: .warp, warpFocusURL: link) }

    let okiosLocation = TmuxLocation(session: "OKIOS-393-Catalogue", window: "@1", pane: "%1")
    let leadLocation = TmuxLocation(session: "lead", window: "@0", pane: "%0")

    @Test func nestedTmuxInWarpBringsTheOutermostClientsTabForwardLast() {
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        // The host of every client is known; only the outermost switched one (ttys033) counts.
        let hosts: [Int32: TmuxClientHost] = [4001: warp(warpLink), 4002: TmuxClientHost(terminal: .tmux), 4003: warp(otherWarpLink)]
        #expect(TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: hosts) == [
            tmux("switch-client", "-c", "/dev/ttys011", "-t", "=OKIOS-393-Catalogue"),
            tmux("select-window", "-t", "@1"),
            tmux("select-pane", "-t", "%1"),
            tmux("select-window", "-t", "@3"),
            tmux("select-pane", "-t", "%3"),
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
            // After the tmux steps, so the tab comes forward already showing the right window.
            .openURL(warpLink),
        ])
    }

    @Test func theInnerClientsHostIsNeverUsed() {
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        // ttys011 runs in a pane of agent-streams, whose server was first started in another tab:
        // its environment can hold that tab's link, but the client is not in that tab.
        let both = TerminalFocus.plan(
            for: okios, panes: nestedPanes, clients: nestedClientsWithPids,
            hosts: [4001: warp(warpLink), 4002: warp(otherWarpLink)]
        )
        #expect(both.filter { $0 == .openURL(otherWarpLink) }.isEmpty)
        #expect(both.last == .openURL(warpLink))
        // With nothing known about the outer client, the inner one is not used in its place.
        let innerOnly = TerminalFocus.plan(
            for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4002: warp(otherWarpLink)]
        )
        #expect(innerOnly == TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClientsWithPids))
        #expect(innerOnly.first == .activate(bundleID: "dev.warp.Warp-Stable"))
        #expect(!opensALink(innerOnly))
    }

    @Test func everyWatcherOfAnAgentStreamsTabOpensThatTab() {
        // The owner's setup: one tmux session, agent-streams, is shown in one Warp tab (ttys033),
        // and each ticket session is attached in a pane of it as a watcher (ttys011, ttys008).
        let panes = nestedPanes + [
            TmuxPane(tty: "/dev/ttys015", location: TmuxLocation(session: "MSTUD-117-ImageJudge", window: "@5", pane: "%5")),
            TmuxPane(tty: "/dev/ttys016", location: TmuxLocation(session: "agent-streams", window: "@9", pane: "%9")),
        ]
        // Each watcher's client has the link of the tab the server was first started in.
        let hosts: [Int32: TmuxClientHost] = [4001: warp(warpLink), 4002: warp(otherWarpLink), 4004: warp(otherWarpLink)]
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        #expect(TerminalFocus.plan(for: okios, panes: panes, clients: nestedClientsWithPids, hosts: hosts) == [
            tmux("switch-client", "-c", "/dev/ttys011", "-t", "=OKIOS-393-Catalogue"),
            tmux("select-window", "-t", "@1"),
            tmux("select-pane", "-t", "%1"),
            tmux("select-window", "-t", "@3"),
            tmux("select-pane", "-t", "%3"),
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
            .openURL(warpLink),
        ])
        // The next watcher is in another window of the same session, the same Warp tab.
        let mstud = origin(.tmux, tty: "ttys015", tmux: TmuxLocation(session: "MSTUD-117-ImageJudge", window: "@5", pane: "%5"), host: .warp)
        #expect(TerminalFocus.plan(for: mstud, panes: panes, clients: nestedClientsWithPids, hosts: hosts) == [
            tmux("switch-client", "-c", "/dev/ttys008", "-t", "=MSTUD-117-ImageJudge"),
            tmux("select-window", "-t", "@5"),
            tmux("select-pane", "-t", "%5"),
            tmux("select-window", "-t", "@2"),
            tmux("select-pane", "-t", "%2"),
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
            .openURL(warpLink),
        ])
        // A session of agent-streams itself is shown by that same tab.
        let streams = origin(.tmux, tty: "ttys016", tmux: TmuxLocation(session: "agent-streams", window: "@9", pane: "%9"), host: .warp)
        #expect(TerminalFocus.plan(for: streams, panes: panes, clients: nestedClientsWithPids, hosts: hosts) == [
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
            tmux("select-window", "-t", "@9"),
            tmux("select-pane", "-t", "%9"),
            .openURL(warpLink),
        ])
    }

    @Test func tmuxInWarpKeepsTheSameStepsWhenNoHostIsKnown() {
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        let today = TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClients)
        #expect(today.first == .activate(bundleID: "dev.warp.Warp-Stable"))
        #expect(!opensALink(today))
        // No hosts at all, hosts for other processes only, and a client inside a tmux pane, or
        // with no terminal found, which say nothing about a window to bring forward.
        let plan = { (hosts: [Int32: TmuxClientHost]) in
            TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: hosts)
        }
        #expect(plan([:]) == today)
        #expect(plan([9999: warp(warpLink)]) == today)
        for terminal in [TerminalApp.tmux, .unknown, .background] {
            #expect(plan([4001: TmuxClientHost(terminal: terminal, warpFocusURL: warpLink)]) == today)
        }
        // Clients that tmux gave no pid for cannot be looked up.
        #expect(TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClients, hosts: [4001: warp(warpLink)]) == today)
    }

    @Test func tmuxInWarpWithoutALinkBringsWarpForwardFirst() {
        // Even when the app guessed for tmux is another one: the client says it is in Warp.
        for guess in [TerminalApp.warp, .terminal] {
            let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: guess)
            let steps = TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4001: warp()])
            #expect(steps.first == .activate(bundleID: "dev.warp.Warp-Stable"))
            #expect(!opensALink(steps))
            #expect(steps.count == 7)
            // A link that is not a Warp link is no link.
            let bad = TerminalFocus.plan(
                for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4001: warp("warp://session/xyz")]
            )
            #expect(bad == steps)
        }
    }

    @Test func tmuxInWarpWithoutNestingOpensThatClientsTab() {
        // The client showing lead (ttys018) is a Warp tab itself: no pane has its tty.
        let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: .warp)
        #expect(TerminalFocus.plan(for: lead, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4003: warp(warpLink)]) == [
            tmux("switch-client", "-c", "/dev/ttys018", "-t", "=lead"),
            tmux("select-window", "-t", "@0"),
            tmux("select-pane", "-t", "%0"),
            .openURL(warpLink),
        ])
    }

    @Test func aClientInsideAnotherTmuxPaneBringsTheGuessedAppForward() {
        // Nothing shows agent-streams, so the walk ends at ttys011, a client inside a pane: it has
        // no window of its own to bring forward.
        let clients = [TmuxClient(tty: "/dev/ttys011", session: "OKIOS-393-Catalogue", activity: 200, pid: 4002)]
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        let plan = TerminalFocus.plan(for: okios, panes: nestedPanes, clients: clients, hosts: [4002: TmuxClientHost(terminal: .tmux)])
        #expect(plan == TerminalFocus.plan(for: okios, panes: nestedPanes, clients: clients))
        #expect(plan.first == .activate(bundleID: "dev.warp.Warp-Stable"))
    }

    // MARK: - tmux shown in other terminals

    /// What bringing the terminal forward and then tmux to lead looks like for the client ttys018.
    func leadSteps(before: [TerminalFocusStep]) -> [TerminalFocusStep] {
        before + [
            tmux("switch-client", "-c", "/dev/ttys018", "-t", "=lead"),
            tmux("select-window", "-t", "@0"),
            tmux("select-pane", "-t", "%0"),
        ]
    }

    func terminalWindow(of tty: String) -> [TerminalFocusStep] {
        [
            .run(program: "osascript", arguments: ["-e", TerminalFocus.terminalScript(tty: tty)]),
            .activate(bundleID: "com.apple.Terminal"),
        ]
    }

    @Test func tmuxShownInTerminalSelectsTheClientsTabByItsTTY() {
        let hosts: [Int32: TmuxClientHost] = [4003: TmuxClientHost(terminal: .terminal)]
        // The app guessed for tmux is Warp, which is wrong here: the plan follows the client.
        for guess in [TerminalApp.warp, .terminal] {
            let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: guess)
            let steps = TerminalFocus.plan(for: lead, panes: nestedPanes, clients: nestedClientsWithPids, hosts: hosts)
            #expect(steps == leadSteps(before: terminalWindow(of: "/dev/ttys018")))
            #expect(!opensALink(steps))
        }
    }

    @Test func aTerminalClientIgnoresTheWarpLinkItCarries() {
        // The Terminal window was opened from a Warp tab, so the client inherited that tab's link.
        let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: .warp)
        let carrying: [Int32: TmuxClientHost] = [4003: TmuxClientHost(terminal: .terminal, warpFocusURL: warpLink)]
        let steps = TerminalFocus.plan(for: lead, panes: nestedPanes, clients: nestedClientsWithPids, hosts: carrying)
        #expect(steps == leadSteps(before: terminalWindow(of: "/dev/ttys018")))
        #expect(!opensALink(steps))
    }

    @Test func nestedTmuxInTerminalSelectsTheOutermostClientsTab() {
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        let hosts: [Int32: TmuxClientHost] = [4001: TmuxClientHost(terminal: .terminal), 4002: warp(otherWarpLink)]
        #expect(TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: hosts) == terminalWindow(of: "/dev/ttys033") + [
            tmux("switch-client", "-c", "/dev/ttys011", "-t", "=OKIOS-393-Catalogue"),
            tmux("select-window", "-t", "@1"),
            tmux("select-pane", "-t", "%1"),
            tmux("select-window", "-t", "@3"),
            tmux("select-pane", "-t", "%3"),
            tmux("switch-client", "-c", "/dev/ttys033", "-t", "=agent-streams"),
        ])
    }

    @Test func tmuxShownInITermSelectsTheClientsSessionByItsTTY() {
        let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: .warp)
        let steps = TerminalFocus.plan(for: lead, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4003: TmuxClientHost(terminal: .iterm)])
        #expect(steps == leadSteps(before: [
            .run(program: "osascript", arguments: ["-e", TerminalFocus.iTermScript(tty: "/dev/ttys018")]),
            .activate(bundleID: "com.googlecode.iterm2"),
        ]))
    }

    @Test func tmuxShownInGhosttyBringsGhosttyForwardFirst() {
        let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: .warp)
        let steps = TerminalFocus.plan(for: lead, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4003: TmuxClientHost(terminal: .ghostty)])
        #expect(steps == leadSteps(before: [.activate(bundleID: "com.mitchellh.ghostty")]))
    }

    @Test func aClientTTYThatIsNotOneNeverReachesTheScript() {
        let odd = TmuxClient(tty: "ttys018\" & do shell script \"x", session: "lead", activity: 1, pid: 4003)
        let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: .warp)
        for terminal in [TerminalApp.terminal, .iterm] {
            let steps = TerminalFocus.plan(for: lead, panes: nestedPanes, clients: [odd], hosts: [4003: TmuxClientHost(terminal: terminal)])
            #expect(steps.first == .activate(bundleID: TerminalFocus.bundleID(of: terminal)!))
            #expect(!runsAScript(steps))
        }
    }

    @Test func withNoClientToSwitchOnlyTheGuessedAppIsBroughtForward() {
        // Hosts are only about clients; with no client there is nothing to choose a window by.
        let lead = origin(.tmux, tty: "ttys000", tmux: leadLocation, host: .warp)
        let hosts: [Int32: TmuxClientHost] = [4003: TmuxClientHost(terminal: .terminal), 4001: warp(warpLink)]
        #expect(TerminalFocus.plan(for: lead, panes: nestedPanes, hosts: hosts) == [.activate(bundleID: "dev.warp.Warp-Stable")])
        #expect(TerminalFocus.plan(for: lead, panes: [], clients: [], hosts: hosts) == [.activate(bundleID: "dev.warp.Warp-Stable")])
    }

    @Test func theClientsSwitchedAreListedInnermostFirst() {
        let okios = origin(.tmux, tty: "ttys009", tmux: okiosLocation, host: .warp)
        let steps = TerminalFocus.plan(for: okios, panes: nestedPanes, clients: nestedClientsWithPids, hosts: [4001: warp(warpLink)])
        #expect(TerminalFocus.switchedClients(in: steps) == ["/dev/ttys011", "/dev/ttys033"])
        #expect(TerminalFocus.switchedClients(in: [.activate(bundleID: "x"), .openURL(warpLink)]).isEmpty)
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

    @Test func tmuxsClientListNowAsksForEachClientsProcess() {
        #expect(TerminalFocus.listClientsArguments.last?.hasSuffix("#{client_pid}") == true)
        #expect(TerminalFocus.clients(fromListClients: "/dev/ttys009\tlead\t1790102753\t4242")
            == [TmuxClient(tty: "/dev/ttys009", session: "lead", activity: 1_790_102_753, pid: 4242)])
        // A pid tmux left empty, or one that is not a number, is simply not known.
        #expect(TerminalFocus.clients(fromListClients: "/dev/ttys009\tlead\t5\t")
            == [TmuxClient(tty: "/dev/ttys009", session: "lead", activity: 5)])
        #expect(TerminalFocus.clients(fromListClients: "/dev/ttys009\tlead\t5\tabc").first?.pid == nil)
        // A line from before the pid was asked for still reads.
        #expect(TerminalFocus.clients(fromListClients: "/dev/ttys009\tlead\t5").first?.pid == nil)
    }
}
