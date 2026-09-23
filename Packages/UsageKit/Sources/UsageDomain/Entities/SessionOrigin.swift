import Foundation

/// The terminal app that owns a session's TTY.
public enum TerminalApp: String, Sendable, Hashable, CaseIterable {
    case warp, terminal, iterm, ghostty, tmux, unknown

    public var displayName: String {
        switch self {
        case .warp: "Warp"
        case .terminal: "Terminal"
        case .iterm: "iTerm"
        case .ghostty: "Ghostty"
        case .tmux: "tmux"
        case .unknown: "Terminal"
        }
    }
}

/// Where a session runs inside tmux: its session, window and pane, as tmux names them
/// ("lead", "@24", "%24"). The window and pane ids are tmux's own, stable while they exist.
public struct TmuxLocation: Sendable, Hashable {
    public let session: String
    public let window: String?
    public let pane: String?

    public init(session: String, window: String? = nil, pane: String? = nil) {
        self.session = session
        self.window = window
        self.pane = pane
    }

    /// Claude Code's `tmux` field, "session:@window.%pane", such as "lead:@24.%24".
    public static func parse(_ value: String) -> TmuxLocation? {
        guard let colon = value.lastIndex(of: ":") else { return value.isEmpty ? nil : TmuxLocation(session: value) }
        let session = String(value[..<colon])
        guard !session.isEmpty else { return nil }
        let rest = value[value.index(after: colon)...]
        let parts = rest.split(separator: ".", maxSplits: 1).map(String.init)
        return TmuxLocation(session: session, window: parts.first, pane: parts.count > 1 ? parts[1] : nil)
    }
}

/// Where a live session was found: the agent process in a terminal on this Mac.
/// Present only for sessions detected from running processes.
public struct SessionOrigin: Sendable, Hashable {
    public let pid: Int32
    /// The controlling terminal, such as "ttys004".
    public let tty: String
    public let terminal: TerminalApp
    /// The process's working directory.
    public let folder: String
    /// The agent's own id for the session, when the agent records one (Claude Code does).
    public let agentSessionID: String?
    /// The session's transcript file, when one was found.
    public let transcriptPath: String?
    /// A name the person gave the session, such as `claude --name lead`. Names the agent
    /// made up itself are left out.
    public let sessionName: String?
    /// The session runs in the user's home folder.
    public let isHomeFolder: Bool
    /// Where in tmux the session runs, when it runs inside tmux and that is known.
    public let tmux: TmuxLocation?
    /// For a session inside tmux, the terminal app its tmux client shows in, such as Warp.
    public let hostTerminal: TerminalApp?

    public init(
        pid: Int32,
        tty: String,
        terminal: TerminalApp,
        folder: String,
        agentSessionID: String? = nil,
        transcriptPath: String? = nil,
        sessionName: String? = nil,
        isHomeFolder: Bool = false,
        tmux: TmuxLocation? = nil,
        hostTerminal: TerminalApp? = nil
    ) {
        self.tmux = tmux
        self.hostTerminal = hostTerminal
        self.pid = pid
        self.tty = tty
        self.terminal = terminal
        self.folder = folder
        self.agentSessionID = agentSessionID
        self.transcriptPath = transcriptPath
        self.sessionName = sessionName
        self.isHomeFolder = isHomeFolder
    }
}
