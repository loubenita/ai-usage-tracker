import Foundation

/// One thing to do to bring a session's terminal to the front.
public enum TerminalFocusStep: Sendable, Hashable {
    /// Bring the app with this bundle id to the front.
    case activate(bundleID: String)
    /// Run a program, found on the usual paths, with these arguments. No shell is involved.
    case run(program: String, arguments: [String])
    /// Open a `warp://session/...` link, which makes Warp switch to the tab it belongs to (and
    /// come forward). Only a link `WarpFocusLink` accepts is ever planned; the app checks it
    /// again before opening it.
    case openURL(String)
}

public enum TerminalFocusAction: Sendable, Hashable {
    case session
    case application(TerminalApp)
}

/// A tmux pane as `tmux list-panes -a` reports it.
public struct TmuxPane: Sendable, Hashable {
    public let tty: String
    public let location: TmuxLocation
}

/// A tmux client as `tmux list-clients` reports it: the terminal it runs in, the session it
/// shows, when it was last used, and its process id.
public struct TmuxClient: Sendable, Hashable {
    public let tty: String
    public let session: String
    /// Seconds since 1970, from tmux's `client_activity`.
    public let activity: Double
    /// The client's process, from tmux's `client_pid`, when tmux says. The processes above it
    /// tell which terminal app the client runs in (see `TmuxClientHost`).
    public let pid: Int32?

    public init(tty: String, session: String, activity: Double = 0, pid: Int32? = nil) {
        self.tty = tty
        self.session = session
        self.activity = activity
        self.pid = pid
    }
}

/// Where a tmux client really runs: the terminal app that started it, and for Warp the link of
/// its tab. Read from the client's own process when Open is clicked, since one tmux server can
/// be shown in several terminals at once.
public struct TmuxClientHost: Sendable, Hashable {
    /// The nearest terminal above the client's process. `.tmux` means the client runs inside a
    /// pane of another tmux session, and `.unknown` that no terminal was found.
    public let terminal: TerminalApp
    /// The `warp://session/...` link of the client's Warp tab, only meaningful when `terminal` is
    /// `.warp`. Warp's variable is copied into everything started from a tab, including a
    /// Terminal window opened there, so the link is trusted only from a client whose nearest
    /// terminal is Warp. The plan checks it again (see `WarpFocusLink`).
    public let warpFocusURL: String?

    public init(terminal: TerminalApp, warpFocusURL: String? = nil) {
        self.terminal = terminal
        self.warpFocusURL = warpFocusURL
    }
}

/// How the panel's Open button brings a session's terminal to the front. Pure: it only says
/// what to do, and the app does it, only when Open is clicked. Nothing is ever typed into a
/// terminal, and no key or mouse event is sent.
///
/// | Where the session runs | What Open does |
/// |---|---|
/// | tmux | brings forward the terminal window or tab the outermost tmux client runs in, then `switch-client`, `select-window` and `select-pane` to the session's pane. When that client sits inside a pane of another tmux session, it also selects that pane and shows the outer session, outward as far as the clients are nested. Which terminal the client runs in is read from the client's own process; the app guessed for tmux is only the fallback |
/// | tmux shown in Terminal or iTerm | before the tmux steps, selects the window and tab whose TTY is the outermost client's, through the terminal's own scripting, and brings the terminal forward |
/// | tmux shown in Warp | the same tmux steps, then the `warp://session` link of the Warp tab the outermost client runs in, last, so that tab comes forward already showing the right window; without that link, Warp is only brought forward first |
/// | Terminal | selects the tab whose TTY is the session's, through Terminal's own scripting, and brings Terminal forward |
/// | iTerm | selects the existing session, tab and window whose TTY is the session's, through iTerm's own scripting |
/// | Warp | opens the session's own tab through the `warp://session` link Warp gives each tab (`WARP_FOCUS_URL`), which also brings Warp forward; without that link, Warp is only brought forward |
/// | Ghostty | brings the app forward; its tabs cannot be chosen exactly from outside |
/// | unknown | nothing, so the panel shows no Open button |
public enum TerminalFocus {
    /// What `tmux list-panes` is asked, to find a pane by its TTY.
    public static let listPanesArguments = ["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}\t#{window_id}\t#{pane_id}"]
    /// What `tmux list-clients` is asked: which terminal each client is in, what it shows, when
    /// it was last used, and its process.
    public static let listClientsArguments = [
        "list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_activity}\t#{client_pid}",
    ]

    public static func bundleID(of terminal: TerminalApp) -> String? {
        switch terminal {
        case .warp: "dev.warp.Warp-Stable"
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .tmux, .unknown, .background: nil
        }
    }

    /// What the button can promise. Terminal, iTerm, tmux, and Warp with its tab link can target
    /// a session. Other supported terminals expose app activation only, so the UI must not call
    /// that "Open session".
    public static func action(for origin: SessionOrigin) -> TerminalFocusAction? {
        switch origin.terminal {
        case .tmux:
            if origin.tmux != nil { return .session }
            return origin.hostTerminal.flatMap { bundleID(of: $0) == nil ? nil : .application($0) }
        case .terminal:
            return safeTTY(origin.tty) == nil ? .application(.terminal) : .session
        case .iterm:
            return safeTTY(origin.tty) == nil ? .application(.iterm) : .session
        case .warp:
            // The tab's own link reaches the session itself; without it only the app comes forward.
            return WarpFocusLink.validated(origin.warpFocusURL) == nil ? .application(.warp) : .session
        case .ghostty:
            return bundleID(of: origin.terminal) == nil ? nil : .application(origin.terminal)
        // A background session has no window to bring forward.
        case .unknown, .background: return nil
        }
    }

    public static func canOpen(_ origin: SessionOrigin) -> Bool { action(for: origin) != nil }

    /// The steps for a session. For tmux, `panes` and `clients` are what tmux reported when Open
    /// was clicked: a pane found by the session's TTY stands in when its location is not known.
    /// A client already showing that session is selected first; the most recently used client is
    /// only a fallback when the session is not currently displayed anywhere. When that client is
    /// itself running inside a pane of another tmux session, the outer session is brought to that
    /// pane too (see `tmuxPlan`).
    ///
    /// A Warp session opens its own tab through its `warp://session` link, which also brings Warp
    /// forward. For tmux, `hosts` holds where each client really runs (by its pid), as the app
    /// read it when Open was clicked: the window or tab of the outermost client is brought
    /// forward by that client's host, and `origin.hostTerminal`, the one app guessed for every
    /// tmux session, is only the fallback for a client with no host.
    public static func plan(
        for origin: SessionOrigin, panes: [TmuxPane] = [], clients: [TmuxClient] = [],
        hosts: [Int32: TmuxClientHost] = [:]
    ) -> [TerminalFocusStep] {
        switch origin.terminal {
        case .tmux:
            return tmuxPlan(origin, panes: panes, clients: clients, hosts: hosts)
        case .terminal:
            guard let tty = safeTTY(origin.tty) else { return activate(.terminal) }
            return [.run(program: "osascript", arguments: ["-e", terminalScript(tty: tty)])] + activate(.terminal)
        case .iterm:
            guard let tty = safeTTY(origin.tty) else { return activate(.iterm) }
            return [.run(program: "osascript", arguments: ["-e", iTermScript(tty: tty)])] + activate(.iterm)
        case .warp:
            guard let link = WarpFocusLink.validated(origin.warpFocusURL) else { return activate(.warp) }
            return [.openURL(link)]
        case .ghostty, .unknown, .background:
            return activate(origin.terminal)
        }
    }

    /// The `-c` client of each `switch-client` step, in the order they run: the client that shows
    /// the session first, then each client that shows an outer session. The app reads back what
    /// the last of them is on.
    public static func switchedClients(in steps: [TerminalFocusStep]) -> [String] {
        steps.compactMap { step in
            guard case .run("tmux", let arguments) = step, arguments.first == "switch-client",
                  arguments.count > 2, arguments[1] == "-c" else { return nil }
            return arguments[2]
        }
    }

    /// How a session's pane was found, for the log: tmux's window and pane ids are not reused,
    /// but they do go when a pane is closed, so the one the agent recorded can be stale.
    public enum TmuxRoute: Sendable, Hashable {
        /// The pane the agent recorded, still there.
        case recorded
        /// The recorded one has gone, or was never recorded: found by the session's TTY.
        case byTTY
        /// Neither: the terminal is brought forward and tmux is left alone.
        case none
    }

    /// The session's pane, and how it was found. The recorded one is used while tmux still has
    /// it; otherwise the pane whose TTY is the session's own.
    public static func location(
        for origin: SessionOrigin, panes: [TmuxPane]
    ) -> (location: TmuxLocation?, route: TmuxRoute) {
        let byTTY = panes.first { $0.tty == devicePath(origin.tty) }?.location
        guard let recorded = origin.tmux else { return (byTTY, byTTY == nil ? .none : .byTTY) }
        // With no list of panes to check against, the recorded one is all there is.
        guard !panes.isEmpty else { return (recorded, .recorded) }
        let stillThere = panes.contains { pane in
            pane.location.session == recorded.session
                && (recorded.pane.map { $0 == pane.location.pane } ?? (recorded.window == pane.location.window))
        }
        if stillThere { return (recorded, .recorded) }
        return byTTY == nil ? (nil, .none) : (byTTY, .byTTY)
    }

    /// How many outer tmux sessions are followed when a client sits inside a pane of another
    /// session. Real setups nest once or twice; the limit only keeps an odd layout from looping on.
    private static let maxNestingLevels = 4

    /// Brings the session's pane to a client, then, when that client is itself running inside a
    /// pane of another tmux session on the same server, selects that outer pane and shows the
    /// outer session on a client of its own. Without this the session is selected inside the inner
    /// client, but the outer session keeps showing whatever window it was on, so the person never
    /// sees it. This repeats outward while the client chosen is again inside a pane.
    ///
    /// The outermost client switched is the one in a real terminal window or tab, and `hosts` says
    /// which terminal that is, so the right window is brought forward: Terminal and iTerm select
    /// the tab with the client's TTY before the tmux steps, Warp opens the client's tab link
    /// last, after them, so the tab comes forward already showing the right window. A client
    /// with no host, or one inside a tmux pane, gets the app guessed for tmux activated first.
    private static func tmuxPlan(
        _ origin: SessionOrigin, panes: [TmuxPane], clients: [TmuxClient], hosts: [Int32: TmuxClientHost]
    ) -> [TerminalFocusStep] {
        let fallback = origin.hostTerminal.map(activate) ?? []
        guard let location = location(for: origin, panes: panes).location else { return fallback }
        // Selecting a client that already shows this session lets tmux choose the correct
        // terminal tab. Only when no client shows it do we fall back to the most recent client.
        guard let client = mostRecent(clients, showing: location.session) else { return fallback }
        let outer = outerSteps(startingAt: client, session: location.session, panes: panes, clients: clients)
        let steps = [switchClient(client, to: location.session)] + select(location) + outer.steps
        let host = outer.outermost.pid.flatMap { hosts[$0] }
        let (before, after) = bringForward(client: outer.outermost, host: host, fallback: fallback)
        return before + steps + after
    }

    /// What brings the window of a tmux client forward, split into what runs before the tmux
    /// steps and what runs after them. A Warp tab link is opened last; the rest come first.
    ///
    /// A Warp link is trusted only when the client's nearest terminal is Warp (the host says so),
    /// since every process inherits the link of the tab it was started from, and a tmux client
    /// in Terminal can carry the link of an unrelated Warp tab.
    private static func bringForward(
        client: TmuxClient, host: TmuxClientHost?, fallback: [TerminalFocusStep]
    ) -> (before: [TerminalFocusStep], after: [TerminalFocusStep]) {
        switch host?.terminal {
        case .terminal?:
            guard let tty = safeTTY(client.tty) else { return (activate(.terminal), []) }
            return ([.run(program: "osascript", arguments: ["-e", terminalScript(tty: tty)])] + activate(.terminal), [])
        case .iterm?:
            guard let tty = safeTTY(client.tty) else { return (activate(.iterm), []) }
            return ([.run(program: "osascript", arguments: ["-e", iTermScript(tty: tty)])] + activate(.iterm), [])
        case .warp?:
            guard let link = WarpFocusLink.validated(host?.warpFocusURL) else { return (activate(.warp), []) }
            return ([], [.openURL(link)])
        case .ghostty?:
            return (activate(.ghostty), [])
        // Inside a tmux pane, no terminal found, or nothing known about the client.
        case .tmux?, .unknown?, .background?, nil:
            return (fallback, [])
        }
    }

    /// The steps for each tmux session that shows `client` inside one of its panes, innermost
    /// first, and the outermost client switched: `client` itself when it is not inside a pane.
    /// A session already visited ends the walk, so two sessions shown inside each other
    /// cannot loop, and so does a session no client is showing: only a client that shows the outer
    /// session can bring it forward, and the fallback to any client would switch the inner one.
    private static func outerSteps(
        startingAt client: TmuxClient, session: String, panes: [TmuxPane], clients: [TmuxClient]
    ) -> (steps: [TerminalFocusStep], outermost: TmuxClient) {
        var steps: [TerminalFocusStep] = []
        var visited: Set<String> = [session]
        var current = client
        for _ in 0..<maxNestingLevels {
            let tty = devicePath(current.tty)
            guard let hostPane = panes.first(where: { devicePath($0.tty) == tty }),
                  visited.insert(hostPane.location.session).inserted else { break }
            steps += select(hostPane.location)
            guard let outer = mostRecent(clients.filter { $0.session == hostPane.location.session }) else { break }
            steps.append(switchClient(outer, to: hostPane.location.session))
            current = outer
        }
        return (steps, current)
    }

    private static func switchClient(_ client: TmuxClient, to session: String) -> TerminalFocusStep {
        // "=" asks for the session with exactly this name, not one that starts with it.
        .run(program: "tmux", arguments: ["switch-client", "-c", client.tty, "-t", "=" + session])
    }

    /// `select-window` and `select-pane` for the ids a location has.
    private static func select(_ location: TmuxLocation) -> [TerminalFocusStep] {
        var steps: [TerminalFocusStep] = []
        if let window = location.window { steps.append(.run(program: "tmux", arguments: ["select-window", "-t", window])) }
        if let pane = location.pane { steps.append(.run(program: "tmux", arguments: ["select-pane", "-t", pane])) }
        return steps
    }

    private static func activate(_ terminal: TerminalApp) -> [TerminalFocusStep] {
        bundleID(of: terminal).map { [.activate(bundleID: $0)] } ?? []
    }

    /// "ttys004" as "/dev/ttys004".
    static func devicePath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }

    /// The TTY only when it looks like one, "ttys004", since it goes into a script.
    static func safeTTY(_ tty: String) -> String? {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard name.hasPrefix("tty"), name.count <= 12,
              name.dropFirst(3).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "/dev/" + name
    }

    /// Terminal's own scripting: select the tab with this TTY and raise its window. It chooses
    /// a tab; it types nothing and clicks nothing.
    static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    /// iTerm's own scripting: select the existing window, tab and split-pane session with this
    /// TTY. It chooses objects only; it types and clicks nothing.
    static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    /// Reads `list-panes` output made with `listPanesArguments`.
    public static func panes(fromListPanes output: String) -> [TmuxPane] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return TmuxPane(tty: fields[0], location: TmuxLocation(session: fields[1], window: fields[2], pane: fields[3]))
        }
    }

    /// The client to move. A client already showing the session always wins; otherwise use the
    /// most recently active client. Equal activity is resolved by TTY so a repeated click has a
    /// stable target.
    public static func mostRecent(_ clients: [TmuxClient], showing session: String) -> TmuxClient? {
        let displayingSession = clients.filter { $0.session == session }
        return mostRecent(displayingSession.isEmpty ? clients : displayingSession)
    }

    private static func mostRecent(_ clients: [TmuxClient]) -> TmuxClient? {
        clients.sorted { left, right in
            left.activity == right.activity ? left.tty < right.tty : left.activity > right.activity
        }.first
    }

    /// Reads `list-clients` output made with `listClientsArguments`.
    public static func clients(fromListClients output: String) -> [TmuxClient] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            return TmuxClient(
                tty: fields[0], session: fields[1],
                activity: fields.count > 2 ? Double(fields[2]) ?? 0 : 0,
                pid: fields.count > 3 ? Int32(fields[3]) : nil
            )
        }
    }
}
