import Foundation

/// The history as last read, saved to disk so the next launch starts from it instead of
/// reading a month of transcripts again, which took up to three minutes.
///
/// It holds, for every Claude Code transcript (main and sub-agent) and Codex rollout the
/// history read: the file's path, how far it was read, its file number, and what its lines
/// said so far (each reply once, by its message id). On launch those are restored, and each
/// file is read only from where it stopped. A file that got shorter, or was replaced by a new
/// file under the same path, is read again from the start.
///
/// Kept in `~/Library/Application Support/AIUsageTracker/history-cache.json`. A cache written
/// by another version of the app is ignored rather than trusted.
struct HistoryCache: Codable {
    static let version = 1

    var version = HistoryCache.version
    var mainTranscripts: [String: IncrementalFileStore<ClaudeTranscript>.Entry] = [:]
    var subagentTranscripts: [String: IncrementalFileStore<ClaudeTranscript>.Entry] = [:]
    var rollouts: [String: IncrementalFileStore<CodexRollout>.Entry] = [:]

    static func path(homeDirectory: String) -> String {
        homeDirectory + "/Library/Application Support/AIUsageTracker/history-cache.json"
    }

    /// The saved cache, or nil when there is none, it cannot be read, or it is another version's.
    static func load(from path: String) -> HistoryCache? {
        guard
            let data = FileManager.default.contents(atPath: path),
            let cache = try? JSONDecoder().decode(HistoryCache.self, from: data),
            cache.version == version
        else { return nil }
        return cache
    }

    /// Writes the cache in one step, so a crash mid-write leaves the last good one.
    func save(to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
