import AppKit
import SwiftUI
import UsageDomain
import UsagePresentation

/// A hosting view that takes the first click, so a control in a window that is never key
/// still responds the moment it is pressed.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Puts the overlay on screen and wires the behaviour SwiftUI cannot do alone:
/// closing on a click outside, closing on Esc, and following screen changes.
@MainActor
final class OverlayController {
    private let viewModel: OverlayViewModel
    private let launchState: LaunchState
    private let panel: OverlayPanel
    private var outsideClickMonitor: Any?
    /// A pending narrowing of the window, waiting for the glass to finish shrinking.
    private var shrinkTask: Task<Void, Never>?
    private lazy var escape = EscapeHotKey { [weak self] in self?.viewModel.close() }

    init(viewModel: OverlayViewModel, launchState: LaunchState) {
        self.viewModel = viewModel
        self.launchState = launchState
        self.panel = OverlayPanel(contentRect: .zero)
        // The rail's continuous hover needs movement events even though this panel never
        // becomes key. The old AppKit tracking view enabled this as a side effect.
        panel.acceptsMouseMovedEvents = true

        // The overlay's window never becomes key, so the first click in it would otherwise be
        // spent activating rather than pressing what is under the pointer.
        let host = FirstMouseHostingView(rootView: OverlayView(
            viewModel: viewModel,
            initiallyShowsSessionDetails: launchState.showsSessionDetails,
            locksExpandedStrip: launchState.target == .hover
        ) { NSApp.terminate(nil) })
        host.sizingOptions = []
        panel.contentView = host
        // Widening the window moves the rail within it. Done before the rail grows, the rail is
        // laid out at its new place first, so the growth starts from where it is on screen.
        viewModel.willExpandStrip = { [weak self] in
            guard let self, panel.frame.width < StripLayout.expandedOverlayWidth else { return }
            position(width: StripLayout.expandedOverlayWidth)
            // SwiftUI would otherwise lay out the wider window on its next pass, together with
            // the growth, and animate the rail from its old place in the narrow window.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
        }
        // The pointer in the hosting view's top-left coordinates, SwiftUI's global space here.
        viewModel.pointerLocation = { [weak panel, weak host] in
            guard let panel, let host else { return nil }
            let point = host.convert(panel.mouseLocationOutsideOfEventStream, from: nil)
            return host.isFlipped ? point : CGPoint(x: point.x, y: host.bounds.height - point.y)
        }
    }

    func show() {
        position()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.position(animated: false) }
        }
        watchOpenState()
        watchOverlayBounds()
        // Before the first load, so a screenshot of a state does not wait for a month of
        // history to be read. The panel draws as soon as the first report arrives.
        applyLaunchState()
        Task {
            await viewModel.start()
            runOpenIfAsked()
        }
    }

    /// Against the screen's right edge, with only enough window width for the active glass.
    /// Keeping the transparent window narrow leaves the rest of the desktop available to the
    /// application behind it.
    private func position(width wanted: CGFloat? = nil, animated: Bool = false) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width = wanted ?? overlayWidth
        let frame = NSRect(x: screen.frame.maxX - width, y: visible.minY, width: width, height: visible.height)
        shrinkTask?.cancel()
        shrinkTask = nil
        // The window is transparent; only the glass inside it animates. Animating the window's
        // own frame clipped the glass to its moving left edge, so a panel seemed to slide in.
        // It widens at once, before the glass grows, and narrows once the glass has shrunk.
        guard animated, frame.width < panel.frame.width else {
            panel.setFrame(frame, display: true)
            return
        }
        shrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(StripLayout.railTransitionDuration))
            guard !Task.isCancelled else { return }
            self?.panel.setFrame(frame, display: true)
        }
    }

    private var overlayWidth: CGFloat {
        if viewModel.isOpen { return StripLayout.overlayWidth }
        return viewModel.isStripExpanded ? StripLayout.expandedOverlayWidth : StripLayout.restingOverlayWidth
    }

    /// Resizes the transparent window with the rail. The glass remains on the screen edge while
    /// the exposed desktop space is never part of this panel's window bounds.
    private func watchOverlayBounds() {
        withObservationTracking {
            _ = viewModel.isStripExpanded
            _ = viewModel.isOpen
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.position(animated: true)
                self?.watchOverlayBounds()
            }
        }
    }

    /// While the panel is open, Esc and a click anywhere outside the overlay close it.
    private func watchOpenState() {
        withObservationTracking {
            _ = viewModel.isOpen
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateCloseTriggers()
                self?.watchOpenState()
            }
        }
    }

    private func updateCloseTriggers() {
        let isOpen = viewModel.isOpen
        escape.isEnabled = isOpen
        // A `--state` launch is for screenshots: a click elsewhere on a Mac in use must not
        // close the panel before it is captured.
        if isOpen, outsideClickMonitor == nil, launchState.target == nil {
            // A global monitor only sees clicks that went to other apps, including clicks
            // that fell through the overlay's transparent parts.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewModel.close() }
            }
        } else if !isOpen, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// `--open` and `--open-tmux`: does what the Open button does, without a click, so the
    /// route can be checked end to end and read back in the open log.
    private func runOpenIfAsked() {
        if let id = launchState.openSessionID {
            viewModel.openTerminal(id)
        }
        if let tmux = launchState.openTmux {
            TerminalOpener().open(SessionOrigin(
                pid: 0, tty: "", terminal: .tmux, folder: NSHomeDirectory(), tmux: tmux,
                // The probe checks the tmux route only, so it brings no app to the front and
                // nothing the person is looking at moves.
                hostTerminal: nil
            ))
        }
    }

    private func applyLaunchState() {
        switch launchState.target {
        case .hover?:
            viewModel.pointerOverStrip(true)
        case .drag?:
            viewModel.beginStripDrag()
            viewModel.dragStrip(to: StripLayout.forcedDragOffset, limit: 300)
        case .open(let id)?:
            viewModel.click(id)
        case .usage(let period, let filter)?:
            viewModel.openUsage()
            viewModel.usagePeriod = period
            viewModel.usageFilter = filter
        case nil:
            break
        }
    }
}
