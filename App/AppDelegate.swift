import AppKit
import UsageData
import UsageDomain
import UsagePresentation

/// The composition root: the only place that picks the real or the fake repository.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: OverlayController?
    /// Where the person dropped the strip, kept between launches.
    static let stripOffsetKey = "stripOffset"

    func applicationDidFinishLaunching(_ notification: Notification) {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_GB")

        let launch = LaunchState(arguments: CommandLine.arguments)
        // For screenshots of the glass in both appearances, without changing the Mac's setting.
        if let appearance = launch.appearance { NSApp.appearance = NSAppearance(named: appearance) }
        let viewModel: OverlayViewModel
        switch launch.data {
        case .real:
            // The open sessions and their files every 6 seconds, and the totals every 10 minutes.
            // The history is saved between launches, so the totals are whole straight away.
            viewModel = OverlayViewModel(
                repository: ProcessSessionRepository(historyCachePath: ProcessSessionRepository.historyCachePath()),
                timeSource: SystemTimeSource(),
                calendar: calendar,
                reloadInterval: OverlayViewModel.defaultReloadInterval,
                totalsInterval: 600,
                opener: TerminalOpener(),
                stripOffset: launch.target == .drag
                    ? StripLayout.forcedDragOffset
                    : CGFloat(UserDefaults.standard.double(forKey: Self.stripOffsetKey)),
                saveStripOffset: { UserDefaults.standard.set(Double($0), forKey: Self.stripOffsetKey) }
            )
        case .fake:
            let repository = FakeUsageRepository(calendar: calendar, sessionCount: launch.sessionCount)
            viewModel = OverlayViewModel(
                repository: repository,
                timeSource: FakeTimeSource(start: repository.anchor),
                calendar: calendar,
                stripOffset: launch.target == .drag ? StripLayout.forcedDragOffset : 0
            )
        }
        let controller = OverlayController(viewModel: viewModel, launchState: launch)
        controller.show()
        self.controller = controller
    }
}

/// A state to force at launch, so screenshots need no mouse or keyboard input:
/// `--state rest|hover|drag|open-session|open-session-details|open-today|open-week|open-month`.
/// `drag` shows the
/// full strip picked up, as Paper frame 7 does. Hover grows the strip as
/// the pointer does. `open-session` opens the Image generation session, as the Paper frames do;
/// `open-session-details` also reveals its details disclosure;
/// `--session <id>` picks another. `open-today`, `open-week` and `open-month` open the usage
/// panel on that period, with no session selected (`open-overview` is `open-today`), showing
/// every agent, or with `--agent claude-code|codex|cursor|…` that agent only.
///
/// `--open <session id>` does what the panel's Open button does for that session, once the
/// sessions have been read, and writes what happened to the open log. `--open-tmux
/// <session>:<window>.<pane>` does the same for a tmux pane given directly, so the route can
/// be tried against a scratch tmux session instead of one somebody is working in.
///
/// `--appearance light|dark` draws the overlay in that appearance, whatever the Mac is set to.
///
/// `--sessions <n>` shows n fake sessions instead of the design's three.
///
/// `--data real|fake` picks the repository. Real, the sessions running in terminals, is the
/// default; a `--state` launch defaults to fake, so screenshots match the Paper frames.
struct LaunchState {
    enum Target: Equatable {
        case hover
        case open(String)
        case usage(UsagePeriod, AgentFilter)
        case drag
    }

    enum DataSource: String {
        case real, fake
    }

    static let defaultSession = "s_img"

    let target: Target?
    let data: DataSource
    let showsSessionDetails: Bool

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let state = value(after: "--state")
        let session = value(after: "--session") ?? Self.defaultSession
        let filter: AgentFilter = value(after: "--agent").flatMap(Agent.init(rawValue:)).map { .agent($0) } ?? .all
        target = switch state {
        case "hover": .hover
        case "drag": .drag
        case "open-session", "open-session-details": .open(session)
        case "open-today", "open-overview": .usage(.today, filter)
        case "open-week": .usage(.week, filter)
        case "open-month": .usage(.month, filter)
        default: nil
        }
        showsSessionDetails = state == "open-session-details"
        data = value(after: "--data").flatMap(DataSource.init(rawValue:)) ?? (state == nil ? .real : .fake)
        sessionCount = value(after: "--sessions").flatMap(Int.init)
        openSessionID = value(after: "--open")
        openTmux = value(after: "--open-tmux").flatMap(TmuxLocation.parse)
        appearance = switch value(after: "--appearance") {
        case "light": .aqua
        case "dark": .darkAqua
        default: nil
        }
    }

    /// `--sessions <n>`: the number of fake sessions, to test a short or a long strip.
    let sessionCount: Int?
    /// `--appearance light|dark`: which appearance to draw in; nil follows the Mac's setting.
    let appearance: NSAppearance.Name?
    /// `--open <session id>`: run Open for that session as soon as the sessions are known.
    let openSessionID: String?
    /// `--open-tmux <session>:<window>.<pane>`: run Open for that tmux pane directly.
    let openTmux: TmuxLocation?
}
