import SwiftUI
import UsageDomain

/// The context ring with the current context used inside: "68k".
struct SessionRing: View {
    let model: RingModel

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: 3)
            Circle()
                .trim(from: 0, to: model.fraction)
                .stroke(
                    model.isNearlyFull ? Theme.red : Theme.ringColor(model.agent),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            // 9.5pt semibold. A long real number shrinks to fit rather than being cut short.
            Text(model.label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 28)
                .staticDigits()
        }
        .padding(2.5)
        .frame(width: 36, height: 36)
    }
}

/// The amber "needs you" dot. Pulses once every 1.6 seconds until hovered;
/// stays solid when Reduce Motion is on.
struct NeedsYouDot: View {
    let pulses: Bool
    /// 9pt on the full strip, 8pt on the half strip.
    var diameter: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Theme.amber)
            .overlay(Circle().stroke(Theme.dotOutline, lineWidth: 1.5))
            .frame(width: diameter, height: diameter)
            .opacity(dimmed ? 0.35 : 1)
            .onAppear(perform: update)
            .onChange(of: pulses) { update() }
            .onChange(of: reduceMotion) { update() }
    }

    private func update() {
        if pulses && !reduceMotion {
            withAnimation(.easeInOut(duration: Theme.pulseDuration / 2).repeatForever(autoreverses: true)) {
                dimmed = true
            }
        } else {
            withAnimation(nil) { dimmed = false }
        }
    }
}

/// The 6pt dot in an agent's colour, beside its name.
struct AgentDot: View {
    let agent: Agent

    var body: some View {
        Circle().fill(Theme.agent(agent)).frame(width: 6, height: 6)
    }
}

/// A thin rounded bar: a track, the used part, and optionally a highlighted part at its end.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat
    var fill: Color = Theme.primary
    /// The end of the used part drawn in another colour: this session's share of a limit.
    var highlight: (fraction: Double, color: Color)?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let used = width * min(max(fraction, 0), 1)
            let lit = min(width * min(max(highlight?.fraction ?? 0, 0), 1), used)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let highlight, lit > 0 {
                    HStack(spacing: 0) {
                        Rectangle().fill(Theme.lift(0.40)).frame(width: used - lit)
                        Rectangle().fill(highlight.color).frame(width: lit)
                    }
                    .frame(width: used, alignment: .leading)
                    .clipShape(Capsule())
                } else {
                    Capsule().fill(fill).frame(width: used)
                }
            }
        }
        .frame(height: height)
    }
}

/// Up to four key numbers in 60pt columns 16pt apart: "Spent" over "$1.10".
struct StatsRow: View {
    let stats: [StatModel]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.label).font(TypeScale.captionFont).foregroundStyle(Theme.label)
                    Text(stat.value)
                        .font(TypeScale.valueFont)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                        .fixedSize()
                        .staticDigits()
                }
                .frame(minWidth: 60, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Context 34%" and its detail over a 5pt bar, with an optional sentence under it.
struct BarRow: View {
    let model: BarRowModel
    var agent: Agent?
    /// The limit views bold their title and draw a 6pt bar in the agent's colour.
    var isLimit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title)
                    .font(TypeScale.font(TypeScale.body, isLimit ? .semibold : .regular))
                    .foregroundStyle(Theme.primary)
                    .fixedSize()
                Spacer(minLength: 8)
                Text(model.detail)
                    .font(TypeScale.secondaryFont)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .staticDigits()
            }
            ProgressBar(
                fraction: model.fraction,
                height: isLimit ? 6 : 5,
                fill: model.isNearlyUsed ? Theme.amber : isLimit ? agent.map(Theme.agent) ?? Theme.primary : Theme.primary,
                highlight: model.highlightFraction.map { ($0, agent.map(Theme.agent) ?? Theme.amber) }
            )
            if let note = model.note {
                Text(note)
                    .font(TypeScale.secondaryFont)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The status row: a coloured dot, what the session is doing, and where it runs.
struct StatusRow: View {
    let model: StatusModel

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            Text(model.text)
                .font(TypeScale.font(TypeScale.body, .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .staticDigits()
            Spacer(minLength: 8)
            if let place = model.place {
                Text(place)
                    .font(TypeScale.secondaryFont)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The one pill the frame lifts off the panel: amber while the session waits for you,
        // red when its context is nearly full.
        .background(RoundedRectangle(cornerRadius: 10).fill(tint))
    }

    private var tint: Color {
        switch model.kind {
        case .waiting: Theme.amber.opacity(0.22)
        case .contextNearlyFull: Theme.red.opacity(0.22)
        case .working, .idle: Theme.lift(0.10)
        }
    }

    private var dotColor: Color {
        switch model.kind {
        case .waiting: Theme.amber
        case .contextNearlyFull: Theme.red
        case .working: Theme.primary
        case .idle: Theme.faint
        }
    }

    private var textColor: Color {
        switch model.kind {
        case .waiting: Theme.amberText
        case .contextNearlyFull: Theme.red
        case .working: Theme.primary
        case .idle: Theme.secondary
        }
    }
}

extension SegmentStyle {
    var barColor: Color {
        switch self {
        case .input: Theme.primary
        case .output: Theme.amber
        case .cacheRead: Theme.lift(0.30)
        case .cacheWrite: Theme.lift(0.60)
        }
    }

    var labelColor: Color {
        self == .output ? Theme.amber : Theme.secondary
    }
}

/// In, out, cache read and cache write as one 5pt bar in 2pt-apart pieces, labelled under it.
struct TokenMixView: View {
    let segments: [TokenSegmentModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let gap: CGFloat = 2
                let available = proxy.size.width - gap * CGFloat(max(segments.count - 1, 0))
                HStack(spacing: gap) {
                    ForEach(segments.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(segments[index].style.barColor)
                            .frame(width: max(available * segments[index].fraction, 2))
                    }
                }
            }
            .frame(height: 5)
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 4) }
                    Text(segments[index].label)
                        .font(TypeScale.captionFont)
                        .foregroundStyle(segments[index].style.labelColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .staticDigits()
                }
            }
        }
    }
}

/// "LIMITS" on the left, "used · frees up" on the right.
struct CapsHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).capsLabel()
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(TypeScale.captionFont).foregroundStyle(Theme.label).lineLimit(1)
            }
        }
    }
}
