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
    /// Room for the strip, the gap, the 320pt panel and the soft glass shadow.
    private static let width: CGFloat = 68 + 8 + 320 + 32

    private let viewModel: OverlayViewModel
    private let launchState: LaunchState
    private let panel: OverlayPanel
    private var outsideClickMonitor: Any?
    private lazy var escape = EscapeHotKey { [weak self] in self?.viewModel.close() }

    init(viewModel: OverlayViewModel, launchState: LaunchState) {
        self.viewModel = viewModel
        self.launchState = launchState
        self.panel = OverlayPanel(contentRect: .zero)

        // The overlay's window never becomes key, so the first click in it would otherwise be
        // spent activating rather than pressing what is under the pointer.
        let host = FirstMouseHostingView(rootView: OverlayView(viewModel: viewModel) { NSApp.terminate(nil) })
        host.sizingOptions = []
        panel.contentView = host
    }

    func show() {
        position()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.position() }
        }
        watchOpenState()
        // Before the first load, so a screenshot of a state does not wait for a month of
        // history to be read. The panel draws as soon as the first report arrives.
        applyLaunchState()
        Task {
            await viewModel.start()
            runOpenIfAsked()
        }
    }

    /// Against the screen's right edge, over the full height below the menu bar,
    /// so the strip touches the edge and centres vertically.
    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: screen.frame.maxX - Self.width, y: visible.minY, width: Self.width, height: visible.height),
            display: true
        )
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
            viewModel.dragStrip(to: -120, limit: 300)
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
