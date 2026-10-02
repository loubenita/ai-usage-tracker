import Foundation
import UsageDomain

/// What a Kiro CLI session file (`~/.kiro/sessions/cli/<session id>.json`) says about usage.
///
/// The file is rewritten as the session goes, so it is read whole each time it changes. The
/// field names first followed the reader in tokscale (github.com/junhoyeo/tokscale,
/// `crates/tokscale-core/src/sessions/kiro.rs`) and were then checked against a session file
/// from a real Kiro install.
///
/// - `session_state.rts_model_state.model_info` has the session's model and its context window
///   (1,000,000 tokens on current builds).
/// - `session_state.conversation_metadata.user_turn_metadatas` has one entry per request: the
///   model that answered it, how long it took, how many tools it called, how full the context
///   was and what it cost in credits. A session can mix models, so each request keeps its own.
/// - Each entry also has token counts, but current builds write every one of them as 0. A
///   request with no counts reports its tokens as unknown, not as zero. The credits in
///   `metering_usage` are what Kiro really reports.
/// - `session_created_reason` says why the session was opened; "subagent" marks a session a
///   parent agent started, as opposed to one a person started.
///
/// The conversation text lives beside the metadata in `<session id>.jsonl`, a transcript whose
/// non-empty lines are each `{"version":…, "kind":…, "data":…}`. Current builds write every
/// token count as 0, so a rough token figure is estimated from that text instead (see
/// `estimatedTokens(fromTranscript:)`); it is kept clearly apart from the precise counts.
struct KiroSession: Sendable, Hashable {
    struct Request: Sendable, Hashable {
        let timestamp: Date?
        let tokens: TokenUsage?
        let contextPercent: Double?
        /// What Kiro billed for the request: its `metering_usage` entries whose unit is "credit".
        let credits: Double?
        /// The model that answered this request, as the request itself names it: "auto" or
        /// "claude-opus-4.8". It can differ from the session's model.
        let model: String?
        /// How long the request took: `turn_duration`, written as seconds and nanoseconds.
        let duration: TimeInterval?
        /// Tools the request called: `builtin_tool_uses`.
        let toolCalls: Int?
        /// Characters in Kiro's reply (`assistant_response_length`) and in the prompt
        /// (`user_prompt_length`).
        let responseLength: Int?
        let promptLength: Int?
    }

    /// The window when a file leaves `context_window_tokens` out, as older Kiro files do.
    /// Current files carry their own, 1,000,000 tokens, which is what is read from the data.
    static let defaultContextWindow = 200_000

    let sessionID: String
    let folder: String?
    let model: String?
    let contextWindow: Int?
    let requests: [Request]
    /// When the session was first opened, from the file's `created_at`. A V2 CLI build may write
    /// a new file per resume, so this can be per-file rather than the very first start, but it is
    /// still a truer session start than the `kiro-cli` process uptime. Nil when the file omits it.
    let createdAt: Date?
    /// Why the session was opened: true when `session_created_reason` is "subagent", so a
    /// parent agent started it rather than a person.
    let isSubagent: Bool
    /// A rough token count estimated from the transcript text (see `estimatedTokens`), input and
    /// output only. Nil when there is no transcript or it holds no message text. It is never a
    /// precise count and is never summed into any exact token total.
    let estimatedTokens: TokenUsage?

    init?(json data: Data, fallbackID: String) {
        self.init(json: data, transcript: nil, fallbackID: fallbackID)
    }

    /// Reads the session metadata, and when `transcript` is the text of the sibling `.jsonl`,
    /// the estimated tokens from it. The transcript-free initializer above keeps estimates nil.
    init?(json data: Data, transcript: String?, fallbackID: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let state = object["session_state"] as? [String: Any]
        let modelInfo = (state?["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any]
        let metadata = state?["conversation_metadata"] as? [String: Any]
        sessionID = object["session_id"] as? String ?? object["id"] as? String ?? fallbackID
        folder = object["cwd"] as? String
        model = modelInfo?["model_id"] as? String
        // Kiro can leave the window out; tokscale then uses 200K, the window of Kiro's Auto agent.
        contextWindow = modelInfo?["context_window_tokens"] as? Int ?? Self.defaultContextWindow
        requests = (metadata?["user_turn_metadatas"] as? [[String: Any]] ?? []).map(Self.request)
        // Kiro writes `session_created_reason: "subagent"` on every CLI session (seen on all of
        // them, including the app's own /usage probe), so it does not actually mark a sub-agent
        // and cannot be trusted. There is no reliable sub-agent signal in Kiro's files, so no
        // session is treated as one.
        isSubagent = false
        createdAt = Self.date(object["created_at"])
        estimatedTokens = transcript.flatMap(Self.estimatedTokens(fromTranscript:))
    }

    private static func request(_ turn: [String: Any]) -> Request {
        func count(_ key: String) -> Int? { (turn[key] as? NSNumber)?.intValue }
        let counts = TokenUsage(
            input: count("input_token_count"),
            output: count("output_token_count"),
            cacheRead: count("cache_read_input_token_count"),
            cacheWrite: count("cache_write_input_token_count")
        )
        let metering = (turn["metering_usage"] as? [[String: Any]])?
            .filter { $0["unit"] as? String == "credit" }
            .compactMap { ($0["value"] as? NSNumber)?.doubleValue }
        return Request(
            timestamp: date(turn["end_timestamp"]),
            tokens: (counts.total ?? 0) > 0 ? counts : nil,
            contextPercent: (turn["context_usage_percentage"] as? NSNumber)?.doubleValue,
            credits: metering.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) },
            model: turn["model"] as? String,
            duration: duration(turn["turn_duration"]),
            toolCalls: count("builtin_tool_uses"),
            responseLength: count("assistant_response_length"),
            promptLength: count("user_prompt_length")
        )
    }

    /// Roughly how many input and output tokens the session's text came to, estimated from the
    /// sibling `<session id>.jsonl` transcript. Current Kiro builds write every precise count as
    /// 0, so this gives a figure where there would otherwise be none. It is deliberately a rough
    /// estimate: about `charactersPerToken` characters a token, with no cache tokens, and it is
    /// never summed into an exact total.
    ///
    /// Each non-empty line is `{"version":…, "kind":…, "data":…}`. Rather than cherry-picking
    /// the clean "text" fields, which captured only a fraction of a real session's context,
    /// this counts the FULL character length of each relevant line, including the structured
    /// JSON the model actually processes: tool-call argument trees, tool-result metadata and
    /// operation specs. The line's top-level `kind` decides which side it counts towards:
    ///
    /// - Input: "Prompt" lines (the person's text) and "ToolResults" lines (file reads, command
    ///   output and search results the model reads back). Tool results are the bulk of a real
    ///   session's bytes, so leaving them out made estimates far too low.
    /// - Output: "AssistantMessage" lines (Kiro's reply, its tool calls and its thinking).
    /// - Every other kind (version/metadata and the like) is ignored.
    ///
    /// The magnitude of a matched line is the raw line string's `.count`: the kind is read by
    /// parsing the line as JSON, but the measure is the whole line's length, which is simple and
    /// deterministic. Lines that are empty, that do not parse as JSON, or that carry no top-level
    /// `kind` are skipped rather than crashing. Nil when no relevant line is found.
    static func estimatedTokens(fromTranscript text: String) -> TokenUsage? {
        var inputChars = 0
        var outputChars = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                let kind = object["kind"] as? String
            else { continue }
            switch kind {
            case "Prompt", "ToolResults":
                inputChars += line.count
            case "AssistantMessage":
                outputChars += line.count
            default:
                continue
            }
        }
        guard inputChars > 0 || outputChars > 0 else { return nil }
        func tokens(_ characters: Int) -> Int? {
            characters > 0 ? Int((Double(characters) / charactersPerToken).rounded()) : nil
        }
        return TokenUsage(input: tokens(inputChars), output: tokens(outputChars), cacheRead: nil, cacheWrite: nil)
    }

    /// A rough average of characters per token for the transcript estimate, calibrated against
    /// Kiro's own reported `context_usage_percentage` over many real sessions. Because the
    /// transcript's structured JSON (tool-call arguments and tool-result metadata) is counted
    /// along with the plain text, since the model processes all of it, full relevant line bytes
    /// per real context token come out near 2.5. It stays a linear divisor: this is an
    /// informational per-session estimate, not a precise count.
    static let charactersPerToken = 2.5

    /// A length of time written as `{"secs": 553, "nanos": 519031792}`; nil without the seconds.
    private static func duration(_ value: Any?) -> TimeInterval? {
        guard let object = value as? [String: Any], let seconds = (object["secs"] as? NSNumber)?.doubleValue
        else { return nil }
        return seconds + ((object["nanos"] as? NSNumber)?.doubleValue ?? 0) / 1_000_000_000
    }

    /// Credits billed for requests at or after `since`, or nil when no request reported any.
    func credits(since: Date) -> Double? {
        let billed = requests.filter { ($0.timestamp ?? .distantPast) >= since }.compactMap(\.credits)
        return billed.isEmpty ? nil : billed.reduce(0, +)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A time written as epoch seconds or milliseconds (as a number or as text), an ISO 8601 string, or Rust's
    /// `{"secs_since_epoch": …}`.
    static func date(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let seconds = number.doubleValue
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        case let text as String:
            return isoFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
                ?? Double(text).flatMap { date(NSNumber(value: $0)) }
        case let object as [String: Any]:
            return (object["secs_since_epoch"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        default:
            return nil
        }
    }

    /// How full the context was after the latest request that said.
    var context: ContextUsage? {
        guard let window = contextWindow, let percent = requests.last(where: { $0.contextPercent != nil })?.contextPercent
        else { return nil }
        return ContextUsage(used: Int((percent / 100 * Double(window)).rounded()), window: window)
    }

    /// Requests with a time become turns, each with the model that answered it, the credits it
    /// was billed, how long it took and the tools it called; cost in dollars is not reported,
    /// because Kiro bills in credits. A request that names no model takes the session's, or Auto.
    func turns(sessionID: String, work: Work) -> [Turn] {
        requests.enumerated().compactMap { index, request in
            request.timestamp.map { timestamp in
                Turn(
                    id: "kiro-\(self.sessionID)-\(index)",
                    timestamp: timestamp,
                    agent: .kiro,
                    sessionID: sessionID,
                    model: ModelName(request.model ?? self.model ?? "auto"),
                    work: work,
                    tokens: request.tokens,
                    cost: Cost(usd: nil),
                    context: contextWindow.flatMap { window in
                        request.contextPercent.map {
                            ContextUsage(used: Int(($0 / 100 * Double(window)).rounded()), window: window)
                        }
                    },
                    duration: request.duration,
                    credits: request.credits,
                    toolCalls: request.toolCalls
                )
            }
        }
    }
}
