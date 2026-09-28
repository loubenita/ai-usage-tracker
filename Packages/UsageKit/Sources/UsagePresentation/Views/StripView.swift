import SwiftUI

/// A single inset glass rail that widens into the session list. Keeping the glass itself alive
/// while its contents change avoids SwiftUI briefly drawing a resting and expanded strip together.
struct StripView: View {
    let model: StripModel
    let availableHeight: CGFloat
    let offset: CGFloat
    let dragOrigin: CGFloat
    let isDragging: Bool
    let restHeight: CGFloat
    let onPointerMoved: (CGPoint) -> Void
    let onPointerLeft: () -> Void
    let onHover: (_ sessionID: String, _ inside: Bool) -> Void
    let onClick: (String) -> Void
    let onUsage: () -> Void
    /// Where each row, and the Usage button, sits in the overlay, so a panel can line up with it.
    let onAnchor: (_ id: String, _ frame: CGRect) -> Void
    let onDragBegin: () -> Void
    let onDrag: (_ offset: CGFloat, _ limit: CGFloat) -> Void
    let onDragEnd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: CGFloat?

    var body: some View {
        VStack(spacing: model.isExpanded ? 0 : StripLayout.compactHandleToContentSpacing) {
            if !model.isExpanded {
                handle
            }
            VStack(spacing: 0) {
                if model.isExpanded {
                    ExpandedContents(
                        model: model, onHover: onHover, onClick: onClick, onUsage: onUsage, onAnchor: onAnchor
                    )
                } else {
                    RestingContents(model: model, onUsage: onUsage)
                }
            }
        }
        .frame(width: model.isExpanded ? StripLayout.expandedWidth : StripLayout.restingWidth)
        .padding(.vertical, StripLayout.compactVerticalInset)
        .contentShape(.rect)
        .glassEffect(GlassStyle.glass(), in: .rect(cornerRadius: GlassStyle.stripRadius))
        // Keep one hover region while the compact and expanded contents swap. The coordinate
        // gate excludes the handle, but an exit from the actual rail always closes it.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                if model.isExpanded || StripLayout.isCompactHoverTarget(y: point.y) {
                    onPointerMoved(point)
                } else {
                    onPointerLeft()
                }
            case .ended:
                onPointerLeft()
            }
        }
        .offset(y: offset)
        .animation(transitionAnimation, value: model.isExpanded)
        .animation(transitionAnimation, value: offset)
    }

    private var transitionAnimation: Animation? {
        reduceMotion || isDragging ? nil : .smooth(duration: StripLayout.railTransitionDuration, extraBounce: 0)
    }

    /// A visible, generous target remains in both sizes, so its gesture never competes with
    /// scrolling or selecting a row.
    private var handle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(width: StripLayout.handleMarkWidth, height: 16)
            .frame(maxWidth: .infinity)
            .frame(height: StripLayout.handleBand)
            .contentShape(.rect)
            .gesture(drag)
            .help("Drag the session rail up or down")
            .accessibilityLabel("Drag the session rail up or down")
            .accessibilityAddTraits(.isButton)
    }

    private var dragLimit: CGFloat { max((availableHeight - restHeight) / 2, 0) }

    private var drag: some Gesture {
        // Global coordinates stay fixed as the rail moves. Local coordinates move with this
        // view, feeding its offset back into translation and making a vertical drag bounce.
        DragGesture(minimumDistance: StripLayout.dragThreshold, coordinateSpace: .global)
            .onChanged { value in
                if start == nil {
                    start = dragOrigin
                    onDragBegin()
                }
                guard let start else { return }
                onDrag(StripLayout.dragged(logicalOrigin: start, by: value.translation.height, limit: dragLimit), dragLimit)
            }
            .onEnded { _ in
                guard start != nil else { return }
                start = nil
                onDragEnd()
            }
    }
}

private struct RestingContents: View {
    let model: StripModel
    let onUsage: () -> Void

    var body: some View {
        VStack(spacing: StripLayout.compactRingSpacing) {
            ForEach(StripLayout.compactItems(from: model.items)) { item in
                CompactContextIndicator(ring: item.ring, needsUser: item.needsUser, pulses: item.pulses)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.accessibilityLabel)
            }
            if model.items.isEmpty {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: StripLayout.compactRingBand, height: StripLayout.compactRingBand)
                    .contentShape(.rect)
                    .onTapGesture(perform: onUsage)
                    .help("Open usage")
                    .accessibilityLabel("No active sessions. Open usage")
                    .accessibilityAddTraits(.isButton)
            }
            if StripLayout.compactOverflowCount(for: model.items) > 0 {
                Text("+\(StripLayout.compactOverflowCount(for: model.items))")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: StripLayout.compactRingBand, height: StripLayout.compactOverflowBand)
                    .accessibilityLabel("\(StripLayout.compactOverflowCount(for: model.items)) more sessions")
            }
        }
        .frame(height: StripLayout.compactContentHeight(for: model.items.count))
    }
}

/// The resting tab needs a readable provider cue and context state, without the expanded rail's
/// tiny token label. Its arc uses the same threshold colour as a full session ring.
private struct CompactContextIndicator: View {
    let ring: RingModel
    let needsUser: Bool
    let pulses: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: ring.fraction)
                .stroke(
                    ring.isNearlyFull ? Theme.red : Theme.ringColor(ring.agent),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            AgentMark(agent: ring.agent)
                .scaleEffect(0.65)
                .frame(width: 16, height: 16)
        }
        .frame(width: StripLayout.compactRingBand, height: StripLayout.compactRingBand)
        .overlay(alignment: .topTrailing) {
            if needsUser {
                NeedsYouDot(pulses: pulses, diameter: 7).offset(x: 1, y: -1)
            }
        }
    }
}

private struct ExpandedContents: View {
    let model: StripModel
    let onHover: (_ sessionID: String, _ inside: Bool) -> Void
    let onClick: (String) -> Void
    let onUsage: () -> Void
    let onAnchor: (_ id: String, _ frame: CGRect) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("SESSIONS")
                    .font(TypeScale.font(TypeScale.caption, .semibold))
                    .tracking(1)
                    .foregroundStyle(Theme.secondary)
                Text("\(model.items.count)")
                    .font(TypeScale.font(TypeScale.caption, .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 4)
                let waiting = model.items.filter(\.needsUser).count
                if waiting > 0 {
                    Circle().fill(Theme.amber).frame(width: 5, height: 5)
                    Text("\(waiting) waiting")
                        .font(TypeScale.font(TypeScale.caption, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) { items; usageButton }
                VStack(spacing: 0) {
                    ScrollView(.vertical) { items }.scrollIndicators(.automatic)
                    usageButton
                }
            }
        }
    }

    private var usageButton: some View {
        UsageButton(action: onUsage)
            .reportsAnchor(StripAnchor.usage, to: onAnchor)
            .padding(.top, 6)
    }

    private var items: some View {
        VStack(spacing: 0) {
            ForEach(model.items) { item in
                StripItemView(item: item)
                    .onHover { inside in onHover(item.id, inside) }
                    .onTapGesture { onClick(item.id) }
                    .reportsAnchor(item.id, to: onAnchor)
                if item.id != model.items.last?.id {
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(height: 0.5)
                        .padding(.leading, 10)
                }
            }
            if model.items.isEmpty {
                Text("No active sessions")
                    .font(TypeScale.font(TypeScale.caption, .medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 10)
    }
}

private struct StripItemView: View {
    let item: StripItemModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            AgentMark(agent: item.ring.agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(TypeScale.font(TypeScale.body, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(context)
                    .font(TypeScale.font(TypeScale.caption, .medium))
                    .foregroundStyle(Theme.timer)
                    // The project and branch share this two-line budget. A long branch cannot
                    // grow a row by taking a third line below its project.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 3) {
                SessionRing(model: item.ring)
                    .overlay(alignment: .topTrailing) {
                        if item.needsUser { NeedsYouDot(pulses: item.pulses).offset(x: -1, y: 1) }
                    }
                Text(item.time)
                    .font(TypeScale.font(TypeScale.caption, .medium))
                    .foregroundStyle(Theme.timer)
                    .lineLimit(1)
                    .fixedSize()
                    .staticDigits()
            }
            .frame(width: 40)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(item.highlight == .hovered ? Theme.lift(0.07) : .clear)
        .overlay(alignment: .leading) {
            if item.highlight == .selected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.agent(item.ring.agent))
                    .frame(width: 3, height: 36)
            }
        }
        .contentShape(.rect)
        .help(item.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var context: String {
        [item.project, item.branch].compactMap { $0 }.joined(separator: "\n")
    }

}

private struct UsageButton: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.fill").font(.system(size: 14, weight: .semibold))
            Text("Usage").font(TypeScale.font(TypeScale.body, .medium))
        }
        .foregroundStyle(Theme.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.lift(0.16)))
        .padding(.horizontal, 10)
        .clickable("Usage", action: action)
    }
}

/// What an open panel lines up with: a session row by its id, or the Usage button.
enum StripAnchor {
    /// The overlay's coordinate space, which spans the height the strip and panel may use.
    static let space = "overlay"
    static let usage = "usage"
}

extension View {
    /// Reports this view's frame in the overlay's coordinate space whenever it changes.
    func reportsAnchor(_ id: String, to report: @escaping (_ id: String, _ frame: CGRect) -> Void) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(StripAnchor.space)) } action: { report(id, $0) }
    }
}
