import SwiftUI

/// The glass strip on the right edge. It touches the screen edge, so only its left corners
/// are rounded. At rest it is the half strip of Paper frame 1: 30pt wide, each session's ring
/// cut in half by the screen edge. With the pointer over it, or a panel open, it grows into
/// the full strip of frame 2: a compact provider mark, task and context ring for each session,
/// plus the usage button.
///
/// When there are more sessions than the screen has room for, the half strip shows as many
/// as fit and a "+N" item for the rest, and the full strip scrolls.
///
/// It is dragged by the visible handle at its top. Nothing happens until the pointer has moved
/// `StripLayout.dragThreshold`; then the full strip follows the pointer up and down the edge.
/// Keeping its size prevents the handle from moving out from under the pointer mid-drag.
///
/// The handle stays the same distance from the screen edge at both widths, so expansion does
/// not move it away before the press. Its gesture does not compete with row scrolling.
struct StripView: View {
    let model: StripModel
    /// The height the screen gives the strip.
    let availableHeight: CGFloat
    /// How far the strip sits from the middle of the edge, and whether it is being dragged.
    let offset: CGFloat
    let isDragging: Bool
    /// How tall the strip is at rest, so a drag stops where it would leave the screen.
    let restHeight: CGFloat
    let onPointer: (_ inside: Bool) -> Void
    let onHover: (_ sessionID: String, _ inside: Bool) -> Void
    let onClick: (String) -> Void
    let onUsage: () -> Void
    let onDragBegin: () -> Void
    let onDrag: (_ offset: CGFloat, _ limit: CGFloat) -> Void
    let onDragEnd: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the strip sat when the drag began; nil while nothing is being dragged.
    @State private var start: CGFloat?
    var body: some View {
        Group {
            if model.isExpanded {
                FullStrip(model: model, onHover: onHover, onClick: onClick, onUsage: onUsage, handle: handle)
            } else {
                HalfStrip(
                    model: model,
                    capacity: StripLayout.restCapacity(
                        height: availableHeight, showingChip: model.items.count > StripLayout.restLimit
                    ),
                    handle: handle
                )
            }
        }
        .contentShape(.rect)
        .offset(y: offset)
        .onHover(perform: onPointer)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isExpanded)
    }

    /// The bar at the top of the strip, and the only place a move gesture begins.
    private var handle: some View {
        Capsule()
            .fill(Theme.lift(0.40))
            .frame(width: StripLayout.handleMarkWidth, height: 5)
            .frame(width: StripLayout.handleHitWidth, height: StripLayout.handleBand)
            .contentShape(.rect)
            .gesture(drag)
            .help("Drag the session list up or down")
            .accessibilityLabel("Drag the strip up or down")
    }

    /// How far the strip may be dragged before its resting self would leave the screen.
    private var dragLimit: CGFloat { max((availableHeight - restHeight) / 2, 0) }

    /// The drag begins once the pointer has moved past the threshold on the handle. Keeping it
    /// off the session list leaves vertical scrolling and row selection untouched.
    private var drag: some Gesture {
        DragGesture(minimumDistance: StripLayout.dragThreshold, coordinateSpace: .local)
            .onChanged { value in
                if start == nil {
                    start = offset
                    onDragBegin()
                }
                guard let start else { return }
                onDrag(StripLayout.dragged(from: start, by: value.translation.height, limit: dragLimit), dragLimit)
            }
            .onEnded { _ in
                guard start != nil else { return }
                start = nil
                onDragEnd()
            }
    }
}

// MARK: - Frame 1: at rest

private struct HalfStrip<Handle: View>: View {
    let model: StripModel
    let capacity: Int
    /// Always visible so the strip's movable affordance is discoverable.
    let handle: Handle?

    var body: some View {
        // The sessions whose work changed most recently, newest first, and "+N" for the rest.
        let recent = model.items.sorted { $0.recency < $1.recency }
        let visible = StripLayout.visible(count: recent.count, capacity: capacity)
        VStack(alignment: .trailing, spacing: 0) {
            VStack(alignment: .trailing, spacing: 12) {
            if let handle { handle.frame(width: 29, alignment: .trailing) }
            ForEach(recent.prefix(visible.shown)) { item in
                VStack(alignment: .trailing, spacing: 3) {
                    HalfRing(model: item.ring)
                        .overlay(alignment: .topLeading) {
                            if item.needsUser {
                                NeedsYouDot(pulses: item.pulses, diameter: 8)
                                    .offset(x: 3, y: 1)
                            }
                        }
                    // "22h45" in the 30pt column: big enough to read, small enough to fit.
                    Text(item.time)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.timer)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .staticDigits()
                        .frame(width: 29)
                }
                .frame(width: 29)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibilityLabel)
            }

            }
            .padding(.top, 12)
            .padding(.bottom, visible.hidden > 0 ? StripLayout.restChipGap : 12)

            if visible.hidden > 0 {
                // A band filling the foot of the strip, its bottom corner the strip's own.
                Text("+\(visible.hidden)")
                    .font(TypeScale.font(TypeScale.caption, .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: StripLayout.restChipHeight)
                    .background(
                        UnevenRoundedRectangle(bottomLeadingRadius: 15).fill(Theme.lift(0.22))
                    )
                    .accessibilityLabel("\(visible.hidden) more sessions")
            }
        }
        .frame(width: 30, alignment: .trailing)
        // Cut by the screen's edge, so only its left corners show.
        .glassEffect(
            GlassStyle.glass(), in: UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 15)
        )
    }
}

/// The left half of a 36pt ring whose centre sits on the screen edge. Context fills it
/// from the top, down the left side.
private struct HalfRing: View {
    let model: RingModel

    var body: some View {
        ZStack {
            arc.stroke(Theme.track, lineWidth: 3)
            arc.trim(from: 0, to: model.fraction)
                .stroke(
                    model.isNearlyFull ? Theme.red : Theme.ringColor(model.agent),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
        }
        .frame(width: 18, height: 36)
    }

    /// From the top of the circle, counter-clockwise, to the bottom.
    private var arc: Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: 18, y: 18), radius: 15.5,
                startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true
            )
        }
    }
}

// MARK: - Frame 2: pointer over the strip

private struct FullStrip<Handle: View>: View {
    let model: StripModel
    let onHover: (_ sessionID: String, _ inside: Bool) -> Void
    let onClick: (String) -> Void
    let onUsage: () -> Void
    /// The bar above the first session, there whenever the strip is open.
    let handle: Handle

    var body: some View {
        // The expanded strip is a readable session list rather than a column of anonymous rings.
        VStack(spacing: 0) {
            // Aligned like the resting handle, so hover expansion leaves it under the pointer.
            handle.frame(width: StripLayout.expandedWidth, alignment: .trailing)
            // All the items when they fit; otherwise the same items in a list that scrolls.
            ViewThatFits(in: .vertical) {
                items
                ScrollView(.vertical) { items }
                    .scrollIndicators(.never)
            }
            UsageButton(action: onUsage)
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .frame(width: StripLayout.expandedWidth)
        // One piece of glass, rounded on the left only: it touches the screen's edge.
        .glassEffect(
            GlassStyle.glass(),
            in: UnevenRoundedRectangle(
                topLeadingRadius: GlassStyle.stripRadius, bottomLeadingRadius: GlassStyle.stripRadius
            )
        )
    }

    private var items: some View {
        VStack(spacing: 2) {
            ForEach(model.items) { item in
                StripItemView(item: item)
                    .onHover { inside in onHover(item.id, inside) }
                    .onTapGesture { onClick(item.id) }
            }
        }
    }
}

private struct StripItemView: View {
    let item: StripItemModel

    var body: some View {
        HStack(spacing: 7) {
            AgentMark(agent: item.ring.agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(TypeScale.font(TypeScale.body, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.time)
                    .font(TypeScale.font(TypeScale.caption, .medium))
                    .foregroundStyle(Theme.timer)
                    .lineLimit(1)
                    .staticDigits()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SessionRing(model: item.ring)
                .overlay(alignment: .topTrailing) {
                    if item.needsUser {
                        NeedsYouDot(pulses: item.pulses)
                            .offset(x: -1, y: 1)
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: StripLayout.expandedWidth - 8, alignment: .leading)
        // The item under the pointer or open is lifted, more when open.
        .background(RoundedRectangle(cornerRadius: 14).fill(highlightFill))
        .frame(width: StripLayout.expandedWidth)
        .contentShape(.rect)
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var highlightFill: Color {
        switch item.highlight {
        case .none: .clear
        case .hovered: Theme.lift(0.16)
        case .selected: Theme.lift(0.28)
        }
    }
}

/// The round button under the strip that opens the usage panel.
private struct UsageButton: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Canvas { context, _ in
                for bar in [(1.5, 8.0, 6.5), (6.5, 4.0, 10.5), (11.5, 1.5, 13.0)] {
                    let rect = CGRect(x: bar.0, y: bar.1, width: 3, height: bar.2)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.primary))
                }
            }
            .frame(width: 16, height: 16)
            Text("Usage")
                .font(TypeScale.font(TypeScale.body, .medium))
                .foregroundStyle(Theme.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.lift(0.16)))
        .padding(.horizontal, 10)
        .clickable("Usage", action: action)
    }
}
