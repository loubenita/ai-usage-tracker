import Foundation

/// Finds the chat a running `cursor-agent` process is using: in the folder's chats directory,
/// the chat written to most recently since the process started.
struct CursorFiles: Sendable {
    let directory: String
    let files: FileAccess

    init(directory: String, files: FileAccess = FileAccess()) {
        self.directory = directory
        self.files = files
    }

    func chat(startedAt: Date, folder: String, excluding taken: Set<String>) -> String? {
        let chats = CursorChat.chatsDirectory(for: folder, cursorDirectory: directory)
        return files.list(chats)
            .map { chats + "/" + $0 }
            .filter { !taken.contains($0) }
            .compactMap { chat in lastWrite(chat).map { (chat: chat, written: $0) } }
            .filter { $0.written >= startedAt.addingTimeInterval(-5) }
            .max { $0.written < $1.written }?
            .chat
    }

    /// When the chat's database last changed. SQLite writes to the `-wal` file first.
    func lastWrite(_ chat: String) -> Date? {
        [chat + "/store.db", chat + "/store.db-wal"].compactMap(files.modified).max()
    }
}
