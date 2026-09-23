import SwiftUI

/// The 320pt panel a session opens, as Paper frame 3 draws it: who and what, an Open button,
/// the status, four key numbers, the context and the tightest limit, the token mix, and the
/// details. Anything the agent did not report is left out.
struct PanelView: View {
    let model: SessionPanelModel
    let onOpen: () -> Void

    var body: some View {
        // One panel, its sections stacked and separated by lines, as the frame draws it.
        VStack(alignment: .leading, spacing: 12) {
            header
            StatusRow(model: model.status)
            if !model.stats.isEmpty {
                StatsRow(stats: model.stats)
            }
            if model.context != nil || model.limit != nil {
                VStack(alignment: .leading, spacing: 10) {
                    if let context = model.context { BarRow(model: context) }
                    if let limit = model.limit { BarRow(model: limit, agent: model.agent) }
                }
                .sectionDivider()
            }
            if !model.tokenMix.isEmpty {
                TokenMixView(segments: model.tokenMix).sectionDivider()
            }
            if let subagents = model.subagents {
                SubagentsView(model: subagents).sectionDivider()
            }
            if !model.details.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.details, id: \.label) { row in
                        HStack {
                            Text(row.label).foregroundStyle(Theme.secondary)
                            Spacer(minLength: 12)
                            Text(row.value)
                                .foregroundStyle(Theme.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .staticDigits()
                        }
                        .font(TypeScale.secondaryFont)
                    }
                }
                .sectionDivider()
            }
        }
        .glassPanel()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    AgentDot(agent: model.agent)
                    Text(model.subtitle)
                        .font(TypeScale.secondaryFont)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Text(model.title)
                    .font(TypeScale.titleFont)
                    .tracking(-0.17)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.canOpen {
                OpenButton(action: onOpen)
            }
        }
    }
}

/// The session's sub-agents, a row per model: runs, tokens, cost at API prices and time.
private struct SubagentsView: View {
    let model: SubagentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsHeader(title: model.title, trailing: model.share)
            ForEach(model.rows) { row in
                HStack(spacing: 0) {
                    Text(row.name).foregroundStyle(Theme.name).lineLimit(1).frame(width: 130, alignment: .leading)
                    Text(row.tokens ?? "").foregroundStyle(Theme.primary).frame(width: 50, alignment: .trailing)
                    Text(row.cost ?? "").foregroundStyle(Theme.primary).frame(width: 50, alignment: .trailing)
                    Text(row.time).foregroundStyle(Theme.secondary).frame(width: 58, alignment: .trailing)
                }
                .font(TypeScale.secondaryFont)
                .staticDigits()
            }
        }
    }
}

/// "↗" in a round button: brings the session's terminal to the front.
private struct OpenButton: View {
    let action: () -> Void

    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.primary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Theme.lift(0.16)))
            .help("Open the session's terminal")
            .clickable("Open the session's terminal", action: action)
    }
}
