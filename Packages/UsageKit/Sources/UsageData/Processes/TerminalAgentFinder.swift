import Foundation
import UsageDomain

/// An agent process a person started in a terminal.
struct TerminalAgentProcess: Sendable, Hashable {
    let process: ProcessRow
    let agent: Agent
    let tty: String
    let terminal: TerminalApp
}

/// Picks the agent sessions out of a process table.
///
/// A session is an agent process with a terminal attached whose parent chain holds no
/// other agent. That drops sub-agents (`claude -p` or `codex exec` started by another
/// agent, and the native binary a Node launcher starts) and background jobs (no TTY).
enum TerminalAgentFinder {
    /// Program names of the agents, as the process table shows them.
    static let agentNames: [String: Agent] = [
        "claude": .claudeCode,
        "codex": .codex,
        "cursor-agent": .cursor,
        "opencode": .opencode,
        "kiro": .kiro,
        "kiro-cli": .kiro,
        // The chat program `kiro-cli` starts, which can also be the session's only process.
        "kiro-cli-chat": .kiro,
    ]

    /// Script runners an agent can be launched through, as in `node /opt/homebrew/bin/codex`.
    static let runtimes: Set<String> = ["node", "bun", "deno"]

    static func find(in rows: [ProcessRow]) -> [TerminalAgentProcess] {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return rows
            .compactMap { row -> TerminalAgentProcess? in
                guard let agent = agent(of: row), let tty = row.tty else { return nil }
                let ancestors = ancestors(of: row, in: byPID)
                guard !ancestors.contains(where: { self.agent(of: $0) != nil }) else { return nil }
                return TerminalAgentProcess(process: row, agent: agent, tty: tty, terminal: terminal(in: ancestors))
            }
            .sorted { ($0.process.startedAt, $0.process.pid) < ($1.process.startedAt, $1.process.pid) }
    }

    /// Which agent a process runs, if any: by its program name, or by the script a runtime runs.
    static func agent(of row: ProcessRow) -> Agent? {
        let arguments = row.arguments
        guard let first = arguments.first else { return nil }
        let name = ProcessRow.baseName(first)
        if let agent = agentNames[name] { return agent }
        // A program inside an app bundle whose name has a space, such as
        // "/Applications/Kiro CLI.app/Contents/MacOS/kiro-cli-chat": `ps` splits it at the space.
        if let bundled = row.command.range(of: ".app/Contents/MacOS/") {
            let program = row.command[bundled.upperBound...].prefix { $0 != " " }
            if let agent = agentNames[String(program)] { return agent }
        }
        guard runtimes.contains(name), arguments.count > 1 else { return nil }
        return agentNames[ProcessRow.baseName(arguments[1])]
    }

    /// The terminal app a tmux client runs in, for sessions inside tmux: tmux's server is not a
    /// child of any terminal, but each client showing it is. With several clients, the one that
    /// started last is taken.
    static func tmuxClientTerminal(in rows: [ProcessRow]) -> TerminalApp? {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return rows
            .filter { $0.executableName == "tmux" && $0.tty != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .lazy
            .map { terminal(in: ancestors(of: $0, in: byPID)) }
            .first { $0 != .unknown && $0 != .tmux }
    }

    /// The terminal app owning the session: the nearest known terminal up the parent chain.
    /// tmux comes first when a session runs inside it, even if tmux is shown in a Warp tab.
    static func terminal(in ancestors: [ProcessRow]) -> TerminalApp {
        for row in ancestors {
            if let app = terminalApp(of: row) { return app }
        }
        return .unknown
    }

    static func terminalApp(of row: ProcessRow) -> TerminalApp? {
        let command = row.command
        if command.contains("/Warp.app/") { return .warp }
        if command.contains("/Terminal.app/") { return .terminal }
        if command.contains("/iTerm.app/") || command.contains("/iTerm2.app/") { return .iterm }
        if command.contains("/Ghostty.app/") { return .ghostty }
        switch row.executableName {
        case "tmux": return .tmux
        case "ghostty": return .ghostty
        default: return nil
        }
    }

    /// Parent, grandparent and so on, stopping at launchd or a loop.
    static func ancestors(of row: ProcessRow, in byPID: [Int32: ProcessRow]) -> [ProcessRow] {
        var chain: [ProcessRow] = []
        var seen: Set<Int32> = [row.pid]
        var next = byPID[row.parentPID]
        while let current = next, current.pid > 1, seen.insert(current.pid).inserted {
            chain.append(current)
            next = byPID[current.parentPID]
        }
        return chain
    }
}
