import AppKit
import UsageData
import UsageDomain

/// Does what `TerminalFocus` plans, when the session panel's Open button is clicked, and at no
/// other time. It asks tmux where the session's pane is, brings forward the terminal window the
/// tmux client runs in (found from the client's own process) and moves tmux to the pane, asks
/// Terminal or iTerm to select the session's tab, or opens the `warp://` link of a Warp tab. It
/// never types into a terminal and sends no key or mouse event.
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
            + (origin.hostTerminal.map { " in \($0.rawValue)" } ?? "")
            + (origin.warpFocusURL.map { " warp tab \($0)" } ?? ""))
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
            let hosts = origin.terminal == .tmux ? Self.hosts(of: clients, log: log) : [:]
            let steps = TerminalFocus.plan(for: origin, panes: panes, clients: clients, hosts: hosts)
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
                case .openURL(let link):
                    DispatchQueue.main.sync { Self.openWarpTab(link, log: log) }
                }
            }
            // What each client that was switched is looking at afterwards, so the log shows
            // whether the switch really happened. Each client's own line of `list-clients` is
            // read: `display-message -c` answers for the most recently used client, whichever is
            // named. With sessions shown inside each other the last one is the outermost client,
            // the one in the terminal tab.
            if origin.terminal == .tmux {
                let location = TerminalFocus.location(for: origin, panes: panes).location
                guard let session = location?.session else { return }
                let switched = TerminalFocus.switchedClients(in: steps)
                guard !switched.isEmpty else {
                    log.write("tmux: no attached client can show \(session)")
                    return
                }
                let shown = Self.run("tmux", ["list-clients", "-F", "#{client_tty}\t#S:#I.#P"], log: log).output
                    .split(separator: "\n")
                for tty in switched {
                    let line = shown.first { $0.hasPrefix(tty + "\t") }
                    log.write("\(tty) is now on " + (line.map { String($0.dropFirst(tty.count + 1)) } ?? "nothing: tmux no longer lists it"))
                }
            }
        }
    }

    /// Where each client tmux listed really runs, by the client's process: the nearest terminal
    /// app above it, and for Warp the link of its tab (see `TmuxClientHostReader`). Whatever is
    /// found is logged for each client, so a wrong window can be traced back to its client.
    private static func hosts(of clients: [TmuxClient], log: OpenLog) -> [Int32: TmuxClientHost] {
        let hosts = TmuxClientHostReader().hosts(of: clients.compactMap(\.pid))
        for client in clients {
            guard let pid = client.pid else {
                log.write("client \(client.tty): tmux gave no pid")
                continue
            }
            log.write("client \(client.tty) pid \(pid): " + describe(hosts[pid]))
        }
        return hosts
    }

    private static func describe(_ host: TmuxClientHost?) -> String {
        guard let host, host.terminal != .unknown else { return "no terminal found" }
        switch host.terminal {
        case .warp: return host.warpFocusURL.map { "warp tab \($0)" } ?? "warp, no tab link"
        case .tmux: return "tmux, inside a pane of another session"
        default: return host.terminal.rawValue
        }
    }

    /// Opens a Warp tab's link, which makes Warp switch to that tab and come forward. The link
    /// is checked again here, since it is opened as a URL.
    private static func openWarpTab(_ link: String, log: OpenLog) {
        guard let valid = WarpFocusLink.validated(link), let url = URL(string: valid) else {
            log.write("open \(link) → refused: not a Warp tab link")
            return
        }
        log.write("open \(valid) → " + (NSWorkspace.shared.open(url) ? "ok" : "failed"))
    }

    private static func activate(_ bundleID: String, log: OpenLog) {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            requestActivation(of: running, bundleID: bundleID, log: log, state: "running")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            log.write("activate \(bundleID): not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            guard error == nil, let application else {
                log.write("activate \(bundleID): launch failed, \(error?.localizedDescription ?? "no application returned")")
                return
            }
            DispatchQueue.main.async {
                requestActivation(of: application, bundleID: bundleID, log: log, state: "launched")
            }
        }
    }

    /// AppKit's launch completion only says that Launch Services accepted the request. Explicitly
    /// activate an existing app and then record what macOS actually put at the front.
    private static func requestActivation(
        of application: NSRunningApplication, bundleID: String, log: OpenLog, state: String
    ) {
        let requested = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        log.write("activate \(bundleID): \(state), request \(requested ? "accepted" : "rejected")")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if frontmost == bundleID {
                log.write("activate \(bundleID): verified front")
            } else {
                log.write("activate \(bundleID): not front; frontmost \(frontmost ?? "none")")
            }
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
