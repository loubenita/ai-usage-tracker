import Foundation
import UsageDomain

/// What a Kiro V3 (ACP) session transcript (`~/.kiro/sessions/<workspace hash>/<sess id>/messages.jsonl`)
/// says about usage, built up line by line.
///
/// The newer Kiro builds keep each session in its own folder, with an append-only transcript
/// `messages.jsonl` beside a `session.json` of metadata (the folder it ran in, its title and
/// model). The transcript carries two kinds of line the credit reading needs:
///
/// - `"assistant"` lines carry `payload.reasoningModelId`, a namespaced model id such as
///   "qdev::auto", and share an `executionId` with the turn's usage line. They are gathered into
///   a map so each turn's usage can be labelled with the model that answered it.
/// - `"usage_summary"` lines carry one turn's billing: `promptTurnSummaries[].usage` whose
///   `unit` is "credit", the tools it called, how long it took (`elapsedTime`, milliseconds),
///   its `status` and its `executionId`.
///
/// Each `usage_summary` becomes one `Usage`, from which the enumerator makes a `Turn`, whatever
/// its `status`. An aborted or failed turn ("aborted", "error") still spends the credits it
/// reports, so its credits are counted the same as a successful turn's; only the status is kept
/// apart (`isSuccess`) in case a view ever wants it, and it never gates the credit reading.
/// Every line is parsed defensively: a malformed or partial line is skipped rather than allowed
/// to crash.
///
/// The file grows and is never rewritten, so it is read with `IncrementalFileStore`, the same
/// way Claude Code transcripts and Codex rollouts are, reading only the lines added since the
/// last refresh.
struct KiroV3Transcript: LineConsumer, Codable {
    /// One turn's billing, from a `usage_summary` line, whatever its status.
    struct Usage: Sendable, Hashable, Codable {
        let executionId: String
        let timestamp: Date
        /// Credits billed for the turn: the sum of `promptTurnSummaries[].usage` whose unit is
        /// "credit". Nil when the turn reported none. Counted whether the turn succeeded or not,
        /// since an aborted or failed turn still spends what it reports.
        let credits: Double?
        /// Tools the turn called: the count of `promptTurnSummaries[].usedTools`.
        let toolCalls: Int
        /// How long the turn took: `elapsedTime`, written in milliseconds.
        let duration: TimeInterval?
        /// Whether the turn's `status` was "success". Kept for display only; it never gates the
        /// credit reading, because a non-success turn is still billed.
        let isSuccess: Bool
    }

    /// The model that answered each turn, keyed by its `executionId`, from the `assistant` lines.
    private(set) var models: [String: String] = [:]
    /// The turns' billing, in the order they were read.
    private(set) var usages: [Usage] = []

    private static let assistantKey = Data(#""type":"assistant""#.utf8)
    private static let usageKey = Data(#""type":"usage_summary""#.utf8)

    mutating func consume(_ line: Data) {
        // Only the two line kinds the reading needs are parsed as JSON; everything else is skipped.
        let isAssistant = line.range(of: Self.assistantKey) != nil
        let isUsage = line.range(of: Self.usageKey) != nil
        guard isAssistant || isUsage else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let payload = object["payload"] as? [String: Any]
        else { return }

        if isAssistant {
            readAssistant(payload)
            return
        }
        readUsage(payload, timestamp: KiroSession.date(object["timestamp"]))
    }

    private mutating func readAssistant(_ payload: [String: Any]) {
        guard
            let executionId = payload["executionId"] as? String,
            let model = payload["reasoningModelId"] as? String
        else { return }
        models[executionId] = model
    }

    private mutating func readUsage(_ payload: [String: Any], timestamp: Date?) {
        guard
            payload["type"] as? String == "usage_summary",
            let executionId = payload["executionId"] as? String,
            let timestamp
        else { return }
        let summaries = payload["promptTurnSummaries"] as? [[String: Any]] ?? []
        let credited = summaries
            .filter { $0["unit"] as? String == "credit" }
            .compactMap { ($0["usage"] as? NSNumber)?.doubleValue }
        let toolCalls = summaries.reduce(0) { $0 + (($1["usedTools"] as? [Any])?.count ?? 0) }
        let elapsed = (payload["elapsedTime"] as? NSNumber)?.doubleValue
        usages.append(Usage(
            executionId: executionId,
            timestamp: timestamp,
            credits: credited.isEmpty ? nil : credited.reduce(0, +),
            toolCalls: toolCalls,
            duration: elapsed.map { $0 / 1000 },
            isSuccess: payload["status"] as? String == "success"
        ))
    }

    /// Strips a namespace prefix such as "qdev::" from a model id, so a V3 "qdev::auto" groups
    /// with a V2 "auto" in the by-model and model-share views. Only the V3 model string is
    /// passed through this. An id with no "::" is returned unchanged.
    static func normalisedModel(_ id: String) -> String {
        guard let range = id.range(of: "::", options: .backwards) else { return id }
        return String(id[range.upperBound...])
    }

    /// Every turn as a turn of one session, whatever its status. Each turn takes the model that
    /// answered it (its `reasoningModelId`, with the namespace stripped), or the session's model,
    /// or "auto". Kiro bills in credits, so cost in dollars is not reported, and the newer builds
    /// carry no per-turn token counts, so tokens are unknown.
    ///
    /// `sessUUID` is the session folder's name; the turn ids are "kiroV3-<sess>-<execId>", which
    /// are disjoint from the V2 CLI "kiro-..." ids, so the two sources never collide.
    func turns(sessUUID: String, sessionID: String, work: Work, sessionModel: String?) -> [Turn] {
        usages.map { usage in
            let raw = models[usage.executionId] ?? sessionModel ?? "auto"
            return Turn(
                id: "kiroV3-\(sessUUID)-\(usage.executionId)",
                timestamp: usage.timestamp,
                agent: .kiro,
                sessionID: sessionID,
                model: ModelName(Self.normalisedModel(raw)),
                work: work,
                tokens: nil,
                cost: Cost(usd: nil),
                context: nil,
                duration: usage.duration,
                credits: usage.credits,
                toolCalls: usage.toolCalls
            )
        }
    }

    /// Credits billed for turns at or after `since`, or nil when none reported any.
    func credits(since: Date) -> Double? {
        let billed = usages.filter { $0.timestamp >= since }.compactMap(\.credits)
        return billed.isEmpty ? nil : billed.reduce(0, +)
    }
}
