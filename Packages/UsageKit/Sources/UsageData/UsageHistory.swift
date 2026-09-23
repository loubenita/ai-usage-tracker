import Foundation
import Synchronization
import UsageDomain

/// Every agent's usage over the last week, or since the 1st of the month when that is longer,
/// including sessions that have ended, so Today, This week and Month count all the work and not
/// only the sessions open now.
///
/// It reads:
/// - Claude Code transcripts in `~/.claude/projects`, with the sub-agents' own transcripts,
///   which sit in `<session id>/subagents/` beside their session's;
/// - Codex rollouts in `~/.codex/sessions`, sub-agents included;
/// - Kiro CLI sessions in `~/.kiro/sessions/cli`;
/// - Claude's limits, as `scripts/claude-statusline.sh` saves them, and Codex's, from its rollouts.
///
/// A week of transcripts is more than a gigabyte, so the first read takes a while. It runs in
/// the background: until it finishes, Today and This week count only the open sessions. After
/// that, each refresh reads only what the files gained.
///
/// Each agent's usual pace comes from the same history, from its main sessions only: a
/// sub-agent's pace is not the owner's.
final class UsageHistory: Sendable {
    static let period: TimeInterval = 8 * 24 * 3600
    static let usualPeriod: TimeInterval = 7 * 24 * 3600
    static let refreshInterval: TimeInterval = 60

    struct Snapshot: Sendable {
        var turns: [Turn] = []
        var limits: [LimitReading] = []
        var usualRates: [Agent: UsualRate] = [:]
        /// Kiro's credits billed this calendar month.
        var creditsThisMonth: [Agent: Double] = [:]
        /// False until the first read has finished.
        var isComplete = false
    }

    private struct State {
        var snapshot = Snapshot()
        var readAt: Date?
        var isReading = false
        /// How far the saved cache had read, to save again only when a file grew.
        var savedOffset: UInt64?
    }

    private let state = Mutex(State())
    private let claudeDirectory: String
    private let homeDirectory: String
    private let codex: CodexFiles
    private let kiro: KiroFiles
    private let files = FileAccess()
    private let mainTranscripts = TranscriptStore()
    private let subagentTranscripts = TranscriptStore(includeSidechains: true)
    private let rollouts = IncrementalFileStore { CodexRollout() }
    private let minimumWorkingTime: TimeInterval
    /// Where the history is saved between launches; nil keeps it in memory only.
    private let cachePath: String?
    /// True when a saved cache was found, so the first read has only new lines to read.
    let startedFromCache: Bool

    init(
        homeDirectory: String,
        claudeDirectory: String,
        codex: CodexFiles,
        kiro: KiroFiles,
        minimumWorkingTime: TimeInterval = UsualRate.minimumWorkingTime,
        cachePath: String? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.claudeDirectory = claudeDirectory
        self.codex = codex
        self.kiro = kiro
        self.minimumWorkingTime = minimumWorkingTime
        self.cachePath = cachePath
        let cache = cachePath.flatMap(HistoryCache.load)
        startedFromCache = cache != nil
        if let cache {
            mainTranscripts.restore(cache.mainTranscripts)
            subagentTranscripts.restore(cache.subagentTranscripts)
            rollouts.restore(cache.rollouts)
        }
    }

    /// The last history read, starting a new read in the background when one is due.
    ///
    /// With a saved cache, the first read is done right here instead: only what the files gained
    /// since the last launch is read, which takes a moment, so the totals are whole from the start.
    func current(now: Date) -> Snapshot {
        let due = state.withLock { state -> (isDue: Bool, isFirst: Bool) in
            guard !state.isReading else { return (false, false) }
            if let readAt = state.readAt, now.timeIntervalSince(readAt) < Self.refreshInterval { return (false, false) }
            state.isReading = true
            return (true, state.readAt == nil)
        }
        if due.isDue && due.isFirst && startedFromCache {
            let snapshot = read(now: now)
            state.withLock { $0.snapshot = snapshot; $0.readAt = now; $0.isReading = false }
            return snapshot
        }
        if due.isDue {
            // The first read is what Today and This week wait for, so it is not left to the
            // lowest priority, where the app took over 45 seconds; later reads are small.
            Task.detached(priority: due.isFirst ? .userInitiated : .utility) {
                let snapshot = self.read(now: now)
                self.state.withLock { $0.snapshot = snapshot; $0.readAt = now; $0.isReading = false }
            }
        }
        return state.withLock { $0.snapshot }
    }

    /// Reads the whole history now. Turns are grouped into sessions by each agent's own
    /// session id, and named after the folder and branch the agent recorded.
    func read(now: Date) -> Snapshot {
        // The Month view needs the calendar month so far, which is longer than the week after the 8th.
        let monthStart = Calendar.current.dateInterval(of: .month, for: now)?.start ?? now
        let since = min(now.addingTimeInterval(-Self.period), monthStart)
        let namer = WorkNamer(files: files, homeDirectory: homeDirectory)
        var turns: [Turn] = []
        var mainSessions: [Agent: [[Turn]]] = [:]

        func add(_ sessionTurns: [Turn], agent: Agent, isMain: Bool) {
            let recent = sessionTurns.filter { $0.timestamp >= since && $0.timestamp <= now }
            turns += recent
            if isMain { mainSessions[agent, default: []].append(recent) }
        }

        // Claude Code: main transcripts, then sub-agents, named after their parent session.
        let projects = claudeDirectory + "/projects"
        let folders = files.list(projects).map { projects + "/" + $0 }
        let mains = folders.flatMap { files.files(in: $0, suffix: ".jsonl", changedSince: since) }
        mainTranscripts.keepOnly(Set(mains))
        for path in mains {
            guard let transcript = mainTranscripts.transcript(at: path) else { continue }
            let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let work = namer.work(folder: transcript.folder, branch: transcript.branch)
            add(transcript.turns(sessionID: "claude-code-\(id)", work: work), agent: .claudeCode, isMain: true)
        }
        let subagents = folders.flatMap { folder in
            files.list(folder).flatMap { session in
                files.files(in: "\(folder)/\(session)/subagents", suffix: ".jsonl", changedSince: since)
                    .map { (path: $0, session: session) }
            }
        }
        subagentTranscripts.keepOnly(Set(subagents.map(\.path)))
        for (path, session) in subagents {
            guard let transcript = subagentTranscripts.transcript(at: path) else { continue }
            let work = namer.work(folder: transcript.folder, branch: transcript.branch)
            add(transcript.turns(sessionID: "claude-code-\(session)", work: work), agent: .claudeCode, isMain: false)
        }

        // Codex: every rollout; its limits come with it.
        var limits: [LimitReading] = []
        let codexPaths = codex.rollouts(changedSince: since, now: now)
        rollouts.keepOnly(Set(codexPaths))
        for path in codexPaths {
            guard let rollout = rollouts.content(at: path) else { continue }
            let work = namer.work(folder: rollout.folder, branch: rollout.branch)
            add(rollout.turns(sessionID: "codex-\(rollout.sessionID ?? path)", work: work), agent: .codex,
                isMain: !rollout.isSubagent)
            limits += rollout.limits.filter { $0.timestamp >= since }
        }

        // Kiro, whose plan counts credits by calendar month. A chat Kiro opened to answer the
        // app's own `/usage` question is not the person's work.
        var kiroCredits: Double?
        for (_, _, session) in kiro.sessions(changedSince: since)
        where session.folder.map({ !$0.hasSuffix("/" + KiroPlanReader.folderName) }) ?? true {
            let work = namer.work(folder: session.folder, branch: nil)
            add(session.turns(sessionID: "kiro-\(session.sessionID)", work: work), agent: .kiro, isMain: true)
            if let credits = session.credits(since: monthStart) { kiroCredits = (kiroCredits ?? 0) + credits }
        }

        if let log = files.data(ClaudeLimitsLog.path(homeDirectory: homeDirectory)) {
            limits += ClaudeLimitsLog.readings(in: log, since: since)
        }

        let usualSince = now.addingTimeInterval(-Self.usualPeriod)
        let usualRates = mainSessions.compactMapValues { sessions in
            UsualRate.make(
                sessions: sessions.map { $0.filter { $0.timestamp >= usualSince } },
                minimumWorkingTime: minimumWorkingTime
            )
        }
        saveCache()
        return Snapshot(
            turns: turns, limits: limits, usualRates: usualRates,
            creditsThisMonth: kiroCredits.map { [.kiro: $0] } ?? [:], isComplete: true
        )
    }

    /// Saves what the stores have read, when a file grew since the last save.
    private func saveCache() {
        guard let cachePath else { return }
        let offset = mainTranscripts.totalOffset + subagentTranscripts.totalOffset + rollouts.totalOffset
        guard state.withLock({ $0.savedOffset }) != offset else { return }
        let cache = HistoryCache(
            mainTranscripts: mainTranscripts.saved, subagentTranscripts: subagentTranscripts.saved, rollouts: rollouts.saved
        )
        if (try? cache.save(to: cachePath)) != nil {
            state.withLock { $0.savedOffset = offset }
        }
    }
}
