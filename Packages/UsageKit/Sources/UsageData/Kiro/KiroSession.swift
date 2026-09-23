import Foundation
import UsageDomain

/// What a Kiro CLI session file (`~/.kiro/sessions/cli/<session id>.json`) says about usage.
///
/// The file is rewritten as the session goes, so it is read whole each time it changes. The
/// field names follow the reader in tokscale (github.com/junhoyeo/tokscale,
/// `crates/tokscale-core/src/sessions/kiro.rs`), which was built against real Kiro files;
/// Kiro was not installed on the Mac this was written on.
///
/// - `session_state.rts_model_state.model_info` has the model and its context window.
/// - `session_state.conversation_metadata.user_turn_metadatas` has one entry per request, with
///   its token counts and how full the context was. Kiro's Auto agent reports zero tokens, so
///   a request with no counts reports its tokens as unknown, not as zero.
struct KiroSession: Sendable, Hashable {
    struct Request: Sendable, Hashable {
        let timestamp: Date?
        let tokens: TokenUsage?
        let contextPercent: Double?
        /// What Kiro billed for the request: its `metering_usage` entries whose unit is "credit".
        let credits: Double?
    }

    static let defaultContextWindow = 200_000

    let sessionID: String
    let folder: String?
    let model: String?
    let contextWindow: Int?
    let requests: [Request]

    init?(json data: Data, fallbackID: String) {
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
            credits: metering.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) }
        )
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

    /// Requests with a time become turns, each with the credits it was billed; cost in dollars
    /// is not reported, because Kiro bills in credits.
    func turns(sessionID: String, work: Work) -> [Turn] {
        requests.enumerated().compactMap { index, request in
            request.timestamp.map { timestamp in
                Turn(
                    id: "kiro-\(self.sessionID)-\(index)",
                    timestamp: timestamp,
                    agent: .kiro,
                    sessionID: sessionID,
                    model: ModelName(model ?? "auto"),
                    work: work,
                    tokens: request.tokens,
                    cost: Cost(usd: nil),
                    context: contextWindow.flatMap { window in
                        request.contextPercent.map {
                            ContextUsage(used: Int(($0 / 100 * Double(window)).rounded()), window: window)
                        }
                    },
                    credits: request.credits
                )
            }
        }
    }
}
