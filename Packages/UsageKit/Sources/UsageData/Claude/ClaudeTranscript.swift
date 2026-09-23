import Foundation
import UsageDomain

/// What a Claude Code transcript (`~/.claude/projects/<folder>/<session id>.jsonl`) says about
/// usage, built up line by line so a growing file only needs its new lines read.
///
/// Claude Code writes one line per content block of a reply, and every line of the same reply
/// repeats the reply's usage. So each reply is counted once, by `message.id`. Lines from
/// sub-agents (`isSidechain`) are left out of a main transcript. A sub-agent's own transcript,
/// where every line is a side chain, is read with `includeSidechains`.
struct ClaudeTranscript: LineConsumer, Codable {
    struct Reply: Sendable, Hashable, Codable {
        let id: String
        let timestamp: Date
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWriteFiveMinute: Int
        let cacheWriteOneHour: Int
        let stopReason: String?

        var cacheWrite: Int { cacheWriteFiveMinute + cacheWriteOneHour }
        /// Everything the model read to write this reply: how full the context was.
        var context: Int { input + cacheRead + cacheWrite }
    }

    /// Who spoke last in the main conversation.
    enum LastSpeaker: Sendable, Hashable, Codable {
        case person
        /// The agent handed a tool result back to itself and is still going.
        case toolResult
        case agent(stopReason: String?)
    }

    private(set) var replies: [Reply] = []
    private var replyIndex: [String: Int] = [:]
    private(set) var lastSpeaker: LastSpeaker?
    private(set) var lastActivity: Date?
    /// The folder and git branch the session last ran in, from its own lines.
    private(set) var folder: String?
    private(set) var branch: String?
    let includeSidechains: Bool
    /// The tools called, the files edited and the first thing the person asked. Only the open
    /// sessions' panels show these, so the saved history leaves them out (see `CodingKeys`).
    private(set) var activity = SessionActivityCounter()

    private enum CodingKeys: String, CodingKey {
        case replies, replyIndex, lastSpeaker, lastActivity, folder, branch, includeSidechains
    }

    init(includeSidechains: Bool = false) {
        self.includeSidechains = includeSidechains
    }

    // ISO8601DateFormatter is safe to share for parsing once configured.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Reads one line; lines that are not JSON or not about the conversation are ignored.
    /// Only the agent's replies are parsed as JSON. The person's lines, often huge tool
    /// output, are read with plain text checks, and everything else is skipped unread.
    mutating func consume(_ line: Substring) {
        consume(Data(line.utf8))
    }

    private static let assistantKey = Data(#""type":"assistant""#.utf8)
    private static let userKey = Data(#""type":"user""#.utf8)
    private static let sidechainKey = Data(#""isSidechain":true"#.utf8)
    private static let toolResultKey = Data(#""type":"tool_result""#.utf8)
    private static let timestampKey = Data(#""timestamp":""#.utf8)

    mutating func consume(_ data: Data) {
        func has(_ key: Data) -> Bool { data.range(of: key) != nil }
        if !has(Self.assistantKey) {
            guard has(Self.userKey), includeSidechains || !has(Self.sidechainKey) else { return }
            let isToolResult = has(Self.toolResultKey)
            lastSpeaker = isToolResult ? .toolResult : .person
            if let timestamp = Self.timestamp(in: data) { lastActivity = timestamp }
            // Only until the first ask is found, so the person's long pastes are parsed once at most.
            if !isToolResult, activity.firstAsk == nil { activity.firstAsk = Self.ask(in: data) }
            return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String,
            includeSidechains || object["isSidechain"] as? Bool != true
        else { return }
        let timestamp = (object["timestamp"] as? String).flatMap { Self.dateFormatter.date(from: $0) }
        if let cwd = object["cwd"] as? String { folder = cwd }
        if let gitBranch = object["gitBranch"] as? String, !gitBranch.isEmpty { branch = gitBranch }
        switch type {
        case "assistant":
            guard let message = object["message"] as? [String: Any], let reply = Self.reply(message, at: timestamp) else { return }
            if let index = replyIndex[reply.id] {
                // A later block of the same reply: same usage, but the stop reason may be filled in now.
                if reply.stopReason != nil { replies[index] = reply.keepingTime(of: replies[index]) }
            } else {
                replyIndex[reply.id] = replies.count
                replies.append(reply)
            }
            lastSpeaker = .agent(stopReason: replies[replyIndex[reply.id]!].stopReason)
            for block in message["content"] as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                let edited = Self.editingTools.contains(block["name"] as? String ?? "")
                    ? (input?["file_path"] ?? input?["notebook_path"]) as? String : nil
                activity.called(id, editing: edited)
            }
        default:
            return
        }
        if let timestamp { lastActivity = timestamp }
    }

    /// The tools that change a file, and so count towards "files changed".
    static let editingTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// What the person typed, from a line of theirs; nil for the lines Claude Code writes itself,
    /// such as a slash command's output or a skill's text.
    static func ask(in line: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["isMeta"] as? Bool != true,
            let message = object["message"] as? [String: Any]
        else { return nil }
        let text: String? = if let content = message["content"] as? String {
            content
        } else {
            (message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        return SessionActivityCounter.ask(from: text)
    }

    /// The line's `"timestamp":"…"` value. Quotes inside message text are escaped, so this
    /// only finds the line's own field.
    private static func timestamp(in line: Data) -> Date? {
        guard let key = line.range(of: timestampKey) else { return nil }
        guard let end = line[key.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return dateFormatter.date(from: String(decoding: line[key.upperBound..<end], as: UTF8.self))
    }

    private static func reply(_ message: [String: Any], at timestamp: Date?) -> Reply? {
        guard
            let id = message["id"] as? String,
            let usage = message["usage"] as? [String: Any],
            let timestamp
        else { return nil }
        func count(_ key: String, in dictionary: [String: Any] = usage) -> Int { dictionary[key] as? Int ?? 0 }
        let writes = usage["cache_creation"] as? [String: Any]
        let totalWrite = count("cache_creation_input_tokens")
        let oneHour = writes.map { count("ephemeral_1h_input_tokens", in: $0) } ?? 0
        return Reply(
            id: id,
            timestamp: timestamp,
            model: message["model"] as? String ?? "",
            input: count("input_tokens"),
            output: count("output_tokens"),
            cacheRead: count("cache_read_input_tokens"),
            // Writes with no split reported are priced as the cheaper 5-minute cache.
            cacheWriteFiveMinute: max(totalWrite - oneHour, 0),
            cacheWriteOneHour: oneHour,
            stopReason: message["stop_reason"] as? String
        )
    }

    /// The replies as turns of one session, each with its cost and the context it used.
    func turns(sessionID: String, work: Work) -> [Turn] {
        replies.map { reply in
            let price = ClaudePrices.price(for: reply.model)
            return Turn(
                id: reply.id,
                timestamp: reply.timestamp,
                agent: .claudeCode,
                sessionID: sessionID,
                model: ModelName(reply.model),
                work: work,
                tokens: TokenUsage(
                    input: reply.input, output: reply.output, cacheRead: reply.cacheRead, cacheWrite: reply.cacheWrite
                ),
                cost: Cost(usd: price?.cost(
                    input: reply.input, output: reply.output, cacheRead: reply.cacheRead,
                    cacheWriteFiveMinute: reply.cacheWriteFiveMinute, cacheWriteOneHour: reply.cacheWriteOneHour
                )),
                context: price.map { ContextUsage(used: reply.context, window: $0.contextWindow) }
            )
        }
    }
}

private extension ClaudeTranscript.Reply {
    func keepingTime(of first: Self) -> Self {
        Self(
            id: id, timestamp: first.timestamp, model: model, input: input, output: output, cacheRead: cacheRead,
            cacheWriteFiveMinute: cacheWriteFiveMinute, cacheWriteOneHour: cacheWriteOneHour, stopReason: stopReason
        )
    }
}
