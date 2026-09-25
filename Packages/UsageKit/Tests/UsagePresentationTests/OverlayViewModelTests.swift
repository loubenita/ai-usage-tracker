import Foundation
import Testing
import UsageData
import UsageDomain
@testable import UsagePresentation

private struct FixedTime: TimeSource {
    let now: Date
}

@MainActor
@Suite("Overlay behaviour")
struct OverlayViewModelTests {
    func makeViewModel() async -> OverlayViewModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let repository = FakeUsageRepository(calendar: calendar)
        let viewModel = OverlayViewModel(
            repository: repository, timeSource: FixedTime(now: repository.anchor), calendar: calendar
        )
        await viewModel.load()
        return viewModel
    }

    @Test func hoverStopsThePulse() async {
        let viewModel = await makeViewModel()
        #expect(viewModel.strip?.items[1].pulses == true)
        viewModel.hover("s_img")
        viewModel.endHover("s_img")
        #expect(viewModel.strip?.items[1].pulses == false)
    }

    @Test func theStripRestsAsAHalfStripAndGrowsUnderThePointer() async {
        let viewModel = await makeViewModel()
        #expect(viewModel.strip?.isExpanded == false)
        viewModel.pointerOverStrip(true)
        #expect(viewModel.strip?.isExpanded == true)
        viewModel.pointerOverStrip(false)
        #expect(viewModel.strip?.isExpanded == false)
    }

    @Test func theStripStaysFullWhileAPanelIsOpen() async {
        let viewModel = await makeViewModel()
        viewModel.click("s_img")
        #expect(viewModel.strip?.isExpanded == true)
        viewModel.close()
        #expect(viewModel.strip?.isExpanded == false)
    }

    @Test func theUsageButtonOpensTheOverviewWithNoSessionSelected() async {
        let viewModel = await makeViewModel()
        viewModel.click("s_img")
        viewModel.openUsage()
        // The usage panel is every agent's, so no session panel opens and no ring is selected.
        #expect(viewModel.panel == nil)
        #expect(viewModel.overview?.period == .today)
        #expect(viewModel.overview?.selected == .all)
        #expect(viewModel.strip?.items.allSatisfy { $0.highlight == .none } == true)
        #expect(viewModel.strip?.isExpanded == true)
        viewModel.usagePeriod = .month
        viewModel.usageFilter = .agent(.codex)
        #expect(viewModel.overview?.period == .month)
        #expect(viewModel.overview?.selected == .agent(.codex))
        // Clicking a session swaps the usage panel for that session's panel.
        viewModel.click("s_bug")
        #expect(viewModel.overview == nil)
        #expect(viewModel.panel?.title == "Bug fixes")
        // Opening it again starts over on All and Today.
        viewModel.openUsage()
        #expect(viewModel.overview?.period == .today)
        #expect(viewModel.overview?.selected == .all)
        viewModel.openUsage()
        #expect(viewModel.overview == nil)
        #expect(!viewModel.isOpen)
    }

    @Test func sessionsThatStartAndEndAppearAndDisappearOnReload() async {
        let repository = ChangingRepository()
        let viewModel = OverlayViewModel(
            repository: repository, timeSource: FixedTime(now: ChangingRepository.now), calendar: .current
        )
        await repository.set(["a", "b"])
        await viewModel.load()
        #expect(viewModel.strip?.items.map(\.id) == ["a", "b"])
        viewModel.click("b")
        await repository.set(["a", "c"])
        await viewModel.load()
        #expect(viewModel.strip?.items.map(\.id) == ["a", "c"])
        #expect(viewModel.panel == nil)
    }

    @Test func holdingTheStripPicksItUpAndDroppingItKeepsItThere() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let repository = FakeUsageRepository(calendar: calendar)
        let saved = Saved()
        let viewModel = OverlayViewModel(
            repository: repository, timeSource: FixedTime(now: repository.anchor), calendar: calendar,
            stripOffset: -40, saveStripOffset: { saved.value = $0 }
        )
        await viewModel.load()
        // It starts where it was left, and moves only once it has been picked up.
        #expect(viewModel.stripOffset == -40)
        viewModel.dragStrip(to: 100, limit: 300)
        #expect(viewModel.stripOffset == -40)

        viewModel.pointerOverStrip(true)
        viewModel.beginStripDrag()
        // It keeps its size while it is dragged, so the handle stays under the pointer.
        #expect(viewModel.strip?.isExpanded == true)
        viewModel.dragStrip(to: 100, limit: 300)
        #expect(viewModel.stripOffset == 100)
        // It cannot be dragged off the screen.
        viewModel.dragStrip(to: 900, limit: 300)
        #expect(viewModel.stripOffset == 300)
        viewModel.endStripDrag()
        #expect(viewModel.isDraggingStrip == false)
        #expect(saved.value == 300)
        #expect(viewModel.strip?.isExpanded == true)
        // Dropped with the pointer away from it, it goes back to the peek.
        viewModel.pointerOverStrip(false)
        #expect(viewModel.strip?.isExpanded == false)
    }

    @Test func movingBetweenItemsKeepsTheNewHover() async {
        let viewModel = await makeViewModel()
        viewModel.hover("s_vid")
        viewModel.hover("s_img")
        viewModel.endHover("s_vid")
        #expect(viewModel.hoveredSessionID == "s_img")
    }

    @Test func clickOpensTheSessionAndClickingAgainCloses() async {
        let viewModel = await makeViewModel()
        viewModel.click("s_img")
        #expect(viewModel.panel?.title == "Image generation")
        viewModel.click("s_img")
        #expect(viewModel.panel == nil)
    }

    @Test func openHandsTheSessionsTerminalToTheOpener() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let repository = FakeUsageRepository(calendar: calendar)
        let opener = RecordingOpener()
        let viewModel = OverlayViewModel(
            repository: repository, timeSource: FixedTime(now: repository.anchor), calendar: calendar, opener: opener
        )
        await viewModel.load()
        viewModel.click("s_img")
        #expect(viewModel.panel?.openAction == .terminal("Warp"))
        viewModel.openTerminal("s_img")
        #expect(opener.opened.map(\.terminal) == [.warp])
        // A session with no known terminal has nothing to open.
        viewModel.openTerminal("s_vid")
        #expect(opener.opened.count == 1)
    }

    @Test func clickingAnotherItemSwitchesSession() async {
        let viewModel = await makeViewModel()
        viewModel.click("s_img")
        viewModel.click("s_bug")
        #expect(viewModel.panel?.title == "Bug fixes")
        viewModel.close()
        #expect(!viewModel.isOpen)
    }

    @Test func hoverAndSelectionHighlightTogether() async {
        let viewModel = await makeViewModel()
        viewModel.click("s_img")
        viewModel.hover("s_vid")
        #expect(viewModel.strip?.items.map(\.highlight) == [.hovered, .selected, .none])
    }
}

/// Where the strip was dropped, instead of the app's settings.
@MainActor private final class Saved {
    var value: CGFloat?
}

/// Keeps what Open was asked to bring forward, instead of bringing anything forward.
private final class RecordingOpener: SessionOpening, @unchecked Sendable {
    private(set) var opened: [SessionOrigin] = []
    func open(_ origin: SessionOrigin) { opened.append(origin) }
}

/// The made-up data, counting which kind of read the view model asks for.
private actor CountingRepository: UsageRepository {
    let fake: FakeUsageRepository
    let historyComplete: Bool
    private(set) var fullReads = 0
    private(set) var sessionReads = 0

    init(fake: FakeUsageRepository, historyComplete: Bool = true) {
        self.fake = fake
        self.historyComplete = historyComplete
    }

    func records(from start: Date, to end: Date) async throws -> UsageRecords {
        fullReads += 1
        let all = try await fake.records(from: start, to: end)
        return UsageRecords(
            turns: all.turns, limits: all.limits, sessionEvents: all.sessionEvents, capturedAt: all.capturedAt,
            usualRates: all.usualRates, isHistoryComplete: historyComplete
        )
    }

    func sessionRecords(from start: Date, to end: Date) async throws -> UsageRecords {
        sessionReads += 1
        return try await fake.records(from: start, to: end)
    }

    func settings() async throws -> UsageSettings { try await fake.settings() }
}

@MainActor
@Suite("Refreshing each part as often as it changes")
struct RefreshScheduleTests {
    @Test func liveSessionDiscoveryUsesTheSixSecondDefault() {
        #expect(OverlayViewModel.defaultReloadInterval == 6)
    }

    fileprivate func make(historyComplete: Bool = true) -> (OverlayViewModel, CountingRepository, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let fake = FakeUsageRepository(calendar: calendar)
        let repository = CountingRepository(fake: fake, historyComplete: historyComplete)
        let viewModel = OverlayViewModel(repository: repository, timeSource: FixedTime(now: fake.anchor), calendar: calendar)
        return (viewModel, repository, fake.anchor)
    }

    @Test func theTimersAndTheSessionListNeverRebuildTheTotals() async {
        let (viewModel, repository, _) = make()
        await viewModel.load()
        #expect(viewModel.totalsBuilds == 1)
        #expect(await repository.fullReads == 1)
        let month = viewModel.report?.month
        // The one-second tick and the six-second read of the open sessions leave the totals be.
        viewModel.refresh()
        viewModel.refresh()
        await viewModel.loadSessions()
        await viewModel.loadSessions()
        #expect(viewModel.totalsBuilds == 1)
        #expect(await repository.fullReads == 1)
        #expect(await repository.sessionReads == 3)
        #expect(viewModel.report?.month == month)
        #expect(viewModel.strip?.items.count == 3)
    }

    @Test func theRefreshButtonRebuildsNowAndRestartsTheCountdown() async {
        let (viewModel, repository, now) = make()
        await viewModel.load()
        // Ten minutes after the build.
        #expect(viewModel.nextTotalsAt == now + 600)
        viewModel.openUsage()
        #expect(viewModel.overview?.refreshLabel == "Refreshes in 10:00")
        viewModel.refreshTotalsNow()
        // A second press while it runs does not start another.
        viewModel.refreshTotalsNow()
        await viewModel.waitForTotals()
        #expect(viewModel.totalsBuilds == 2)
        #expect(await repository.fullReads == 2)
        #expect(viewModel.nextTotalsAt == now + 600)
        #expect(viewModel.isRefreshingTotals == false)
    }

    @Test func aHistoryStillBeingReadIsLookedAtAgainSoon() async {
        let (viewModel, _, now) = make(historyComplete: false)
        await viewModel.load()
        #expect(viewModel.nextTotalsAt == now + 10)
    }

    @Test func theCountdownReadsInMinutesAndSeconds() {
        let presenter = UsagePanelPresenter(formatter: UsageFormatter(calendar: .current))
        #expect(presenter.refreshLabel(.next(in: 192)) == "Refreshes in 3:12")
        #expect(presenter.refreshLabel(.next(in: 0.4)) == "Refreshes in 0:01")
        #expect(presenter.refreshLabel(.next(in: -3)) == "Refreshes in 0:00")
        #expect(presenter.refreshLabel(.refreshing) == "Refreshing…")
    }
}

/// A repository whose running sessions can be changed between loads, as processes come and go.
private actor ChangingRepository: UsageRepository {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var ids: [String] = []

    func set(_ ids: [String]) { self.ids = ids }

    func records(from start: Date, to end: Date) async throws -> UsageRecords {
        let tag = WorkTag(project: "p", concern: "c")
        let events = ids.map {
            SessionEvent(
                timestamp: Self.now - 60, agent: .claudeCode, sessionID: $0, kind: .start, state: .working,
                activeDuration: 0, idleDuration: 0, work: tag
            )
        }
        return UsageRecords(turns: [], limits: [], sessionEvents: events, capturedAt: Self.now)
    }

    func settings() async throws -> UsageSettings {
        UsageSettings(dailyCostBudget: 9, dailyTokenBudget: 1, workdayEndHour: 20)
    }
}
