import Foundation
import Testing
@testable import UsageData

/// A running `kiro-cli` is matched to its session file by folder and by when the file changed.
/// Each test makes a project folder, a symlink to it and a sessions folder in a temporary
/// directory, and removes them afterwards.
@Suite("Matching a running Kiro session to its file")
struct KiroFilesTests {
    /// The process started at this moment; files are dated from it.
    static let started = Date(timeIntervalSince1970: 1_790_000_000)

    struct Folders {
        let root: URL
        let project: String
        let other: String
        let link: String
        let sessions: String

        static func make() throws -> Folders {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let folders = Folders(
                root: root,
                project: root.appendingPathComponent("project").path,
                other: root.appendingPathComponent("other").path,
                link: root.appendingPathComponent("link").path,
                sessions: root.appendingPathComponent("sessions").path
            )
            for directory in [folders.project, folders.other, folders.sessions] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(atPath: folders.link, withDestinationPath: folders.project)
            return folders
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A session file for a chat that ran in `cwd`, last changed `seconds` after the process started.
        @discardableResult
        func write(_ id: String, cwd: String, changedAfterStart seconds: TimeInterval = 30) throws -> String {
            let path = sessions + "/" + id + ".json"
            try #"{ "session_id": "\#(id)", "cwd": "\#(cwd)" }"#.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: KiroFilesTests.started.addingTimeInterval(seconds)], ofItemAtPath: path
            )
            return path
        }

        func found(in folder: String) -> String? {
            KiroFiles(directory: sessions).session(startedAt: KiroFilesTests.started, folder: folder, excluding: [])?.path
        }
    }

    @Test func aFileInTheProcessFolderMatches() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        let path = try folders.write("a", cwd: folders.project)
        #expect(folders.found(in: folders.project) == path)
    }

    @Test func aTrailingSlashOnEitherSideStillMatches() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        let path = try folders.write("a", cwd: folders.project + "/")
        #expect(folders.found(in: folders.project) == path)
        #expect(folders.found(in: folders.project + "/") == path)
    }

    @Test func dotsInEitherPathAreSettled() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        let path = try folders.write("a", cwd: folders.other + "/../project/./")
        #expect(folders.found(in: folders.project) == path)
    }

    @Test func aFileWhoseFolderIsASymlinkToTheProcessFolderMatches() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        let path = try folders.write("a", cwd: folders.link)
        #expect(folders.found(in: folders.project) == path)
        // And the other way round: the process runs in the link, the file names the folder.
        let reverse = try Folders.make()
        defer { reverse.remove() }
        let reversePath = try reverse.write("b", cwd: reverse.project)
        #expect(reverse.found(in: reverse.link) == reversePath)
    }

    @Test func aFileInAnotherFolderDoesNotMatch() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        try folders.write("a", cwd: folders.other)
        #expect(folders.found(in: folders.project) == nil)
        // A folder whose name only starts the same is not the same folder.
        try folders.write("b", cwd: folders.project + "-2")
        #expect(folders.found(in: folders.project) == nil)
    }

    @Test func aFileOlderThanFiveSecondsBeforeTheStartDoesNotMatch() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        // The previous session in the same folder, which ended before this process started.
        try folders.write("previous", cwd: folders.project, changedAfterStart: -6)
        #expect(folders.found(in: folders.project) == nil)
        // `ps` rounds the start to the second, so a file just before it still counts.
        let path = try folders.write("current", cwd: folders.project, changedAfterStart: -4)
        #expect(folders.found(in: folders.project) == path)
    }

    @Test func theFileChangedMostRecentlyWinsAndATakenFileIsLeftAlone() throws {
        let folders = try Folders.make()
        defer { folders.remove() }
        let older = try folders.write("older", cwd: folders.project, changedAfterStart: 10)
        let newer = try folders.write("newer", cwd: folders.project, changedAfterStart: 20)
        let files = KiroFiles(directory: folders.sessions)
        #expect(files.session(startedAt: Self.started, folder: folders.project, excluding: [])?.path == newer)
        #expect(files.session(startedAt: Self.started, folder: folders.project, excluding: [newer])?.path == older)
    }
}
