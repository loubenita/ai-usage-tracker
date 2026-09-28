import SwiftUI

/// The whole overlay as the Paper frames lay it out: the strip flush against the right edge,
/// and the open panel 8pt to its left.
///
/// The strip sits where the person dropped it. When it grows under the pointer it grows away
/// from the nearer edge, and neither it nor the panel beside it ever leaves the screen: the
/// maths is `StripLayout.place`, and a list too long for the screen scrolls inside the strip.
public struct OverlayView: View {
    @Bindable var viewModel: OverlayViewModel
    /// What the right-click menu's one item does. The app has no Dock icon or menu bar item,
    /// so this menu is the only way to quit it.
    private let onQuit: () -> Void
    /// Screenshot launches may reveal the selected session's disclosure without pointer input.
    private let initiallyShowsSessionDetails: Bool
    /// Keeps the forced hover screenshot expanded when the real pointer is elsewhere.
    private let locksExpandedStrip: Bool
    /// The strip's height as drawn, and its height while it rests, whose edge growth keeps.
    @State private var stripHeight: CGFloat = 0
    @State private var restStripHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    /// Where each session row and the Usage button sit, for lining the open panel up with them.
    @State private var anchors: [String: CGRect] = [:]

    public init(
        viewModel: OverlayViewModel,
        initiallyShowsSessionDetails: Bool = false,
        locksExpandedStrip: Bool = false,
        onQuit: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.initiallyShowsSessionDetails = initiallyShowsSessionDetails
        self.locksExpandedStrip = locksExpandedStrip
        self.onQuit = onQuit
    }

    /// Room kept free above and below the strip, so it never touches the menu bar or the Dock.
    private static let screenMargin: CGFloat = 8
    /// Keeps the drag handle out of macOS's menu-bar reveal area in a full-screen Space.
    private static let verticalSafeMargin: CGFloat = 40

    public var body: some View {
        GeometryReader { geometry in
            content(availableHeight: geometry.size.height - 2 * Self.verticalSafeMargin)
                .padding(.vertical, Self.verticalSafeMargin)
        }
    }

    private func content(availableHeight: CGFloat) -> some View {
        // A drag shows the compact rail. Use its known resting height immediately instead of
        // one render of the expanded measurement, which otherwise changes the placement while
        // the pointer is already moving.
        let displayedStripHeight = viewModel.isDraggingStrip ? restStripHeight : stripHeight
        let strip = StripLayout.place(
            contentHeight: displayedStripHeight, restHeight: restStripHeight, available: availableHeight,
            offset: viewModel.stripOffset
        )
        let panel = panelPlacement(available: availableHeight, besideStrip: strip.offset)
        // One container, so the strip and the panel are glass of one kind and blend at their edges.
        return GlassEffectContainer(spacing: GlassStyle.spacing) {
            HStack(alignment: .center, spacing: 8) {
                Spacer(minLength: 0)
                // A panel taller than the screen scrolls instead of running off it.
                // The panel's own height, not the frame's, which takes the whole screen.
                ViewThatFits(in: .vertical) {
                    openPanel.measureHeight { panelHeight = $0 }
                    ScrollView(.vertical) { openPanel.measureHeight { panelHeight = $0 } }
                        .scrollIndicators(.never)
                }
                .frame(maxHeight: availableHeight)
                .offset(y: panel.offset)
                if let model = viewModel.strip {
                    StripView(
                        model: model,
                        availableHeight: availableHeight,
                        offset: strip.offset,
                        growthAnchor: StripLayout.growthAnchor(
                            restHeight: restStripHeight, available: availableHeight, offset: viewModel.stripOffset
                        ),
                        dragOrigin: StripLayout.dragOrigin(for: strip),
                        isDragging: viewModel.isDraggingStrip,
                        restHeight: restStripHeight,
                        onPointerMoved: { location in
                            if !locksExpandedStrip { viewModel.pointerMovedOverStrip(at: location) }
                        },
                        onPointerLeft: {
                            if !locksExpandedStrip { viewModel.pointerLeftStrip() }
                        },
                        onHover: { id, inside in
                            inside ? viewModel.hover(id) : viewModel.endHover(id)
                        },
                        onClick: { viewModel.click($0) },
                        onUsage: { viewModel.openUsage() },
                        onAnchor: { id, frame in anchors[id] = frame },
                        onDragBegin: { viewModel.beginStripDrag() },
                        onDrag: { offset, limit in viewModel.dragStrip(to: offset, limit: limit) },
                        onDragEnd: { viewModel.endStripDrag() },
                        onFrame: { viewModel.stripFrameChanged($0) }
                    )
                    // The resting rail is a macOS surface with air around it, not a clipped
                    // extension of the screen edge. The expanded list keeps that same inset.
                    .padding(.trailing, Self.screenMargin)
                    .measureHeight { height in
                        stripHeight = height
                        if !model.isExpanded { restStripHeight = height }
                    }
                }
            }
            .contextMenu {
                Button("Quit", action: onQuit)
            }
        }
        // Position the glass at the edge without making the transparent window a full-size hit
        // target. Empty space remains available to whatever is behind the overlay.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .coordinateSpace(.named(StripAnchor.space))
    }

    /// A session panel's top is level with its row and the usage panel's bottom with the Usage
    /// button, both kept on the screen. Before the rows are measured, it sits beside the strip.
    private func panelPlacement(available: CGFloat, besideStrip: CGFloat) -> StripLayout.Placement {
        if let id = viewModel.openSessionID, let row = anchors[id] {
            return StripLayout.place(panel: panelHeight, available: available, top: row.minY)
        }
        if viewModel.overview != nil, let button = anchors[StripAnchor.usage] {
            return StripLayout.place(panel: panelHeight, available: available, bottom: button.maxY)
        }
        return StripLayout.place(panel: panelHeight, available: available, beside: besideStrip)
    }

    @ViewBuilder private var openPanel: some View {
        if let usage = viewModel.overview {
            UsagePanelView(
                model: usage,
                onSelectAgent: { viewModel.usageFilter = $0 },
                onSelectPeriod: { viewModel.usagePeriod = $0 },
                onSelectBucket: { viewModel.selectUsageBucket($0) },
                onRefresh: { viewModel.refreshTotalsNow() }
            )
        } else if let panel = viewModel.panel {
            PanelView(
                model: panel,
                initiallyShowsDetails: initiallyShowsSessionDetails,
                onOpen: { viewModel.openTerminal(panel.sessionID) }
            )
        }
    }
}

private extension View {
    /// Reports this view's height as it is drawn, so the placement maths can use it.
    func measureHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
    }
}
