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
    let onPointer: (_ inside: Bool) -> Void
    let onHover: (_ sessionID: String, _ inside: Bool) -> Void
    let onClick: (String) -> Void
    let onUsage: () -> Void
    let onDragBegin: () -> Void
    let onDrag: (_ offset: CGFloat, _ limit: CGFloat) -> Void
    let onDragEnd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            handle
            Group {
                if model.isExpanded {
                    ExpandedContents(model: model, onHover: onHover, onClick: onClick, onUsage: onUsage)
                } else {
                    RestingContents(
                        model: model,
                        capacity: StripLayout.restCapacity(
                            height: availableHeight,
                            showingChip: model.items.count > StripLayout.restLimit
                        )
                    )
                }
            }
        }
        .frame(width: model.isExpanded ? StripLayout.expandedWidth : StripLayout.restingWidth)
        .padding(.vertical, 8)
        .glassEffect(GlassStyle.glass(), in: .rect(cornerRadius: GlassStyle.stripRadius))
        .contentShape(.rect)
        .offset(y: offset)
        .onHover(perform: onPointer)
        .animation(transitionAnimation, value: model.isExpanded)
        .animation(transitionAnimation, value: offset)
    }

    private var transitionAnimation: Animation? {
        reduceMotion || isDragging ? nil : .smooth(duration: 0.24)
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
        DragGesture(minimumDistance: StripLayout.dragThreshold, coordinateSpace: .local)
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
    let capacity: Int

    var body: some View {
        let ranked = model.items.sorted { $0.priority < $1.priority }
        let visible = StripLayout.visible(count: ranked.count, capacity: capacity)
        VStack(spacing: 10) {
            ForEach(ranked.prefix(visible.shown)) { item in
                VStack(spacing: 2) {
                    SessionRing(model: item.ring)
                        .overlay(alignment: .topTrailing) {
                            if item.needsUser { NeedsYouDot(pulses: item.pulses, diameter: 8).offset(x: 1, y: -1) }
                        }
                    Text(item.time)
                        .font(TypeScale.font(10, .semibold))
                        .foregroundStyle(Theme.timer)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .staticDigits()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.accessibilityLabel)
            }
            if visible.hidden > 0 {
                Text("+\(visible.hidden)")
                    .font(TypeScale.font(TypeScale.caption, .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 36, height: StripLayout.restChipHeight)
                    .background(Capsule().fill(Theme.lift(0.16)))
                    .accessibilityLabel("\(visible.hidden) more sessions")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

private struct ExpandedContents: View {
    let model: StripModel
    let onHover: (_ sessionID: String, _ inside: Bool) -> Void
    let onClick: (String) -> Void
    let onUsage: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) { items; UsageButton(action: onUsage).padding(.top, 6) }
            VStack(spacing: 0) {
                ScrollView(.vertical) { items }.scrollIndicators(.never)
                UsageButton(action: onUsage).padding(.top, 6)
            }
        }
        .padding(.bottom, 4)
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
        HStack(spacing: 8) {
            AgentMark(agent: item.ring.agent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(TypeScale.font(TypeScale.body, .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                Text(item.project)
                    .font(TypeScale.font(TypeScale.caption, .medium))
                    .foregroundStyle(Theme.timer)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let branch = item.branch {
                        Text(branch)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                        Spacer(minLength: 2)
                    } else {
                        Spacer(minLength: 0)
                    }
                    Text(item.time)
                        .fixedSize()
                }
                .font(TypeScale.font(TypeScale.caption, .medium))
                .foregroundStyle(Theme.timer)
                .staticDigits()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SessionRing(model: item.ring)
                .overlay(alignment: .topTrailing) {
                    if item.needsUser { NeedsYouDot(pulses: item.pulses).offset(x: -1, y: 1) }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(highlightFill))
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
