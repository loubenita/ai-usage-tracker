import Foundation
import Synchronization

/// Finds Kiro V3 (ACP) sessions, each in its own folder under
/// `~/.kiro/sessions/<workspace hash>/<sess id>/`, with an append-only `messages.jsonl`
/// transcript beside a `session.json` of metadata.
///
/// It walks the workspace-hash folders of `~/.kiro/sessions` (skipping the V2 `cli` folder,
/// which `KiroFiles` reads), finds the `sess_*` session folders inside them, and returns each
/// session whose transcript changed at or after `since`, with the folder it ran in, its model
/// and its title read from `session.json`. The transcript itself is read by the caller through
/// an `IncrementalFileStore`, the same way Codex rollouts are, so only new lines are read.
///
/// The `session.json` metadata is cached and read again only when it changes.
final class KiroV3Files: Sendable {
    /// One V3 session: its transcript path, when the transcript last changed, the session
    /// folder's name, and what `session.json` said.
    struct Found: Sendable {
        let transcriptPath: String
        let modified: Date
        let sessUUID: String
        let folder: String?
        let model: String?
        let title: String?
        /// When the session was first opened, from `session.json`'s `createdAt`. A stable true
        /// start, unlike the `kiro-cli` process start, which resets on resume or reconnect.
        let createdAt: Date?
    }

    /// What `session.json` holds that the reading needs.
    struct Metadata: Sendable, Hashable {
        let folder: String?
        let model: String?
        let title: String?
        /// The session's true start, from `createdAt`.
        let createdAt: Date?
    }

    let directory: String
    private let files: FileAccess
    /// Each `session.json` as last read, with the time it was changed then.
    private let cache = Mutex<[String: (modified: Date, metadata: Metadata)]>([:])
    /// The V2 CLI folder, which sits beside the workspace-hash folders and is read elsewhere.
    static let cliFolderName = "cli"

    init(directory: String, files: FileAccess = FileAccess()) {
        self.directory = directory
        self.files = files
    }

    /// The sessions whose transcript changed at or after `since`. A session folder is any
    /// `sess_*` folder inside a workspace-hash folder; its transcript is `messages.jsonl`.
    func sessions(changedSince since: Date) -> [Found] {
        var found: [Found] = []
        for workspace in files.list(directory) where workspace != Self.cliFolderName {
            let workspacePath = directory + "/" + workspace
            guard files.isDirectory(workspacePath) == true else { continue }
            for session in files.list(workspacePath) where session.hasPrefix("sess_") {
                let sessionPath = workspacePath + "/" + session
                let transcriptPath = sessionPath + "/messages.jsonl"
                guard let modified = files.modified(transcriptPath), modified >= since else { continue }
                let metadata = metadata(at: sessionPath + "/session.json")
                found.append(Found(
                    transcriptPath: transcriptPath,
                    modified: modified,
                    sessUUID: session,
                    folder: metadata?.folder,
                    model: metadata?.model,
                    title: metadata?.title,
                    createdAt: metadata?.createdAt
                ))
            }
        }
        return found
    }

    /// The metadata of a session, read again only when its `session.json` changed.
    private func metadata(at path: String) -> Metadata? {
        guard let modified = files.modified(path) else { return nil }
        if let cached = cache.withLock({ $0[path] }), cached.modified == modified {
            return cached.metadata
        }
        guard let metadata = files.data(path).flatMap(Self.metadata(json:)) else { return nil }
        cache.withLock { $0[path] = (modified, metadata) }
        return metadata
    }

    /// Reads a `session.json`: `workspacePaths[0]` is the folder it ran in, `modelId` its model
    /// ("auto"), `title` its name, and `createdAt` when it was first opened. A file that does not
    /// parse is read as nothing.
    static func metadata(json data: Data) -> Metadata? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let folder = (object["workspacePaths"] as? [Any])?.first as? String
        return Metadata(
            folder: folder,
            model: object["modelId"] as? String,
            title: object["title"] as? String,
            createdAt: KiroSession.date(object["createdAt"])
        )
    }
}
