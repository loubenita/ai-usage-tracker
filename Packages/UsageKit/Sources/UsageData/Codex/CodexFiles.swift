import Foundation
import Synchronization

/// Finds Codex rollouts, `~/.codex/sessions/<year>/<month>/<day>/rollout-….jsonl`, and the one
/// a running `codex` process is writing.
final class CodexFiles: Sendable {
    let directory: String
    private let files: FileAccess
    /// Each rollout's first line, which never changes once written.
    private let metas = Mutex<[String: CodexRollout]>([:])

    init(directory: String, files: FileAccess = FileAccess()) {
        self.directory = directory
        self.files = files
    }

    /// Rollouts written to at or after `since`: those in the day folders from the day before
    /// `since` until today, and archived ones.
    func rollouts(changedSince since: Date, now: Date, calendar: Calendar = .current) -> [String] {
        var folders = [directory + "/archived_sessions"]
        var day = calendar.startOfDay(for: since.addingTimeInterval(-24 * 3600))
        while day <= now {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            folders.append(String(
                format: "%@/sessions/%04d/%02d/%02d", directory, parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
            ))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? now.addingTimeInterval(1)
        }
        return folders.flatMap { files.files(in: $0, suffix: ".jsonl", changedSince: since) }
    }

    /// The rollout's first line: its session id, folder, start and whether a sub-agent wrote it.
    func meta(of path: String) -> CodexRollout? {
        if let meta = metas.withLock({ $0[path] }) { return meta }
        guard let line = files.firstLine(path) else { return nil }
        var meta = CodexRollout()
        meta.consume(line)
        guard meta.sessionID != nil else { return nil }
        metas.withLock { $0[path] = meta }
        return meta
    }

    /// The rollout of a `codex` process started at `startedAt` in `folder`: a main session in
    /// that folder, written to since the process started. One the process started itself wins
    /// over one it resumed; among equals, the latest written. Rollouts already linked to another
    /// process are skipped.
    func rollout(startedAt: Date, folder: String, excluding taken: Set<String>, now: Date) -> String? {
        let candidates = rollouts(changedSince: startedAt, now: now)
            .filter { !taken.contains($0) }
            .compactMap { path in meta(of: path).map { (path: path, meta: $0) } }
            .filter { $0.meta.folder == folder && !$0.meta.isSubagent }
        let started = candidates.filter { ($0.meta.startedAt ?? .distantPast) >= startedAt.addingTimeInterval(-30) }
        return (started.isEmpty ? candidates : started)
            .max { (files.modified($0.path) ?? .distantPast) < (files.modified($1.path) ?? .distantPast) }?
            .path
    }
}
