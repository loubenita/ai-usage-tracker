import Foundation
import UsageDomain

/// What a Codex rollout (`~/.codex/sessions/<year>/<month>/<day>/rollout-….jsonl`) says about
/// usage, built up line by line.
///
/// - The first line, `session_meta`, gives the session's id, folder and git branch, and says
///   whether a sub-agent wrote it.
/// - `turn_context` lines give the model and its reasoning effort.
/// - Each `token_count` event reports one model request: `last_token_usage` is that request,
///   and `rate_limits` is the plan's limits at that moment. An event whose running total did
///   not move reports only limits, and adds no reply.
/// - `task_started` and `task_complete` say whether Codex is working or waiting for the person.
///
/// OpenAI counts cached input inside `input_tokens`, and reasoning inside `output_tokens`. So
/// cached input is taken out of input, and reasoning is not added to output a second time.
struct CodexRollout: LineConsumer, Codable {
    struct Reply: Sendable, Hashable, Codable {
        let id: String
        let timestamp: Date
        let model: String
        let input: Int
        let cachedInput: Int
        let cacheWrite: Int
        let output: Int
        /// Tokens the request used, out of `contextWindow`.
        let context: Int
        let contextWindow: Int?
    }

    private(set) var sessionID: String?
    private(set) var startedAt: Date?
    private(set) var folder: String?
    private(set) var branch: String?
    private(set) var isSubagent = false
    private(set) var model: String?
    /// The reasoning effort of the latest turn, such as "medium".
    private(set) var effort: String?
    private(set) var replies: [Reply] = []
    private(set) var limits: [LimitReading] = []
    /// When Codex last started or finished working on the person's request.
    private(set) var lastTaskStart: Date?
    private(set) var lastTaskEnd: Date?
    private var lastTotal: Int?
    /// The tools called, the files patched and the first thing the person asked. Only the open
    /// sessions' panels show these, so the saved history leaves them out (see `CodingKeys`).
    private(set) var activity = SessionActivityCounter()

    private enum CodingKeys: String, CodingKey {
        case sessionID, startedAt, folder, branch, isSubagent, model, effort, replies, limits, lastTaskStart
        case lastTaskEnd, lastTotal
    }

    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wantedKeys = [
        #""type":"session_meta""#, #""type":"turn_context""#, #""type":"token_count""#,
        #""type":"task_started""#, #""type":"task_complete""#, #""type":"turn_aborted""#,
    ].map { Data($0.utf8) }

    private static let toolCallKeys = [#""type":"function_call""#, #""type":"custom_tool_call""#, #""type":"local_shell_call""#]
        .map { Data($0.utf8) }
    private static let userMessageKey = Data(#""role":"user""#.utf8)

    mutating func consume(_ line: Data) {
        if Self.toolCallKeys.contains(where: { line.range(of: $0) != nil }) {
            readToolCall(line)
            return
        }
        // Only until the first ask is found, so the person's long pastes are parsed once at most.
        if activity.firstAsk == nil, line.range(of: Self.userMessageKey) != nil, line.range(of: Self.messageKey) != nil {
            activity.firstAsk = Self.ask(in: line)
            return
        }
        // Most lines are messages and tool output; only these few are parsed as JSON.
        guard
            Self.wantedKeys.contains(where: { line.range(of: $0) != nil }),
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = object["payload"] as? [String: Any]
        else { return }
        let timestamp = (object["timestamp"] as? String).flatMap { Self.dateFormatter.date(from: $0) }

        switch object["type"] as? String {
        case "session_meta":
            sessionID = payload["id"] as? String ?? payload["session_id"] as? String
            startedAt = (payload["timestamp"] as? String).flatMap { Self.dateFormatter.date(from: $0) } ?? timestamp
            folder = payload["cwd"] as? String
            branch = (payload["git"] as? [String: Any])?["branch"] as? String
            isSubagent = (payload["source"] as? [String: Any])?["subagent"] != nil
        case "turn_context":
            if let model = payload["model"] as? String { self.model = model }
            if let effort = payload["effort"] as? String { self.effort = effort }
            if let cwd = payload["cwd"] as? String { folder = cwd }
        case "event_msg":
            guard let timestamp else { return }
            switch payload["type"] as? String {
            case "token_count": readTokenCount(payload, at: timestamp)
            case "task_started": lastTaskStart = timestamp
            case "task_complete", "turn_aborted": lastTaskEnd = timestamp
            default: return
            }
        default:
            return
        }
    }

    private static let messageKey = Data(#""type":"message""#.utf8)

    /// A tool call, counted once by its id. A patch names the files it changes on lines such as
    /// "*** Update File: /path", whichever tool carries it.
    private mutating func readToolCall(_ line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = object["payload"] as? [String: Any],
            let id = payload["call_id"] as? String ?? payload["id"] as? String
        else { return }
        let text = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
        activity.called(id, editing: nil)
        for file in Self.patchedFiles(in: text) { activity.called(id, editing: file) }
    }

    static func patchedFiles(in text: String) -> [String] {
        let markers = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            // Inside a JSON string the patch's newlines are "\n", so a marker may end at one.
            return markers.first { line.hasPrefix($0) }.map { marker in
                String(line.dropFirst(marker.count).prefix { $0 != "\\" && $0 != "\"" })
            }
        }
    }

    /// The person's words from a `message` line of theirs; nil for the context Codex adds itself.
    static func ask(in line: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = object["payload"] as? [String: Any],
            payload["role"] as? String == "user",
            let content = payload["content"] as? [[String: Any]]
        else { return nil }
        let texts = content.compactMap { $0["text"] as? String }
        return texts.lazy.compactMap(SessionActivityCounter.ask(from:)).first
    }

    private mutating func readTokenCount(_ payload: [String: Any], at timestamp: Date) {
        if let limits = payload["rate_limits"] as? [String: Any], let reading = Self.limitReading(limits, at: timestamp) {
            self.limits.append(reading)
        }
        guard
            let info = payload["info"] as? [String: Any],
            let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int,
            let last = info["last_token_usage"] as? [String: Any],
            total != lastTotal
        else { return }
        lastTotal = total
        func count(_ key: String) -> Int { last[key] as? Int ?? 0 }
        let input = count("input_tokens")
        let cached = min(count("cached_input_tokens"), input)
        replies.append(Reply(
            id: "\(sessionID ?? "codex")-\(total)",
            timestamp: timestamp,
            model: model ?? "",
            input: input - cached,
            cachedInput: cached,
            cacheWrite: count("cache_write_input_tokens"),
            output: count("output_tokens"),
            context: count("total_tokens"),
            contextWindow: info["model_context_window"] as? Int
        ))
    }

    /// Codex names its windows by length: 300 minutes is the 5-hour limit, 10,080 the weekly one.
    /// Some models have limits of their own, such as `codex_bengalfox` for GPT-5.3-Codex-Spark;
    /// only the plan's main `codex` limit is read.
    private static func limitReading(_ limits: [String: Any], at timestamp: Date) -> LimitReading? {
        if let id = limits["limit_id"] as? String, id != "codex" { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> LimitWindowReading? in
            guard
                let window = limits[key] as? [String: Any],
                let used = (window["used_percent"] as? NSNumber)?.doubleValue,
                let minutes = window["window_minutes"] as? Int,
                let resets = (window["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            let kind: LimitWindowKind? = switch minutes {
            case 300: .fiveHour
            case 10_080: .weekly
            default: nil
            }
            return kind.map { LimitWindowReading(kind: $0, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets)) }
        }
        guard !windows.isEmpty else { return nil }
        return LimitReading(timestamp: timestamp, agent: .codex, plan: limits["plan_type"] as? String, windows: windows)
    }

    /// Working while a task has started and not finished; otherwise waiting since it finished.
    func state(now: Date) -> SessionState {
        guard let lastTaskEnd else { return .working }
        if let lastTaskStart, lastTaskStart > lastTaskEnd { return .working }
        return ClaudeSessionState.waitingOrIdle(since: lastTaskEnd, now: now)
    }

    /// The replies as turns of one session. Codex's prices are not in the app, so cost is not
    /// reported rather than guessed.
    func turns(sessionID: String, work: Work) -> [Turn] {
        replies.map { reply in
            Turn(
                id: reply.id,
                timestamp: reply.timestamp,
                agent: .codex,
                sessionID: sessionID,
                model: ModelName(reply.model),
                work: work,
                tokens: TokenUsage(
                    input: reply.input, output: reply.output, cacheRead: reply.cachedInput, cacheWrite: reply.cacheWrite
                ),
                cost: Cost(usd: nil),
                context: reply.contextWindow.map { ContextUsage(used: reply.context, window: $0) }
            )
        }
    }
}
