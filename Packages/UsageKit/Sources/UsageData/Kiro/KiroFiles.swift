import Foundation
import Synchronization

/// Finds Kiro CLI sessions, `~/.kiro/sessions/cli/<session id>.json`, and the one a running
/// `kiro-cli` process is using.
final class KiroFiles: Sendable {
    let directory: String
    private let files: FileAccess
    /// Each session file as last read, with the time it was changed then.
    private let cache = Mutex<[String: (modified: Date, session: KiroSession)]>([:])

    init(directory: String, files: FileAccess = FileAccess()) {
        self.directory = directory
        self.files = files
    }

    /// Sessions changed at or after `since`, read again only when their file changed.
    func sessions(changedSince since: Date) -> [(path: String, modified: Date, session: KiroSession)] {
        files.files(in: directory, suffix: ".json", changedSince: since).compactMap { path in
            guard let modified = files.modified(path) else { return nil }
            if let cached = cache.withLock({ $0[path] }), cached.modified == modified {
                return (path, modified, cached.session)
            }
            let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard let data = files.data(path), let session = KiroSession(json: data, fallbackID: id) else { return nil }
            cache.withLock { $0[path] = (modified, session) }
            return (path, modified, session)
        }
    }

    /// The session of a `kiro-cli` process started at `startedAt` in `folder`: the one in that
    /// folder changed most recently since the process started.
    ///
    /// `ps` gives the start only to the second, so a file changed up to five seconds before it
    /// still counts. Going further back would let the previous session in the same folder be
    /// taken for this one.
    func session(startedAt: Date, folder: String, excluding taken: Set<String>)
        -> (path: String, modified: Date, session: KiroSession)?
    {
        let wanted = Self.normalised(folder)
        return sessions(changedSince: startedAt.addingTimeInterval(-5))
            .filter { !taken.contains($0.path) && $0.session.folder.map(Self.normalised) == wanted }
            .max { $0.modified < $1.modified }
    }

    /// A folder written so that the same place always reads the same: without a trailing slash
    /// or `.` and `..`, and with symlinks followed. `/Users/me/app/` and a link to `/Users/me/app`
    /// are both `/Users/me/app`.
    static func normalised(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
