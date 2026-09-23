import AppKit
import UsageDomain

/// Does what `TerminalFocus` plans, when the session panel's Open button is clicked, and at no
/// other time. It asks tmux where the session's pane is, brings the terminal app forward and
/// moves tmux to the pane, or asks Terminal to select the session's tab. It never types into a
/// terminal and sends no key or mouse event.
///
/// Every step is written to `~/Library/Application Support/AIUsageTracker/open.log` with what
/// was run, what it printed and how it ended, so a click that does nothing can be read back.
struct TerminalOpener: SessionOpening {
    /// Where these programs live. The app is started by Finder or launchd, not by a shell, so
    /// it has no PATH of its own and each one is found by its full path.
    private static let programPaths: [String: [String]] = [
        "tmux": ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"],
        "osascript": ["/usr/bin/osascript"],
    ]

    func open(_ origin: SessionOrigin) {
        let log = OpenLog()
        log.write("open \(origin.terminal.rawValue) pid \(origin.pid) tty \(origin.tty)"
            + (origin.tmux.map { " tmux \($0.session):\($0.window ?? "?").\($0.pane ?? "?")" } ?? "")
            + (origin.hostTerminal.map { " in \($0.rawValue)" } ?? ""))
        DispatchQueue.global(qos: .userInitiated).async {
            // Always ask tmux which panes it has: the ids the agent recorded go stale when a
            // pane is closed, and then the session is found by its TTY instead.
            let panes = origin.terminal == .tmux
                ? TerminalFocus.panes(fromListPanes: Self.run("tmux", TerminalFocus.listPanesArguments, log: log).output)
                : []
            if origin.terminal == .tmux {
                let found = TerminalFocus.location(for: origin, panes: panes)
                switch found.route {
                case .recorded:
                    log.write("pane: the one the agent recorded, \(found.location?.pane ?? "?")")
                case .byTTY:
                    log.write("pane: the recorded one has gone; found \(found.location?.pane ?? "?") by tty \(origin.tty)")
                case .none:
                    log.write("pane: not found, by id or by tty \(origin.tty); leaving tmux alone")
                }
            }
            let clients = origin.terminal == .tmux
                ? TerminalFocus.clients(fromListClients: Self.run("tmux", TerminalFocus.listClientsArguments, log: log).output)
                : []
            let steps = TerminalFocus.plan(for: origin, panes: panes, clients: clients)
            guard !steps.isEmpty else {
                log.write("nothing to do: no plan for \(origin.terminal.rawValue)")
                return
            }
            for step in steps {
                switch step {
                case .activate(let bundleID):
                    DispatchQueue.main.sync { Self.activate(bundleID, log: log) }
                case .run(let program, let arguments):
                    _ = Self.run(program, arguments, log: log)
                }
            }
            // What that client is looking at afterwards, so the log shows whether the switch
            // really happened. Without naming the client, tmux answers for another one.
            if origin.terminal == .tmux, let session = origin.tmux?.session ?? panes.first?.location.session {
                let client = TerminalFocus.mostRecent(clients, showing: session)
                let arguments = ["display-message", "-p"] + (client.map { ["-c", $0.tty] } ?? []) + ["#S:#I.#P"]
                let now = Self.run("tmux", arguments, log: log).output.trimmingCharacters(in: .whitespacesAndNewlines)
                log.write("\(client?.tty ?? "the client") is now on \(now)")
            }
        }
    }

    private static func activate(_ bundleID: String, log: OpenLog) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log.write("activate \(bundleID): not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            log.write("activate \(bundleID): \(error.map { "failed, \($0.localizedDescription)" } ?? "front")")
        }
    }

    /// Runs a program directly, with no shell, and logs the command, how it ended and anything
    /// it complained about.
    @discardableResult
    private static func run(_ program: String, _ arguments: [String], log: OpenLog) -> (output: String, status: Int32) {
        guard let path = programPaths[program]?.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            log.write("\(program) not found at \(programPaths[program]?.joined(separator: ", ") ?? "")")
            return ("", -1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let errors = Pipe()
        process.standardOutput = out
        process.standardError = errors
        let command = ([path] + arguments).joined(separator: " ")
        do {
            try process.run()
        } catch {
            log.write("\(command) → could not start: \(error.localizedDescription)")
            return ("", -1)
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let complaint = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        log.write("\(command) → exit \(process.terminationStatus)" + (complaint.isEmpty ? "" : ", said: \(complaint)"))
        return (output, process.terminationStatus)
    }
}

/// The log of what Open did, kept beside the app's other files so it can be read after the fact.
final class OpenLog: Sendable {
    static func path(homeDirectory: String = NSHomeDirectory()) -> String {
        homeDirectory + "/Library/Application Support/AIUsageTracker/open.log"
    }

    func write(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        let text = "\(stamp) \(line)\n"
        NSLog("AIUsageTracker open: %@", line)
        let path = Self.path()
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data(text.utf8).write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
