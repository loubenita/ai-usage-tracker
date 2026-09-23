import CryptoKit
import Foundation
import SQLite3
import UsageDomain

/// What a Cursor Agent chat says about itself. Cursor keeps each chat in
/// `~/.cursor/chats/<MD5 of the folder>/<chat id>/store.db`, a SQLite database, with the
/// prompts the person typed in `prompt_history.json` beside it.
///
/// Cursor records no token count per reply, so only the chat as a whole is known:
/// - the `meta` table holds one row, JSON written as hex, with the chat's name, its last model
///   and the id of its latest root entry;
/// - that root entry, in the `blobs` table, is protobuf. Its field 5 is the context: field 1
///   is the tokens used and field 2 the window.
///
/// The database is opened read-only while Cursor writes to it. SQLite lets a reader and a
/// writer share a database; the reader never changes it.
struct CursorChat: Sendable, Hashable {
    let name: String?
    let model: String?
    let context: ContextUsage?
    let promptCount: Int?

    /// The folder Cursor keeps a folder's chats in.
    static func chatsDirectory(for folder: String, cursorDirectory: String) -> String {
        let hash = Insecure.MD5.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        return cursorDirectory + "/chats/" + hash
    }

    /// Reads the chat in `directory`, or nil when its database cannot be read.
    static func read(directory: String) -> CursorChat? {
        guard let database = ReadOnlyDatabase(path: directory + "/store.db") else { return nil }
        guard
            let hex = database.text("SELECT value FROM meta LIMIT 1"),
            let meta = hexData(hex).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return nil }
        let root = (meta["latestRootBlobId"] as? String).flatMap { id in
            database.blob("SELECT data FROM blobs WHERE id = ?", argument: id)
        }
        let prompts = FileManager.default.contents(atPath: directory + "/prompt_history.json")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
        return CursorChat(
            name: meta["name"] as? String,
            model: modelName(meta["lastUsedModel"] as? String),
            context: root.flatMap(context(inRoot:)),
            promptCount: prompts?.count
        )
    }

    /// The model as Cursor's screen names it: a chat on Auto saves "default".
    static func modelName(_ saved: String?) -> String? {
        saved == "default" ? "Auto" : saved
    }

    /// Field 5 of the root entry: `{1: tokens used, 2: window}`.
    static func context(inRoot data: Data) -> ContextUsage? {
        guard let usage = Protobuf.fields(data).last(where: { $0.number == 5 })?.bytes else { return nil }
        let fields = Protobuf.fields(usage)
        guard
            let used = fields.first(where: { $0.number == 1 })?.value,
            let window = fields.first(where: { $0.number == 2 })?.value,
            window > 0
        else { return nil }
        return ContextUsage(used: Int(used), window: Int(window))
    }

    private static func hexData(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// Just enough protobuf to read the fields of one message, without its schema.
enum Protobuf {
    struct Field {
        let number: Int
        /// A varint's value.
        let value: UInt64?
        /// A length-delimited field's bytes: a string, bytes, or a nested message.
        let bytes: Data?
    }

    /// The message's top-level fields, or as many as could be read before anything malformed.
    static func fields(_ data: Data) -> [Field] {
        let bytes = [UInt8](data)
        var fields: [Field] = []
        var index = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while index < bytes.count, let key = varint() {
            let number = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = varint() else { return fields }
                fields.append(Field(number: number, value: value, bytes: nil))
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return fields }
                let end = index + Int(length)
                fields.append(Field(number: number, value: nil, bytes: Data(bytes[index..<end])))
                index = end
            case 1:
                index += 8
            case 5:
                index += 4
            default:
                return fields
            }
        }
        return fields
    }
}

/// A SQLite database opened read-only, for single-value queries.
private final class ReadOnlyDatabase {
    private var handle: OpaquePointer?

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
    }

    deinit { sqlite3_close(handle) }

    func text(_ sql: String) -> String? {
        query(sql, argument: nil) { statement in
            sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }

    func blob(_ sql: String, argument: String) -> Data? {
        query(sql, argument: argument) { statement in
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    private func query<T>(_ sql: String, argument: String?, read: (OpaquePointer?) -> T?) -> T? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        if let argument {
            // SQLITE_TRANSIENT: SQLite copies the text before this call returns.
            sqlite3_bind_text(statement, 1, argument, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return read(statement)
    }
}
