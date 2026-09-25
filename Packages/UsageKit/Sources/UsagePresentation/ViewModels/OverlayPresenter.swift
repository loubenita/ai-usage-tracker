import Foundation
import UsageDomain

/// Maps a `UsageReport` to the strip and the session panel the views draw. Pure, so every
/// sentence and number on screen can be unit-tested without a window. The usage panel is
/// `UsagePanelPresenter`.
public struct OverlayPresenter: Sendable {
    /// The first ask is kept in the selected session's details and cut to this many characters.
    static let firstAskLength = 28

    let format: UsageFormatter

    public init(formatter: UsageFormatter) {
        self.format = formatter
    }

    // MARK: - Strip

    public func strip(
        _ report: UsageReport,
        hovered: String?,
        open: String?,
        acknowledged: Set<String>,
        expanded: Bool = true
    ) -> StripModel {
        // Which sessions were busy most recently, so the resting strip can show those first.
        let byRecency = report.sessions
            .sorted { $0.summary.lastActivityAt > $1.summary.lastActivityAt }
            .enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let items = report.sessions.map { session in
            let summary = session.summary
            let highlight: ItemHighlight =
                summary.id == open ? .selected : summary.id == hovered ? .hovered : .none
            return StripItemModel(
                id: summary.id,
                ring: ring(session),
                title: session.title,
                // Short, so it fits the 30pt strip; the panel says it in full.
                time: format.compactDuration(summary.activeDuration),
                needsUser: summary.needsUser,
                pulses: summary.needsUser && !acknowledged.contains(summary.id),
                highlight: highlight,
                recency: byRecency[summary.id] ?? 0,
                accessibilityLabel: [
                    session.title,
                    summary.agent.displayName,
                    summary.work.tag.project,
                    summary.activity?.firstAsk,
                    format.duration(summary.activeDuration),
                    summary.context.map {
                        "context \(format.tokens($0.used)) of \(format.tokens($0.window)), \(format.percent($0.fraction)) full"
                    },
                    status(session, report: report).text.lowercased(),
                ].compactMap { $0 }.joined(separator: ", ")
            )
        }
        return StripModel(items: items, isExpanded: expanded)
    }

    // MARK: - Session panel

    public func panel(_ report: UsageReport, sessionID: String) -> SessionPanelModel? {
        guard let session = report.sessions.first(where: { $0.id == sessionID }) else { return nil }
        let summary = session.summary
        return SessionPanelModel(
            sessionID: sessionID,
            agent: summary.agent,
            subtitle: summary.work.tag.project,
            title: session.title,
            openAction: summary.origin.flatMap(openAction),
            status: status(session, report: report),
            stats: stats(summary),
            context: contextRow(session, now: report.now),
            tokenMix: summary.tokens.map(tokenMix) ?? [],
            tokenMixNote: summary.tokens.flatMap(tokenMixNote),
            subagents: subagents(summary),
            details: details(session, now: report.now)
        )
    }

    func openAction(_ origin: SessionOrigin) -> SessionOpenAction? {
        switch TerminalFocus.action(for: origin) {
        case .session: .session
        case .application(let terminal): .terminal(terminal.displayName)
        case nil: nil
        }
    }

    /// Spent, Tokens, Active and Turns, each only when the agent reported it. An agent that
    /// bills in credits shows its credits where the cost would be.
    func stats(_ summary: SessionSummary) -> [StatModel] {
        let spent: StatModel? = if let cost = summary.costUSD, cost > 0 {
            StatModel(label: "Total spent", value: format.usd(cost))
        } else if let credits = summary.credits, credits > 0 {
            StatModel(label: "Credits", value: format.credits(credits))
        } else {
            nil
        }
        return [
            spent,
            summary.tokens?.total.flatMap {
                $0 > 0 ? StatModel(label: "Total tokens", value: format.tokens($0)) : nil
            },
            summary.activeDuration >= 60 ? StatModel(label: "Active", value: format.duration(summary.activeDuration)) : nil,
            summary.turnCount > 0 ? StatModel(label: "Turns", value: "\(summary.turnCount)") : nil,
        ].compactMap { $0 }
    }

    /// "Context 34%" over "68k of 200k · full ~15:15".
    func contextRow(_ session: SessionReport, now: Date) -> BarRowModel? {
        guard let context = session.summary.context else { return nil }
        var detail = "\(format.tokens(context.used)) of \(format.tokens(context.window))"
        if let full = session.contextFullAt, full > now {
            detail += " · full ~\(format.approximateClock(full))"
        }
        return BarRowModel(
            title: "Context \(format.percent(context.fraction))", detail: detail, fraction: context.fraction,
            highlightFraction: nil, isNearlyUsed: false, note: nil
        )
    }

    /// The session's sub-agents, one row per run, with an aggregate and their share of the
    /// session's spend, or of its tokens when no cost is known. Nil when it started none.
    func subagents(_ summary: SessionSummary) -> SubagentsModel? {
        let runs = summary.subagents
        guard !runs.isEmpty else { return nil }
        let share: String? = if let cost = summary.subagentCostUSD, let total = summary.costUSD, total > 0 {
            "\(format.percent(Share.of(cost, in: total))) of session spend"
        } else if let total = summary.tokens?.total, total > 0, summary.subagentTokens > 0 {
            "\(format.percent(Double(summary.subagentTokens) / Double(total))) of session tokens"
        } else {
            nil
        }
        let totalTokens = summary.subagentTokens
        let totalTime = runs.reduce(0) { $0 + $1.workingTime }
        let total = [
            totalTokens > 0 ? format.tokens(totalTokens) : nil,
            summary.subagentCostUSD.map(format.usd),
            totalTime >= 60 ? format.duration(totalTime) : "<1m",
        ].compactMap { $0 }.joined(separator: " · ") + " combined"
        let rows = runs.enumerated().map { index, run in
            let tokens = run.tokens?.total
            return SubagentRowModel(
                id: run.id,
                model: run.model.displayName,
                run: "Run \(index + 1)",
                tokens: tokens.flatMap { $0 > 0 ? format.tokens($0) : nil },
                cost: run.costUSD.map(format.usd),
                time: run.workingTime >= 60 ? format.duration(run.workingTime) : "<1m"
            )
        }
        return SubagentsModel(
            title: "SUB-AGENT RUNS · \(runs.count)",
            inclusion: "Included in session totals",
            share: share,
            total: total,
            rows: rows
        )
    }

    /// "5-hour limit", "Week limit", "Month limit", "Plan".
    static func limitName(_ kind: LimitStanding.Kind) -> String {
        switch kind {
        case .fiveHour: "5-hour limit"
        case .weekly: "Week limit"
        case .monthly: "Month limit"
        case .plan: "Plan"
        }
    }

    /// Pace, Model, Started, Work, Branch and First ask: those the agent's records hold.
    func details(_ session: SessionReport, now: Date) -> [DetailRowModel] {
        let summary = session.summary
        let pace = session.tokensPerHour.map { rate in
            ["\(format.tokenRate(rate))/h", session.rateComparedWithUsual.map(format.timesUsual)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        let model = summary.model.map { model in
            summary.effort.map { "\(model.displayName) · \($0) effort" } ?? model.displayName
        }
        let activity = summary.activity
        let work = [
            activity?.toolCalls.flatMap { $0 > 0 ? Self.count($0, "tool call") : nil },
            activity?.filesChanged.flatMap { $0 > 0 ? Self.count($0, "file changed", plural: "files changed") : nil },
        ].compactMap { $0 }
        return [
            pace.map { DetailRowModel(label: "Pace", value: $0) },
            model.map { DetailRowModel(label: "Model", value: $0) },
            DetailRowModel(
                label: "Started",
                value: "\(format.clock(summary.startedAt)) · open \(format.duration(now.timeIntervalSince(summary.startedAt)))"
            ),
            work.isEmpty ? nil : DetailRowModel(label: "Work", value: work.joined(separator: " · ")),
            summary.work.branch.map { DetailRowModel(label: "Branch", value: $0) },
            activity?.firstAsk.map { DetailRowModel(label: "First ask", value: quoted($0)) },
        ].compactMap { $0 }
    }

    /// "64 tool calls", "1 tool call".
    static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        value == 1 ? "1 \(singular)" : "\(value) \(plural ?? singular + "s")"
    }

    /// The ask in quotes, cut with "…" so the closing quote shows.
    func quoted(_ ask: String) -> String {
        let cut = ask.count > Self.firstAskLength
            ? ask.prefix(Self.firstAskLength).trimmingCharacters(in: .whitespaces) + "…" : ask
        return "\"\(cut)\""
    }

    // MARK: - Shared pieces

    func ring(_ session: SessionReport) -> RingModel {
        let context = session.summary.context
        return RingModel(
            // The label and arc always describe the same live context reading.
            label: context.map { format.ringTokens($0.used) } ?? session.code,
            fraction: context?.fraction ?? 0,
            isNearlyFull: session.isContextNearlyFull,
            agent: session.summary.agent
        )
    }

    /// What the session is doing, how long it has waited, and where it runs.
    func status(_ session: SessionReport, report: UsageReport) -> StatusModel {
        let summary = session.summary
        let place = summary.origin.flatMap(Self.place)
        let waited = summary.stateSince.flatMap { since -> String? in
            let interval = report.now.timeIntervalSince(since)
            return interval >= 60 ? format.duration(interval) : nil
        }
        switch summary.state {
        case .waiting:
            return StatusModel(
                kind: .waiting, text: ["Waiting for your reply", waited].compactMap { $0 }.joined(separator: " · "),
                place: place
            )
        case .working where session.isContextNearlyFull:
            return StatusModel(kind: .contextNearlyFull, text: "Working · context nearly full", place: place)
        case .working:
            return StatusModel(kind: .working, text: "Working", place: place)
        case .idle, .ended:
            return StatusModel(kind: .idle, text: ["Idle", waited].compactMap { $0 }.joined(separator: " · "), place: place)
        }
    }

    /// "Warp · tmux lead", "Terminal · ttys004", "Warp"; nil when the terminal is not known.
    static func place(_ origin: SessionOrigin) -> String? {
        switch origin.terminal {
        case .tmux:
            let host = origin.hostTerminal.map(\.displayName)
            let session = origin.tmux.map { "tmux \($0.session)" } ?? "tmux"
            return [host, session].compactMap { $0 }.joined(separator: " · ")
        case .terminal:
            return "Terminal · \(origin.tty)"
        case .unknown:
            return nil
        default:
            return origin.terminal.displayName
        }
    }

    /// "Input 52k", "Output 14k", "Cache read 200k", "Cache write 14k": what the agent reported.
    func tokenMix(_ tokens: TokenUsage) -> [TokenSegmentModel] {
        let parts: [(SegmentStyle, String, Int?)] = [
            (.input, "Input", tokens.input), (.output, "Output", tokens.output),
            (.cacheRead, "Cache read", tokens.cacheRead), (.cacheWrite, "Cache write", tokens.cacheWrite),
        ]
        return parts.compactMap { style, name, value in
            guard let value, value > 0 else { return nil }
            return TokenSegmentModel(
                style: style, label: name, value: format.tokens(value)
            )
        }
    }

    func tokenMixNote(_ tokens: TokenUsage) -> String? {
        guard (tokens.cacheRead ?? 0) > 0 else { return nil }
        return "Input is new, uncached text. Cache read is context reused from earlier turns."
    }
}
