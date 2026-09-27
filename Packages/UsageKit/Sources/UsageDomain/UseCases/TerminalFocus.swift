import Foundation

/// One thing to do to bring a session's terminal to the front.
public enum TerminalFocusStep: Sendable, Hashable {
    /// Bring the app with this bundle id to the front.
    case activate(bundleID: String)
    /// Run a program, found on the usual paths, with these arguments. No shell is involved.
    case run(program: String, arguments: [String])
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
/// shows, and when it was last used.
public struct TmuxClient: Sendable, Hashable {
    public let tty: String
    public let session: String
    /// Seconds since 1970, from tmux's `client_activity`.
    public let activity: Double

    public init(tty: String, session: String, activity: Double = 0) {
        self.tty = tty
        self.session = session
        self.activity = activity
    }
}

/// How the panel's Open button brings a session's terminal to the front. Pure: it only says
/// what to do, and the app does it, only when Open is clicked. Nothing is ever typed into a
/// terminal, and no key or mouse event is sent.
///
/// | Where the session runs | What Open does |
/// |---|---|
/// | tmux | brings the tmux client's terminal forward, then `switch-client`, `select-window` and `select-pane` to the session's pane |
/// | Terminal | selects the tab whose TTY is the session's, through Terminal's own scripting, and brings Terminal forward |
/// | Warp, iTerm, Ghostty | brings the app forward; their tabs cannot be chosen from outside |
/// | unknown | nothing, so the panel shows no Open button |
public enum TerminalFocus {
    /// What `tmux list-panes` is asked, to find a pane by its TTY.
    public static let listPanesArguments = ["list-panes", "-a", "-F", "#{pane_tty}\t#{session_name}\t#{window_id}\t#{pane_id}"]
    /// What `tmux list-clients` is asked: which terminal each client is in, what it shows, and
    /// when it was last used.
    public static let listClientsArguments = ["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_activity}"]

    public static func bundleID(of terminal: TerminalApp) -> String? {
        switch terminal {
        case .warp: "dev.warp.Warp-Stable"
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .tmux, .unknown: nil
        }
    }

    /// What the button can promise. Terminal and tmux can target a session. Other supported
    /// terminals expose app activation only, so the UI must not call that "Open session".
    public static func action(for origin: SessionOrigin) -> TerminalFocusAction? {
        switch origin.terminal {
        case .tmux:
            if origin.tmux != nil { return .session }
            return origin.hostTerminal.flatMap { bundleID(of: $0) == nil ? nil : .application($0) }
        case .terminal:
            return safeTTY(origin.tty) == nil ? .application(.terminal) : .session
        case .warp, .iterm, .ghostty:
            return bundleID(of: origin.terminal) == nil ? nil : .application(origin.terminal)
        case .unknown: return nil
        }
    }

    public static func canOpen(_ origin: SessionOrigin) -> Bool { action(for: origin) != nil }

    /// The steps for a session. For tmux, `panes` and `clients` are what tmux reported when Open
    /// was clicked: a pane found by the session's TTY stands in when its location is not known,
    /// and the client showing the session is the one moved.
    public static func plan(
        for origin: SessionOrigin, panes: [TmuxPane] = [], clients: [TmuxClient] = []
    ) -> [TerminalFocusStep] {
        switch origin.terminal {
        case .tmux:
            return tmuxPlan(origin, panes: panes, clients: clients)
        case .terminal:
            guard let tty = safeTTY(origin.tty) else { return activate(.terminal) }
            return [.run(program: "osascript", arguments: ["-e", terminalScript(tty: tty)])] + activate(.terminal)
        case .warp, .iterm, .ghostty, .unknown:
            return activate(origin.terminal)
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

    private static func tmuxPlan(_ origin: SessionOrigin, panes: [TmuxPane], clients: [TmuxClient]) -> [TerminalFocusStep] {
        let host = origin.hostTerminal.map(activate) ?? []
        guard let location = location(for: origin, panes: panes).location else { return host }
        // The client used most recently: the terminal tab the person is looking at. Warp,
        // iTerm and Ghostty give no way to choose a tab from outside, so rather than leaving
        // the session in a tab they cannot be sent to, it is brought to the tab they are in.
        // A client already showing the session wins a tie, so nothing moves needlessly.
        let client = mostRecent(clients, showing: location.session)
        var switchClient = ["switch-client"]
        if let client { switchClient += ["-c", client.tty] }
        // "=" asks for the session with exactly this name, not one that starts with it.
        switchClient += ["-t", "=" + location.session]
        var steps = host + [TerminalFocusStep.run(program: "tmux", arguments: switchClient)]
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

    /// Reads `list-panes` output made with `listPanesArguments`.
    public static func panes(fromListPanes output: String) -> [TmuxPane] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return TmuxPane(tty: fields[0], location: TmuxLocation(session: fields[1], window: fields[2], pane: fields[3]))
        }
    }

    /// The client to move: the one used most recently, and among clients used at the same
    /// moment, one already showing the session.
    public static func mostRecent(_ clients: [TmuxClient], showing session: String) -> TmuxClient? {
        clients.max { left, right in
            (left.activity, left.session == session ? 1 : 0) < (right.activity, right.session == session ? 1 : 0)
        }
    }

    /// Reads `list-clients` output made with `listClientsArguments`.
    public static func clients(fromListClients output: String) -> [TmuxClient] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, !fields[0].isEmpty else { return nil }
            return TmuxClient(tty: fields[0], session: fields[1], activity: fields.count > 2 ? Double(fields[2]) ?? 0 : 0)
        }
    }
}
