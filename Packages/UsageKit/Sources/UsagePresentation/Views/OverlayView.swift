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

    public var body: some View {
        GeometryReader { geometry in
            content(availableHeight: geometry.size.height - 2 * Self.screenMargin)
                .padding(.vertical, Self.screenMargin)
        }
    }

    private func content(availableHeight: CGFloat) -> some View {
        let strip = StripLayout.place(
            contentHeight: stripHeight, restHeight: restStripHeight, available: availableHeight,
            offset: viewModel.stripOffset
        )
        let panel = StripLayout.place(panel: panelHeight, available: availableHeight, beside: strip.offset)
        // One container, so the strip and the panel are glass of one kind and blend at their edges.
        return GlassEffectContainer(spacing: GlassStyle.spacing) {
            HStack(alignment: .center, spacing: 8) {
                Spacer(minLength: 0)
                // A panel taller than the screen scrolls instead of running off it.
                ViewThatFits(in: .vertical) {
                    openPanel
                    ScrollView(.vertical) { openPanel }.scrollIndicators(.never)
                }
                .frame(maxHeight: availableHeight)
                .measureHeight { panelHeight = $0 }
                .offset(y: panel.offset)
                if let model = viewModel.strip {
                    StripView(
                        model: model,
                        availableHeight: availableHeight,
                        offset: strip.offset,
                        dragOrigin: viewModel.stripOffset,
                        isDragging: viewModel.isDraggingStrip,
                        restHeight: restStripHeight,
                        onPointer: { inside in
                            if !locksExpandedStrip { viewModel.pointerOverStrip(inside) }
                        },
                        onHover: { id, inside in
                            inside ? viewModel.hover(id) : viewModel.endHover(id)
                        },
                        onClick: { viewModel.click($0) },
                        onUsage: { viewModel.openUsage() },
                        onDragBegin: { viewModel.beginStripDrag() },
                        onDrag: { offset, limit in viewModel.dragStrip(to: offset, limit: limit) },
                        onDragEnd: { viewModel.endStripDrag() }
                    )
                    .measureHeight { height in
                        stripHeight = height
                        if !model.isExpanded { restStripHeight = height }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .contextMenu {
                Button("Quit", action: onQuit)
            }
        }
    }

    @ViewBuilder private var openPanel: some View {
        if let usage = viewModel.overview {
            UsagePanelView(
                model: usage,
                onSelectAgent: { viewModel.usageFilter = $0 },
                onSelectPeriod: { viewModel.usagePeriod = $0 },
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
