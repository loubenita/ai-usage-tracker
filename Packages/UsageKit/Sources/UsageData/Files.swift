import Foundation
import UsageDomain

/// Read-only file access for detection and history. Nothing here writes.
struct FileAccess: Sendable {
    let read: @Sendable (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }

    let isDirectory: @Sendable (String) -> Bool? = { path in
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return nil }
        return directory.boolValue
    }

    func data(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func list(_ directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    }
    func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// The files in `directory` with `suffix`, changed at or after `since`.
    func files(in directory: String, suffix: String, changedSince since: Date) -> [String] {
        list(directory)
            .filter { $0.hasSuffix(suffix) }
            .map { directory + "/" + $0 }
            .filter { modified($0).map { $0 >= since } ?? false }
    }

    /// The first line of a file, reading no more than `limit` bytes.
    func firstLine(_ path: String, limit: Int = 1 << 20) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < limit, let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                return line + chunk[..<newline]
            }
            line += chunk
        }
        return line.isEmpty ? nil : line
    }
}

/// Names the work in a folder the way a live session's work is named: the git repository and
/// branch, or the folder's own name outside git. Work in the home folder is "Home folder",
/// not the owner's user name.
struct WorkNamer: Sendable {
    static let homeFolder = "Home folder"

    let files: FileAccess
    let homeDirectory: String

    /// `branch` is the one the agent recorded, which wins over the folder's current branch:
    /// a finished session keeps the branch it ran on.
    func work(folder: String?, branch recorded: String?) -> Work {
        guard let folder else {
            return Work(tag: WorkTag(project: "Unknown folder", concern: recorded ?? "Unknown folder"))
        }
        if Self.standardized(folder) == Self.standardized(homeDirectory) {
            return Work(tag: WorkTag(project: Self.homeFolder, concern: Self.homeFolder), branch: recorded, folder: folder)
        }
        let folderName = URL(fileURLWithPath: folder).lastPathComponent
        let git = GitLocator(readFile: files.read, isDirectory: files.isDirectory).locate(folder: folder)
        let branch = recorded ?? git?.branch
        let tag = WorkTag(project: git?.repositoryName ?? folderName, concern: branch ?? folderName)
        return Work(tag: tag, branch: branch, folder: folder)
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
