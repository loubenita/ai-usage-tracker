import Foundation
import Synchronization
import UsageDomain

/// Serves the agent sessions running in terminals on this Mac, found from the process table,
/// with the last week of every agent's usage for Today and This week.
///
/// Each detected session becomes a `start` record at the process's start time, so the strip's
/// timer shows how long it has been running. Then each agent's own files add what they know:
///
/// | Agent | File | What it gives |
/// |---|---|---|
/// | Claude Code | the transcript, found through `~/.claude/sessions/<pid>.json`, and its sub-agents' beside it | replies, cost, status |
/// | Codex | the rollout in `~/.codex/sessions` | replies, status, limits |
/// | Cursor Agent | the chat's `store.db` in `~/.cursor/chats` | context, model, prompts |
/// | Kiro CLI | the session in `~/.kiro/sessions/cli` | requests, context |
///
/// Everything is read, never written, and no other process is signalled. The one program the app
/// runs is `kiro-cli`, to ask for Kiro's plan (see `KiroPlanReader`), when it is installed.
public struct ProcessSessionRepository: UsageRepository {
    /// A Cursor or Kiro session whose files changed this recently is taken to be working; they
    /// record no "finished" event, so a quiet session is taken to be waiting for the person.
    static let quietAfter: TimeInterval = 30

    private let source: any ProcessSource
    private let claudeDirectory: String
    private let timeZone: TimeZone
    private let usageSettings: UsageSettings
    private let files = FileAccess()
    private let homeDirectory: String
    private let transcripts = TranscriptStore()
    private let subagentTranscripts = TranscriptStore(includeSidechains: true)
    private let rollouts = IncrementalFileStore { CodexRollout() }
    private let codex: CodexFiles
    private let cursor: CursorFiles
    private let kiro: KiroFiles
    private let history: UsageHistory
    private let kiroPlan: KiroPlanReader
    private let liveCache = LiveCache()

    public init(
        source: any ProcessSource = SystemProcessSource(),
        homeDirectory: String = NSHomeDirectory(),
        claudeDirectory: String? = nil,
        timeZone: TimeZone = .current,
        settings: UsageSettings = ProcessSessionRepository.defaultSettings,
        historyCachePath: String? = nil,
        filesInterval: TimeInterval = ProcessSessionRepository.defaultFilesInterval
    ) {
        self.filesInterval = filesInterval
        self.source = source
        self.homeDirectory = homeDirectory
        self.claudeDirectory = claudeDirectory ?? homeDirectory + "/.claude"
        self.timeZone = timeZone
        self.usageSettings = settings
        self.codex = CodexFiles(directory: homeDirectory + "/.codex")
        self.cursor = CursorFiles(directory: homeDirectory + "/.cursor")
        self.kiro = KiroFiles(directory: homeDirectory + "/.kiro/sessions/cli")
        self.history = UsageHistory(
            homeDirectory: homeDirectory, claudeDirectory: self.claudeDirectory, codex: codex, kiro: kiro,
            cachePath: historyCachePath
        )
        self.kiroPlan = KiroPlanReader(homeDirectory: homeDirectory)
    }

    /// Where the app keeps the history between launches (see `HistoryCache`).
    public static func historyCachePath(homeDirectory: String = NSHomeDirectory()) -> String {
        HistoryCache.path(homeDirectory: homeDirectory)
    }

    /// The owner's label table. No budgets: the design's $9 and 2.6M were examples, and there
    /// is no setting for a real one yet, so Today and This week compare nothing with a budget.
    public static let defaultSettings = UsageSettings(
        dailyCostBudget: nil,
        dailyTokenBudget: nil,
        workdayEndHour: 20,
        labelRules: LabelRules.table
    )

    /// A session's own files are read again at most this often by default; the process list,
    /// which says which sessions are open, is read on every call.
    public static let defaultFilesInterval: TimeInterval = 6
    private let filesInterval: TimeInterval

    public func records(from start: Date, to end: Date) async throws -> UsageRecords {
        try records(from: start, to: end, includeHistory: true)
    }

    /// The open sessions without the month of past turns, for the strip's quick refresh.
    public func sessionRecords(from start: Date, to end: Date) async throws -> UsageRecords {
        try records(from: start, to: end, includeHistory: false)
    }

    private func records(from start: Date, to end: Date, includeHistory: Bool) throws -> UsageRecords {
        let rows = ProcessTable.parse(try source.processList(), timeZone: timeZone)
        let found = TerminalAgentFinder.find(in: rows).sorted { $0.process.startedAt < $1.process.startedAt }
        let tmuxHost = found.contains { $0.terminal == .tmux } ? TerminalAgentFinder.tmuxClientTerminal(in: rows) : nil
        let now = Date()
        let due = found.filter { liveCache.entry(for: $0, now: now, maxAge: filesInterval) == nil }
        let claudeSessions = due.contains { $0.agent == .claudeCode } ? readClaudeSessionFiles() : []
        var live = LiveSessions()
        for agent in found {
            read(agent, claudeSessions: claudeSessions, tmuxHost: tmuxHost, now: now, into: &live)
        }
        liveCache.keepOnly(found)
        transcripts.keepOnly(live.claudeTranscripts)
        subagentTranscripts.keepOnly(live.subagentTranscripts)
        rollouts.keepOnly(live.rollouts)

        let past = history.current(now: now)
        let inRange = { (date: Date) in date >= start && date <= end }
        // The history's copy of a live session's replies is replaced by the live one, which is
        // newer and carries the live session's id.
        let turns: [Turn]
        if includeHistory {
            let liveIDs = Set(live.turns.map(\.id))
            turns = live.turns + past.turns.filter { !liveIDs.contains($0.id) }
        } else {
            turns = live.turns
        }
        return UsageRecords(
            turns: turns.filter { inRange($0.timestamp) },
            limits: includeHistory ? Array(Set(past.limits + live.limits)) : live.limits,
            sessionEvents: live.events,
            capturedAt: now,
            usualRates: past.usualRates,
            isHistoryComplete: past.isComplete,
            creditsThisMonth: past.creditsThisMonth,
            plans: kiroPlan.current(now: now).map { [.kiro: $0] } ?? [:]
        )
    }

    public func settings() async throws -> UsageSettings { usageSettings }

    // MARK: - One session

    /// What the open sessions gave this refresh, and which files they use.
    fileprivate struct LiveSessions {
        var events: [SessionEvent] = []
        var turns: [Turn] = []
        var limits: [LimitReading] = []
        var claudeTranscripts: Set<String> = []
        var subagentTranscripts: Set<String> = []
        var rollouts: Set<String> = []
        var cursorChats: Set<String> = []
        var kiroSessions: Set<String> = []
    }

    /// What an agent's own files say about one session.
    fileprivate struct AgentFiles {
        var agentSessionID: String?
        var transcriptPath: String?
        var sessionName: String?
        var turns: [Turn] = []
        var limits: [LimitReading] = []
        var state: SessionState?
        var snapshot: SessionSnapshot?
        /// Where the session runs in tmux, when its agent records it (Claude Code does).
        var tmux: TmuxLocation?
    }

    private func read(
        _ found: TerminalAgentProcess, claudeSessions: [ClaudeSessionFile], tmuxHost: TerminalApp?, now: Date,
        into live: inout LiveSessions
    ) {
        let process = found.process
        let sessionID = "\(found.agent.rawValue)-\(process.pid)"
        let folder: String
        let work: Work
        let agentFiles: AgentFiles
        if let cached = liveCache.entry(for: found, now: now, maxAge: filesInterval) {
            // Read a few seconds ago: the same files, claimed again so their stores keep them.
            (folder, work, agentFiles) = (cached.folder, cached.work, cached.files)
            live.claim(cached.claimed)
        } else {
            let claude = found.agent == .claudeCode
                ? ClaudeSessionIndex.file(forPID: process.pid, startedAt: process.startedAt, in: claudeSessions)
                : nil
            folder = source.workingDirectory(of: process.pid) ?? claude?.cwd ?? homeDirectory
            work = WorkNamer(files: files, homeDirectory: homeDirectory).work(folder: folder, branch: nil)
            let before = live.claimed
            switch found.agent {
            case .claudeCode:
                agentFiles = claude.map { claudeFiles($0, sessionID: sessionID, work: work, now: now, live: &live) }
                    ?? AgentFiles()
            case .codex:
                agentFiles = codexFiles(process, folder: folder, sessionID: sessionID, work: work, now: now, live: &live)
            case .cursor:
                agentFiles = cursorFiles(process, folder: folder, now: now, live: &live)
            case .kiro:
                agentFiles = kiroFiles(process, folder: folder, sessionID: sessionID, work: work, now: now, live: &live)
            case .antigravity, .opencode:
                agentFiles = AgentFiles()
            }
            liveCache.store(
                LiveCache.Entry(
                    readAt: now, folder: folder, work: work, files: agentFiles, claimed: live.claimed.subtracting(before)
                ),
                for: found
            )
        }

        let start = SessionEvent(
            timestamp: process.startedAt,
            agent: found.agent,
            sessionID: sessionID,
            kind: .start,
            state: .working,
            activeDuration: 0,
            idleDuration: 0,
            work: work.tag,
            workDetail: work,
            origin: SessionOrigin(
                pid: process.pid,
                tty: found.tty,
                terminal: found.terminal,
                folder: folder,
                agentSessionID: agentFiles.agentSessionID,
                transcriptPath: agentFiles.transcriptPath,
                sessionName: agentFiles.sessionName,
                isHomeFolder: URL(fileURLWithPath: folder).standardizedFileURL.path
                    == URL(fileURLWithPath: homeDirectory).standardizedFileURL.path,
                tmux: found.terminal == .tmux ? agentFiles.tmux : nil,
                hostTerminal: found.terminal == .tmux ? tmuxHost : nil
            )
        )
        live.events.append(start)
        live.turns += agentFiles.turns
        live.limits += agentFiles.limits
        if agentFiles.state != nil || agentFiles.snapshot != nil {
            live.events.append(statusEvent(
                after: start, state: agentFiles.state ?? .working, snapshot: agentFiles.snapshot, now: now
            ))
        }
    }

    /// What the session is doing now. Its duration counts from the process start, so the
    /// strip's time stays the time the session has been running.
    private func statusEvent(
        after start: SessionEvent, state: SessionState, snapshot: SessionSnapshot?, now: Date
    ) -> SessionEvent {
        SessionEvent(
            timestamp: now,
            agent: start.agent,
            sessionID: start.sessionID,
            kind: state == .working ? .active : .idle,
            state: state,
            activeDuration: max(now.timeIntervalSince(start.timestamp), 0),
            idleDuration: 0,
            work: start.work,
            snapshot: snapshot
        )
    }

    // MARK: - Each agent's files

    private func claudeFiles(
        _ claude: ClaudeSessionFile, sessionID: String, work: Work, now: Date, live: inout LiveSessions
    ) -> AgentFiles {
        let path = transcriptPath(for: claude)
        let transcript = path.flatMap { path in
            live.claudeTranscripts.insert(path)
            return transcripts.transcript(at: path)
        }
        let state = ClaudeSessionState.make(
            fileStatus: claude.status,
            statusChangedAt: claude.statusChangedAt,
            lastSpeaker: transcript?.lastSpeaker,
            lastActivity: transcript?.lastActivity,
            now: now
        )
        return AgentFiles(
            agentSessionID: claude.sessionId,
            transcriptPath: path,
            sessionName: claude.chosenName,
            turns: transcript?.turns(sessionID: sessionID, work: work) ?? [],
            state: state,
            snapshot: SessionSnapshot(
                activity: transcript?.activity.activity,
                stateSince: state == .working ? nil : claude.statusChangedAt ?? transcript?.lastActivity,
                subagents: path.map { subagents(ofTranscript: $0, work: work, live: &live) } ?? []
            ),
            tmux: claude.tmux.flatMap(TmuxLocation.parse)
        )
    }

    private func codexFiles(
        _ process: ProcessRow, folder: String, sessionID: String, work: Work, now: Date, live: inout LiveSessions
    ) -> AgentFiles {
        guard
            let path = codex.rollout(startedAt: process.startedAt, folder: folder, excluding: live.rollouts, now: now),
            let rollout = rollouts.content(at: path)
        else { return AgentFiles() }
        live.rollouts.insert(path)
        return AgentFiles(
            agentSessionID: rollout.sessionID,
            transcriptPath: path,
            turns: rollout.turns(sessionID: sessionID, work: work),
            limits: rollout.limits,
            state: rollout.state(now: now),
            snapshot: SessionSnapshot(
                effort: rollout.effort, activity: rollout.activity.activity, stateSince: rollout.lastTaskEnd
            )
        )
    }

    private func cursorFiles(_ process: ProcessRow, folder: String, now: Date, live: inout LiveSessions) -> AgentFiles {
        guard
            let chat = cursor.chat(startedAt: process.startedAt, folder: folder, excluding: live.cursorChats),
            let read = CursorChat.read(directory: chat)
        else { return AgentFiles() }
        live.cursorChats.insert(chat)
        return AgentFiles(
            transcriptPath: chat + "/store.db",
            state: Self.state(lastWrite: cursor.lastWrite(chat), now: now),
            snapshot: SessionSnapshot(
                model: read.model.map { ModelName($0) }, context: read.context, turnCount: read.promptCount,
                stateSince: cursor.lastWrite(chat)
            )
        )
    }

    private func kiroFiles(
        _ process: ProcessRow, folder: String, sessionID: String, work: Work, now: Date, live: inout LiveSessions
    ) -> AgentFiles {
        guard let found = kiro.session(startedAt: process.startedAt, folder: folder, excluding: live.kiroSessions)
        else { return AgentFiles() }
        live.kiroSessions.insert(found.path)
        let session = found.session
        return AgentFiles(
            agentSessionID: session.sessionID,
            transcriptPath: found.path,
            turns: session.turns(sessionID: sessionID, work: work),
            state: Self.state(lastWrite: found.modified, now: now),
            snapshot: SessionSnapshot(
                model: session.model.map { ModelName($0) }, context: session.context,
                turnCount: session.requests.count, stateSince: found.modified
            )
        )
    }

    /// Working while the agent's files keep changing; waiting once they have been quiet.
    static func state(lastWrite: Date?, now: Date) -> SessionState {
        guard let lastWrite else { return .working }
        if now.timeIntervalSince(lastWrite) < quietAfter { return .working }
        return ClaudeSessionState.waitingOrIdle(since: lastWrite, now: now)
    }

    // MARK: - Claude Code files

    /// The session's sub-agents: `<session id>/subagents/agent-*.jsonl` beside its transcript,
    /// each read once and then only as it grows. Their replies are counted once each, by id.
    private func subagents(ofTranscript path: String, work: Work, live: inout LiveSessions) -> [SubagentRun] {
        let directory = String(path.dropLast(".jsonl".count)) + "/subagents"
        return files.list(directory)
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .sorted()
            .compactMap { name in
                let file = directory + "/" + name
                live.subagentTranscripts.insert(file)
                guard let transcript = subagentTranscripts.transcript(at: file) else { return nil }
                let id = String(name.dropLast(".jsonl".count))
                return SubagentRun.make(id: id, turns: transcript.turns(sessionID: id, work: work))
            }
    }

    private func readClaudeSessionFiles() -> [ClaudeSessionFile] {
        let directory = claudeDirectory + "/sessions"
        return files.list(directory)
            .filter { $0.hasSuffix(".json") }
            .compactMap { files.data(directory + "/" + $0).flatMap(ClaudeSessionIndex.parse) }
    }

    private func transcriptPath(for session: ClaudeSessionFile) -> String? {
        let projects = claudeDirectory + "/projects"
        return ClaudeSessionIndex.transcriptPath(
            for: session,
            projectsDirectory: projects,
            projectFolders: { files.list(projects) },
            fileExists: files.exists
        )
    }
}

/// The files each open session uses, tagged by kind so each store keeps its own.
struct ClaimedFiles: Hashable, Sendable {
    var claudeTranscripts: Set<String> = []
    var subagentTranscripts: Set<String> = []
    var rollouts: Set<String> = []
    var cursorChats: Set<String> = []
    var kiroSessions: Set<String> = []

    func subtracting(_ other: ClaimedFiles) -> ClaimedFiles {
        ClaimedFiles(
            claudeTranscripts: claudeTranscripts.subtracting(other.claudeTranscripts),
            subagentTranscripts: subagentTranscripts.subtracting(other.subagentTranscripts),
            rollouts: rollouts.subtracting(other.rollouts),
            cursorChats: cursorChats.subtracting(other.cursorChats),
            kiroSessions: kiroSessions.subtracting(other.kiroSessions)
        )
    }
}

extension ProcessSessionRepository.LiveSessions {
    var claimed: ClaimedFiles {
        ClaimedFiles(
            claudeTranscripts: claudeTranscripts, subagentTranscripts: subagentTranscripts, rollouts: rollouts,
            cursorChats: cursorChats, kiroSessions: kiroSessions
        )
    }

    mutating func claim(_ files: ClaimedFiles) {
        claudeTranscripts.formUnion(files.claudeTranscripts)
        subagentTranscripts.formUnion(files.subagentTranscripts)
        rollouts.formUnion(files.rollouts)
        cursorChats.formUnion(files.cursorChats)
        kiroSessions.formUnion(files.kiroSessions)
    }
}

/// What each open session's files said when last read, so a refresh a few seconds later
/// reuses it instead of finding and reading the files again. A session is keyed by its
/// process and start time, so a new process with a reused pid is read afresh.
final class LiveCache: Sendable {
    fileprivate struct Entry: Sendable {
        let readAt: Date
        let folder: String
        let work: Work
        let files: ProcessSessionRepository.AgentFiles
        let claimed: ClaimedFiles
    }

    private let entries = Mutex<[String: Entry]>([:])

    private static func key(_ found: TerminalAgentProcess) -> String {
        "\(found.agent.rawValue)-\(found.process.pid)-\(found.process.startedAt.timeIntervalSince1970)"
    }

    /// The session's last read, if it is younger than `maxAge`.
    fileprivate func entry(for found: TerminalAgentProcess, now: Date, maxAge: TimeInterval) -> Entry? {
        entries.withLock { $0[Self.key(found)] }.flatMap { now.timeIntervalSince($0.readAt) < maxAge ? $0 : nil }
    }

    fileprivate func store(_ entry: Entry, for found: TerminalAgentProcess) {
        entries.withLock { $0[Self.key(found)] = entry }
    }

    /// Forgets sessions that are no longer open.
    func keepOnly(_ found: [TerminalAgentProcess]) {
        let open = Set(found.map(Self.key))
        entries.withLock { $0 = $0.filter { open.contains($0.key) } }
    }
}
