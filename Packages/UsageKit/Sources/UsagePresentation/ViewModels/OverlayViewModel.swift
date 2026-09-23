import Foundation
import Observation
import UsageDomain

/// Holds the overlay's state: the latest report, what is hovered, what is open.
///
/// Each part is refreshed as often as it changes, so the main thread stays free:
/// - every second, only the timers move (the open sessions are re-summed from their own turns);
/// - every `reloadInterval` seconds, the open sessions are read, without the month of history;
/// - every `totalsInterval` seconds (10 minutes), or when the usage panel's refresh button is pressed,
///   Today, Week, Month and the limits are rebuilt from every record, off the main thread. Until
///   the history has finished its first read, that happens every `pendingTotalsInterval` seconds.
@MainActor
@Observable
public final class OverlayViewModel {
    public private(set) var report: UsageReport?
    public private(set) var hoveredSessionID: String?
    public private(set) var openSessionID: String?
    /// Whether the pointer is over the strip, which grows it from the half strip to the full one.
    public private(set) var isPointerOverStrip = false
    /// Whether the usage button's panel is open. It shows every agent, so no session is selected.
    public private(set) var isOverviewOpen = false
    /// The usage panel's period and whose usage it shows.
    public var usagePeriod: UsagePeriod = .today
    public var usageFilter: AgentFilter = .all
    /// Sessions whose "needs you" dot has been seen by hovering, so it stops pulsing.
    public private(set) var acknowledgedSessionIDs: Set<String> = []
    public private(set) var loadError: String?
    /// True while the strip is being dragged up or down the screen's edge (Paper frame 7).
    public private(set) var isDraggingStrip = false
    /// How far the strip sits from the middle of the screen's edge, in points: negative is up.
    public private(set) var stripOffset: CGFloat

    private let repository: any UsageRepository
    private let timeSource: any TimeSource
    private let calendar: Calendar
    private let presenter: OverlayPresenter
    private let usagePresenter: UsagePanelPresenter
    private let opener: (any SessionOpening)?
    @ObservationIgnored private let saveStripOffset: (@MainActor (CGFloat) -> Void)?
    private let reloadInterval: Int
    private let totalsInterval: Int
    static let pendingTotalsInterval = 10
    /// The open sessions, as last read.
    @ObservationIgnored private var sessions: UsageRecords?
    /// Today, This week, Month and the limits, as last built.
    @ObservationIgnored private(set) var totals: UsageTotals?
    @ObservationIgnored private var generate: GenerateUsageReport?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var totalsTask: Task<Void, Never>?
    /// How many times the totals were built: the tests count them.
    @ObservationIgnored private(set) var totalsBuilds = 0
    /// When the totals are next rebuilt on their own; the overview counts down to it.
    public private(set) var nextTotalsAt: Date?
    /// True while a rebuild of the totals is running.
    public private(set) var isRefreshingTotals = false

    /// - Parameters:
    ///   - reloadInterval: seconds between reads of the open sessions.
    ///   - totalsInterval: seconds between rebuilds of Today, This week, Month and the limits.
    public init(
        repository: any UsageRepository,
        timeSource: any TimeSource,
        calendar: Calendar,
        reloadInterval: Int = 2,
        totalsInterval: Int = 600,
        opener: (any SessionOpening)? = nil,
        stripOffset: CGFloat = 0,
        saveStripOffset: (@MainActor (CGFloat) -> Void)? = nil
    ) {
        self.opener = opener
        self.stripOffset = stripOffset
        self.saveStripOffset = saveStripOffset
        self.repository = repository
        self.timeSource = timeSource
        self.calendar = calendar
        self.reloadInterval = max(reloadInterval, 1)
        self.totalsInterval = max(totalsInterval, 1)
        let formatter = UsageFormatter(calendar: calendar)
        self.presenter = OverlayPresenter(formatter: formatter)
        self.usagePresenter = UsagePanelPresenter(formatter: formatter)
    }

    // MARK: - Lifecycle

    /// Loads everything once, then keeps each part as fresh as it changes (see the type).
    public func start() async {
        await load()
        ticker?.cancel()
        ticker = Task { [weak self, reloadInterval] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
                guard let self else { return }
                if tick % reloadInterval == 0 {
                    await self.loadSessions()
                } else {
                    self.refresh()
                }
                if let next = self.nextTotalsAt, self.timeSource.now >= next {
                    self.rebuildTotals()
                }
            }
        }
    }

    /// The refresh button: rebuilds the totals now and restarts the countdown.
    public func refreshTotalsNow() {
        rebuildTotals()
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// The open sessions, then every total, waiting for both.
    func load() async {
        await loadSessions()
        await loadTotals()
    }

    /// Reads the open sessions only: cheap enough to do every couple of seconds.
    func loadSessions() async {
        do {
            let generate = try await makeGenerate()
            let range = generate.recordRange(endingAt: timeSource.now)
            sessions = try await repository.sessionRecords(from: range.start, to: range.end)
            loadError = nil
            refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Reads every record and builds the totals off the main thread, then shows them.
    func loadTotals() async {
        isRefreshingTotals = true
        defer { isRefreshingTotals = false }
        do {
            let generate = try await makeGenerate()
            let now = timeSource.now
            let range = generate.recordRange(endingAt: now)
            let all = try await repository.records(from: range.start, to: range.end)
            let totals = await Task.detached(priority: .userInitiated) { generate.totals(all, now: now) }.value
            self.totals = totals
            totalsBuilds += 1
            // A history still being read is looked at again soon; after that, on the interval.
            let wait = totals.isHistoryComplete ? totalsInterval : Self.pendingTotalsInterval
            nextTotalsAt = timeSource.now.addingTimeInterval(TimeInterval(wait))
            if sessions == nil { sessions = all }
            refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Starts a rebuild of the totals unless one is already running; never waits for it.
    func rebuildTotals() {
        guard totalsTask == nil else { return }
        totalsTask = Task { [weak self] in
            await self?.loadTotals()
            self?.totalsTask = nil
        }
    }

    /// Waits for a rebuild that is running, so tests can check what it left.
    func waitForTotals() async {
        await totalsTask?.value
    }

    private func makeGenerate() async throws -> GenerateUsageReport {
        if let generate { return generate }
        let made = GenerateUsageReport(settings: try await repository.settings(), calendar: calendar)
        generate = made
        return made
    }

    /// The timers' tick: the open sessions re-summed at the current time, with the totals as
    /// last built. Before the first totals, the open sessions' own turns stand in for them.
    func refresh() {
        guard let sessions, let generate else { return }
        let now = timeSource.now
        let report = generate.report(sessions: sessions, totals: totals ?? generate.totals(sessions, now: now), now: now)
        self.report = report
        forgetEndedSessions(in: report)
    }

    /// A session that ended takes its hover and its open panel with it.
    private func forgetEndedSessions(in report: UsageReport) {
        let live = Set(report.sessions.map(\.id))
        if let openSessionID, !live.contains(openSessionID) { self.openSessionID = nil }
        if let hoveredSessionID, !live.contains(hoveredSessionID) { self.hoveredSessionID = nil }
        acknowledgedSessionIDs.formIntersection(live)
    }

    // MARK: - Intents

    /// The pointer entering or leaving the strip grows or shrinks it.
    public func pointerOverStrip(_ inside: Bool) {
        isPointerOverStrip = inside
    }

    /// Hovering an item highlights it and stops its "needs you" dot pulsing.
    public func hover(_ sessionID: String) {
        hoveredSessionID = sessionID
        acknowledgedSessionIDs.insert(sessionID)
    }

    /// Leaving an item clears the hover only if no other item has taken it already,
    /// because moving between items can report the new item before the old one.
    public func endHover(_ sessionID: String) {
        if hoveredSessionID == sessionID { hoveredSessionID = nil }
    }

    /// Clicking an item opens its panel; clicking the open item closes it.
    public func click(_ sessionID: String) {
        if openSessionID == sessionID {
            close()
        } else {
            isOverviewOpen = false
            openSessionID = sessionID
        }
    }

    /// The usage button opens the usage panel on All and Today, with no session selected;
    /// pressing it again closes it.
    public func openUsage() {
        if isOverviewOpen {
            close()
        } else {
            openSessionID = nil
            isOverviewOpen = true
            usagePeriod = .today
            usageFilter = .all
        }
    }

    /// The session panel's Open button: brings the session's terminal to the front. It runs
    /// only on this click, and never types into the terminal.
    public func openTerminal(_ sessionID: String) {
        guard let origin = report?.sessions.first(where: { $0.id == sessionID })?.summary.origin else { return }
        opener?.open(origin)
    }

    /// Pressing and holding the strip picks it up; it then follows the pointer up and down the
    /// screen's edge, and stays where it is dropped.
    public func beginStripDrag() {
        isDraggingStrip = true
    }

    /// - Parameters:
    ///   - offset: where the strip has been dragged to, from the middle of the edge.
    ///   - limit: how far it may go before it would leave the screen.
    public func dragStrip(to offset: CGFloat, limit: CGFloat) {
        guard isDraggingStrip else { return }
        stripOffset = StripLayout.dragged(from: offset, by: 0, limit: limit)
    }

    public func endStripDrag() {
        guard isDraggingStrip else { return }
        isDraggingStrip = false
        saveStripOffset?(stripOffset)
    }

    public func close() {
        openSessionID = nil
        isOverviewOpen = false
    }

    public var isOpen: Bool { openSessionID != nil || isOverviewOpen }

    /// The full strip shows while the pointer is over it or a panel is open, and it keeps that
    /// size while it is dragged: changing size mid-drag moved the handle out from under the
    /// pointer and ended the drag.
    public var isStripExpanded: Bool { isPointerOverStrip || isOpen || isDraggingStrip }

    // MARK: - What to draw

    public var strip: StripModel? {
        report.map {
            presenter.strip(
                $0,
                hovered: hoveredSessionID,
                open: openSessionID,
                acknowledged: acknowledgedSessionIDs,
                expanded: isStripExpanded
            )
        }
    }

    public var panel: SessionPanelModel? {
        guard let report, let openSessionID else { return nil }
        return presenter.panel(report, sessionID: openSessionID)
    }

    public var overview: UsagePanelModel? {
        guard let report, isOverviewOpen else { return nil }
        return usagePresenter.panel(
            report, filter: usageFilter, period: usagePeriod,
            refresh: isRefreshingTotals ? .refreshing : nextTotalsAt.map { .next(in: $0.timeIntervalSince(report.now)) }
        )
    }
}
