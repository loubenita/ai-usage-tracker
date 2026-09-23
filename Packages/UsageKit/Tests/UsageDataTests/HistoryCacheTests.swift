import Foundation
import Testing
import UsageDomain
@testable import UsageData

/// The history saved between launches (`HistoryCache`): a restored store reads only what a file
/// gained since, reads a file again when it shrank or was replaced, and never counts a reply twice.
///
/// The Claude fixture transcript has 41 lines and 9 replies; most replies are split over several
/// lines that repeat the same `message.id`, so a split in the middle of one tests the deduplication.
@Suite("The history saved between launches")
struct HistoryCacheTests {
    let lines: [String]

    init() throws {
        lines = try Fixture.text("claude-transcript.jsonl").split(separator: "\n").map(String.init)
    }

    func temporaryFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString).jsonl").path
    }

    func write(_ lines: [String], to path: String) throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: false, encoding: .utf8)
    }

    func append(_ lines: [String], to path: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
    }

    /// A store's entries, saved to JSON and read back, as between two launches.
    func throughDisk(_ store: TranscriptStore) throws -> [String: TranscriptStore.Entry] {
        let path = temporaryFile()
        try HistoryCache(mainTranscripts: store.saved).save(to: path)
        return try #require(HistoryCache.load(from: path)).mainTranscripts
    }

    func replies(of path: String) -> [ClaudeTranscript.Reply] {
        TranscriptStore().transcript(at: path)?.replies ?? []
    }

    @Test func resumesFromTheSavedOffsetAndCountsASplitReplyOnce() throws {
        let path = temporaryFile()
        let whole = temporaryFile()
        try write(lines, to: whole)
        // Line 5 is the second line of the first reply: the reply is split across the save.
        try write(Array(lines.prefix(5)), to: path)
        let first = TranscriptStore()
        #expect(first.transcript(at: path)?.replies.count == 1)
        let saved = try throughDisk(first)

        // Blank the lines already read, keeping their length: a store that read the file from
        // the start again would lose the first reply.
        let blanked = lines.prefix(5).map { String(repeating: " ", count: $0.utf8.count) }
        try write(Array(blanked), to: path)
        try append(Array(lines.dropFirst(5)), to: path)

        let next = TranscriptStore()
        next.restore(saved)
        let read = try #require(next.transcript(at: path))
        #expect(read.replies == replies(of: whole))
        #expect(read.replies.count == 9)
        #expect(Set(read.replies.map(\.id)).count == 9)
    }

    @Test func aFileThatShrankIsReadAgainFromTheStart() throws {
        let path = temporaryFile()
        try write(lines, to: path)
        let first = TranscriptStore()
        #expect(first.transcript(at: path)?.replies.count == 9)
        let saved = try throughDisk(first)

        // Rewritten with only its last ten lines, it is now shorter than where the save stopped.
        try write(Array(lines.suffix(10)), to: path)
        let next = TranscriptStore()
        next.restore(saved)
        let read = try #require(next.transcript(at: path))
        #expect(read.replies == replies(of: path))
        #expect(read.replies.count < 9)
    }

    @Test func aFileReplacedUnderTheSamePathIsReadAgain() throws {
        let path = temporaryFile()
        try write(Array(lines.prefix(20)), to: path)
        let first = TranscriptStore()
        _ = first.transcript(at: path)
        let saved = try throughDisk(first)

        // A new file, longer than the old one, moved into the same path.
        let other = temporaryFile()
        try write(Array(lines.suffix(30)) + Array(lines.suffix(30)), to: other)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: other, toPath: path)

        let next = TranscriptStore()
        next.restore(saved)
        #expect(next.transcript(at: path)?.replies == replies(of: path))
    }

    @Test func aSavedCacheOfAnotherVersionIsIgnored() throws {
        let path = temporaryFile()
        var cache = HistoryCache()
        cache.version = HistoryCache.version + 1
        try cache.save(to: path)
        #expect(HistoryCache.load(from: path) == nil)
        #expect(HistoryCache.load(from: "/nonexistent/cache.json") == nil)
    }

    @Test func aRelaunchStartsWholeFromTheCache() throws {
        let home = try UsageHistoryTests.home()
        let cachePath = home + "/cache/history-cache.json"
        func history() -> UsageHistory {
            UsageHistory(
                homeDirectory: home, claudeDirectory: home + "/.claude",
                codex: CodexFiles(directory: home + "/.codex"), kiro: KiroFiles(directory: home + "/.kiro/sessions/cli"),
                minimumWorkingTime: 0, cachePath: cachePath
            )
        }
        let first = history()
        #expect(!first.startedFromCache)
        // With no cache yet, the first look finds nothing read: "Still reading" on the first run.
        #expect(first.current(now: UsageHistoryTests.now).isComplete == false)
        let read = first.read(now: UsageHistoryTests.now)
        #expect(FileManager.default.fileExists(atPath: cachePath))

        // The next launch has the whole history on its very first look.
        let second = history()
        #expect(second.startedFromCache)
        let snapshot = second.current(now: UsageHistoryTests.now)
        #expect(snapshot.isComplete)
        #expect(snapshot.turns.map(\.id).sorted() == read.turns.map(\.id).sorted())
        #expect(snapshot.limits.count == read.limits.count)
    }
}
