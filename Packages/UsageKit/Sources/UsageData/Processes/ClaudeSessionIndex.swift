import Foundation

/// A running Claude Code session's own file, `~/.claude/sessions/<pid>.json`.
/// Only the fields needed to link a process to its transcript are read.
struct ClaudeSessionFile: Sendable, Hashable, Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    /// Milliseconds since 1970.
    let startedAt: Double?
    let name: String?
    /// "user" when the person named the session; "derived" or "auto" when Claude Code did.
    let nameSource: String?
    /// "busy" while the agent works, "idle" when it has stopped.
    let status: String?
    /// Milliseconds since 1970.
    let statusUpdatedAt: Double?
    /// Where the session runs in tmux, "session:@window.%pane", when it runs inside tmux.
    let tmux: String?

    init(
        pid: Int32, sessionId: String, cwd: String, startedAt: Double?,
        name: String? = nil, nameSource: String? = nil, status: String? = nil, statusUpdatedAt: Double? = nil,
        tmux: String? = nil
    ) {
        self.tmux = tmux
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.name = name
        self.nameSource = nameSource
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
    }

    var statusChangedAt: Date? { statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    /// The session's name, only when the person chose it.
    var chosenName: String? { nameSource == "user" ? name : nil }
}

/// Links Claude Code processes to their session files and transcripts.
enum ClaudeSessionIndex {
    /// Reads one session file; anything unreadable is nil.
    static func parse(_ data: Data) -> ClaudeSessionFile? {
        try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    }

    /// The session file for a process: same pid, and written after the process started,
    /// so a stale file left by an earlier process with a reused pid is not taken.
    static func file(forPID pid: Int32, startedAt: Date, in files: [ClaudeSessionFile]) -> ClaudeSessionFile? {
        let slack: TimeInterval = 5
        return files.first { file in
            guard file.pid == pid else { return false }
            guard let written = file.startedAt else { return true }
            return Date(timeIntervalSince1970: written / 1000) >= startedAt.addingTimeInterval(-slack)
        }
    }

    /// Claude Code names a project's transcript folder after its working directory with every
    /// character that is not a letter or digit replaced by "-":
    /// "/Users/me/Development/ai-usage-tracker" is "-Users-me-Development-ai-usage-tracker".
    static func projectFolderName(forCWD cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        })
    }

    /// The transcript `<projects>/<folder name>/<session id>.jsonl`, if it exists. When it is
    /// not where the working directory says, any project folder holding that session id is used.
    static func transcriptPath(
        for session: ClaudeSessionFile,
        projectsDirectory: String,
        projectFolders: () -> [String],
        fileExists: (String) -> Bool
    ) -> String? {
        let fileName = session.sessionId + ".jsonl"
        let expected = "\(projectsDirectory)/\(projectFolderName(forCWD: session.cwd))/\(fileName)"
        if fileExists(expected) { return expected }
        return projectFolders()
            .map { "\(projectsDirectory)/\($0)/\(fileName)" }
            .first(where: fileExists)
    }
}
