import SwiftUI

/// The panel a session opens: who and what, status, totals, context and the tightest limit stay
/// visible. Token breakdowns, individual sub-agent runs and supporting facts sit behind one
/// disclosure so the useful depth does not crowd the session's current state.
struct PanelView: View {
    let model: SessionPanelModel
    let onOpen: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            if hasDetails {
                detailsToggle.sectionDivider()
                if showsDetails {
                    if !model.tokenMix.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CapsHeader(title: "TOKEN BREAKDOWN")
                            TokenMixView(segments: model.tokenMix)
                        }
                    }
                    if let subagents = model.subagents {
                        SubagentsView(model: subagents).sectionDivider()
                    }
                    if !model.details.isEmpty {
                        SessionDetailsView(rows: model.details).sectionDivider()
                    }
                }
            }
        }
        .glassPanel()
        .onChange(of: model.sessionID) { showsDetails = false }
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

    private var hasDetails: Bool {
        !model.tokenMix.isEmpty || model.subagents != nil || !model.details.isEmpty
    }

    private var detailsToggle: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsDetails ? "Hide details" : "Show details")
                    .font(TypeScale.font(TypeScale.body, .semibold))
                    .foregroundStyle(Theme.primary)
                Text(detailsSummary)
                    .font(TypeScale.captionFont)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 2)
        .clickable(showsDetails ? "Hide session details" : "Show session details") {
            showsDetails.toggle()
        }
    }

    private var detailsSummary: String {
        [
            model.tokenMix.isEmpty ? nil : "token mix",
            model.subagents.map { "\($0.rows.count) sub-agent \($0.rows.count == 1 ? "run" : "runs")" },
            model.details.isEmpty ? nil : "\(model.details.count) session facts",
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The session's sub-agents, with their aggregate followed by tokens, cost and time per run.
private struct SubagentsView: View {
    let model: SubagentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CapsHeader(title: model.title, trailing: model.share)
            Text(model.inclusion)
                .font(TypeScale.font(TypeScale.secondary, .medium))
                .foregroundStyle(Theme.primary)
            HStack {
                Text("All runs").foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                Text(model.total).foregroundStyle(Theme.primary)
            }
            .font(TypeScale.secondaryFont)
            .staticDigits()
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.model)
                            .font(TypeScale.font(TypeScale.body, .semibold))
                            .foregroundStyle(Theme.name)
                        Spacer(minLength: 8)
                        Text(row.run)
                            .font(TypeScale.captionFont)
                            .foregroundStyle(Theme.secondary)
                    }
                    HStack(spacing: 20) {
                        if let tokens = row.tokens { metric("Tokens", tokens) }
                        if let cost = row.cost { metric("Cost", cost) }
                        metric("Time", row.time)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.lift(0.08)))
                .help("Sub-agent \(row.id)")
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(TypeScale.captionFont).foregroundStyle(Theme.label)
            Text(value).font(TypeScale.secondaryFont).foregroundStyle(Theme.primary).staticDigits()
        }
    }
}

/// Supporting facts use a label-over-value layout so branches and first asks can wrap instead
/// of being squeezed into one dense row.
private struct SessionDetailsView: View {
    let rows: [DetailRowModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsHeader(title: "SESSION DETAILS")
            ForEach(rows, id: \.label) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).font(TypeScale.captionFont).foregroundStyle(Theme.label)
                    Text(row.value)
                        .font(TypeScale.secondaryFont)
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .staticDigits()
                }
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
