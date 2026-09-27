import Foundation

/// Claude Code keeps each profile's sessions and transcripts under its config directory.
/// A status-line reading registers custom directories; conventional home directories are
/// also found so a session remains visible before its first limit reading.
enum ClaudeAccounts {
    struct Profile: Sendable, Hashable {
        let directory: String
        let name: String
    }

    static func profiles(homeDirectory: String, log: Data?, files: FileAccess) -> [Profile] {
        let primary = homeDirectory + "/.claude"
        let candidates = files.list(homeDirectory)
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { homeDirectory + "/" + $0 }
        let registered = log.map(ClaudeLimitsLog.accounts) ?? [:]
        let paths = Set(candidates + registered.keys + [primary])
        return paths.sorted().compactMap { path in
            guard files.exists(path + "/sessions") || files.exists(path + "/projects") else { return nil }
            return Profile(directory: path, name: registered[path] ?? name(for: path, homeDirectory: homeDirectory))
        }
    }

    static func name(for directory: String, homeDirectory: String) -> String {
        if directory == homeDirectory + "/.claude" { return "Default" }
        let base = URL(fileURLWithPath: directory).lastPathComponent
        return base.hasPrefix(".claude-") ? String(base.dropFirst(".claude-".count)) : base
    }
}
