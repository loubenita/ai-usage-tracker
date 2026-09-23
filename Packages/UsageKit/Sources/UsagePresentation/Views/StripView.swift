import SwiftUI

/// The glass strip on the right edge. It touches the screen edge, so only its left corners
/// are rounded. At rest it is the half strip of Paper frame 1: 30pt wide, each session's ring
/// cut in half by the screen edge. With the pointer over it, or a panel open, it grows into
/// the full strip of frame 2: whole rings with each session's tokens inside, and the usage button.
///
/// When there are more sessions than the screen has room for, the half strip shows as many
/// as fit and a "+N" item for the rest, and the full strip scrolls.
///
/// It is dragged by the handle at its top, or from anywhere after a five-second hold. Either
/// way nothing happens until the pointer has moved `StripLayout.dragThreshold`; then the strip
/// shrinks back to the half strip (Paper frame 7), follows the pointer up and down the edge,
/// and grows back where it is dropped.
///
/// The gesture lives here, on the view that stays put, rather than on the handle: shrinking
/// swaps the handle's view for another, which would end the drag as soon as it began.
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
    /// True once the strip has been held long enough to be dragged from anywhere.
    @State private var isHeld = false

    /// How long the strip is held before it can be dragged.
    static let holdToDrag: Double = 5

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
                    handle: isDragging ? handle : nil
                )
            }
        }
        .frame(maxHeight: availableHeight)
        .contentShape(.rect)
        .offset(y: offset)
        .onHover(perform: onPointer)
        .gesture(drag)
        .simultaneousGesture(hold)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isExpanded)
    }

    /// The bar at the top of the strip. The gesture is on the strip itself; this is what it
    /// looks like, and what a press must start on before the strip has been held.
    private var handle: some View {
        Capsule()
            .fill(Theme.lift(0.40))
            .frame(width: 22, height: 4)
            .frame(height: StripLayout.handleBand)
            .accessibilityLabel("Drag the strip up or down")
    }

    /// How far the strip may be dragged before its resting self would leave the screen.
    private var dragLimit: CGFloat { max((availableHeight - restHeight) / 2, 0) }

    /// Holding anywhere on the strip for five seconds lets it be dragged from there. It does
    /// not move or shrink until the pointer does.
    private var hold: some Gesture {
        LongPressGesture(minimumDuration: Self.holdToDrag, maximumDistance: StripLayout.dragThreshold)
            .onEnded { _ in isHeld = true }
    }

    /// The drag itself: it begins once the pointer has moved past the threshold, from the
    /// handle or from anywhere the strip has been held.
    private var drag: some Gesture {
        DragGesture(minimumDistance: StripLayout.dragThreshold, coordinateSpace: .local)
            .onChanged { value in
                if start == nil {
                    guard StripLayout.canDrag(fromY: value.startLocation.y, isHeld: isHeld) else { return }
                    start = offset
                    onDragBegin()
                }
                guard let start else { return }
                onDrag(StripLayout.dragged(from: start, by: value.translation.height, limit: dragLimit), dragLimit)
            }
            .onEnded { _ in
                isHeld = false
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
    /// Shown only while the strip is being dragged; at rest the strip is just its sessions.
    let handle: Handle?

    var body: some View {
        // The sessions whose work changed most recently, newest first, and "+N" for the rest.
        let recent = model.items.sorted { $0.recency < $1.recency }
        let visible = StripLayout.visible(count: recent.count, capacity: capacity)
        VStack(alignment: .trailing, spacing: 0) {
            VStack(alignment: .trailing, spacing: 12) {
            if let handle { handle.frame(width: 29) }
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
        // Frame 2: 14pt above the first ring, 10pt between items, 12pt above the usage button
        // and 12pt under it. Every item carries 6pt above and below for the selected highlight,
        // so selecting one never moves the items below it; the spacing takes that back out.
        VStack(spacing: 0) {
            handle.frame(width: 68)
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
        .frame(width: 68)
        // One piece of glass, rounded on the left only: it touches the screen's edge.
        .glassEffect(
            GlassStyle.glass(),
            in: UnevenRoundedRectangle(
                topLeadingRadius: GlassStyle.stripRadius, bottomLeadingRadius: GlassStyle.stripRadius
            )
        )
    }

    private var items: some View {
        VStack(spacing: -2) {
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
        VStack(spacing: 5) {
            SessionRing(model: item.ring)
                .overlay(alignment: .topTrailing) {
                    if item.needsUser {
                        NeedsYouDot(pulses: item.pulses)
                            .offset(x: -1, y: 1)
                    }
                }
            Text(item.time)
                .font(TypeScale.font(TypeScale.secondary, .medium))
                .foregroundStyle(Theme.timer)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 4)
                .staticDigits()
        }
        .padding(.vertical, 6)
        .frame(width: 56)
        // The item under the pointer or open is lifted, more when open.
        .background(RoundedRectangle(cornerRadius: 14).fill(highlightFill))
        .frame(width: 68)
        .contentShape(.rect)
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
        Canvas { context, _ in
            for bar in [(1.5, 8.0, 6.5), (6.5, 4.0, 10.5), (11.5, 1.5, 13.0)] {
                let rect = CGRect(x: bar.0, y: bar.1, width: 3, height: bar.2)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.primary))
            }
        }
        .frame(width: 16, height: 16)
        .frame(width: 36, height: 36)
        .background(Circle().fill(Theme.lift(0.16)))
        .clickable("Usage", action: action)
    }
}
