import Foundation
import Synchronization
import UsageDomain

/// Something built up one line at a time from a file that only ever grows: a Claude Code
/// transcript or a Codex rollout.
protocol LineConsumer: Sendable {
    mutating func consume(_ line: Data)
}

/// Keeps each file read so far, so every refresh reads only the lines added since the last
/// one. A file that got shorter was rewritten, and a file with a new file number was replaced;
/// either is read again from the start.
final class IncrementalFileStore<Content: LineConsumer>: Sendable {
    /// What was read of one file: the parsed content, how far it got, and which file it was.
    struct Entry: Sendable {
        var content: Content
        var offset: UInt64 = 0
        var partialLine = Data()
        /// The file's number on its disk, so a file replaced under the same path is noticed.
        var fileNumber: UInt64?
    }

    private let entries = Mutex<[String: Entry]>([:])
    private let make: @Sendable () -> Content

    init(_ make: @escaping @Sendable () -> Content) {
        self.make = make
    }

    static func fileNumber(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    func content(at path: String) -> Content? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let number = Self.fileNumber(of: path)

        return entries.withLock { entries in
            var entry = entries[path] ?? Entry(content: make(), fileNumber: number)
            if size < entry.offset || entry.fileNumber != number {
                entry = Entry(content: make(), fileNumber: number)
            }
            try? handle.seek(toOffset: entry.offset)
            // In 4 MB pieces, so a long file never sits in memory whole.
            while entry.offset < size, let data = try? handle.read(upToCount: 4 << 20), !data.isEmpty {
                entry.offset += UInt64(data.count)
                let bytes = entry.partialLine + data
                var start = bytes.startIndex
                while let newline = bytes[start...].firstIndex(of: 0x0A) {
                    if newline > start { entry.content.consume(bytes[start..<newline]) }
                    start = newline + 1
                }
                entry.partialLine = Data(bytes[start...])
            }
            entries[path] = entry
            return entry.content
        }
    }

    /// Forgets files that are no longer wanted.
    func keepOnly(_ paths: Set<String>) {
        entries.withLock { $0 = $0.filter { paths.contains($0.key) } }
    }

    /// Every file read so far, to save.
    var saved: [String: Entry] { entries.withLock { $0 } }

    /// Picks up where a saved store left off. A file read since keeps what this store read.
    func restore(_ saved: [String: Entry]) {
        entries.withLock { entries in entries.merge(saved) { current, _ in current } }
    }

    /// How far into its files the store has read, all together: it changes whenever a file grew.
    var totalOffset: UInt64 { entries.withLock { $0.values.reduce(0) { $0 + $1.offset } } }
}

extension IncrementalFileStore.Entry: Codable where Content: Codable {}

/// Keeps each Claude Code transcript read so far.
typealias TranscriptStore = IncrementalFileStore<ClaudeTranscript>

extension IncrementalFileStore where Content == ClaudeTranscript {
    /// A store for the main conversation only, or, with `includeSidechains`, for a sub-agent's
    /// transcript, whose every line is marked as a side chain.
    convenience init(includeSidechains: Bool = false) {
        self.init { ClaudeTranscript(includeSidechains: includeSidechains) }
    }

    func transcript(at path: String) -> ClaudeTranscript? { content(at: path) }
}

/// Whether a Claude Code session is working, waiting for the person, or resting.
enum ClaudeSessionState {
    /// After this long unanswered, a session that stopped is resting rather than waiting.
    static let waitingLimit: TimeInterval = 30 * 60

    /// The session file's `status` ("busy" or "idle") wins; without it, the transcript's last
    /// line decides: the agent finished its reply, or the conversation is still going.
    static func make(
        fileStatus: String?,
        statusChangedAt: Date?,
        lastSpeaker: ClaudeTranscript.LastSpeaker?,
        lastActivity: Date?,
        now: Date
    ) -> SessionState {
        switch fileStatus {
        case "busy": return .working
        case "idle": return waitingOrIdle(since: statusChangedAt ?? lastActivity, now: now)
        default: break
        }
        switch lastSpeaker {
        case .agent(stopReason: "end_turn")?: return waitingOrIdle(since: lastActivity, now: now)
        case nil: return .working
        default: return .working
        }
    }

    /// A session that stopped is waiting for the person, and resting once it has waited
    /// `waitingLimit`. Every agent's session uses this rule.
    static func waitingOrIdle(since: Date?, now: Date) -> SessionState {
        guard let since else { return .waiting }
        return now.timeIntervalSince(since) < waitingLimit ? .waiting : .idle
    }
}
