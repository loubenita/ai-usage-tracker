import SwiftUI
import UsageDomain

/// The usage button's shared-width panel, as Paper frames 4 to 6 draw it: an agent picker, the
/// period tabs with the refresh countdown, then every agent together or one on its own.
struct UsagePanelView: View {
    let model: UsagePanelModel
    let onSelectAgent: (AgentFilter) -> Void
    let onSelectPeriod: (UsagePeriod) -> Void
    let onRefresh: () -> Void

    var body: some View {
        // One panel, its sections stacked and separated by lines, as the frames draw them.
        VStack(alignment: .leading, spacing: 12) {
            AgentPicker(items: model.picker, selected: model.selected, onSelect: onSelectAgent)
            periodRow
            switch model.content {
            case .all(let all): AllAgentsView(model: all)
            case .agent(let agent): AgentUsageView(model: agent)
            }
        }
        .glassPanel()
    }

    private var periodRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 14) {
                ForEach(UsagePeriod.allCases, id: \.self) { period in
                    let isSelected = period == model.period
                    Text(Self.name(period))
                        .font(TypeScale.font(TypeScale.body, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.primary : Theme.label)
                        .fixedSize()
                        .padding(.bottom, 1)
                        .overlay(alignment: .bottom) {
                            if isSelected { Rectangle().fill(Theme.primary).frame(height: 2).offset(y: 2) }
                        }
                        .clickable(Self.name(period)) { onSelectPeriod(period) }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            Spacer(minLength: 8)
            if let label = model.refreshLabel {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                    Text(label).font(TypeScale.captionFont).staticDigits()
                }
                .foregroundStyle(Theme.secondary)
                .fixedSize()
                .clickable("Refresh the totals now. \(label)", action: onRefresh)
            }
        }
        .frame(height: 20)
    }

    static func name(_ period: UsagePeriod) -> String {
        switch period {
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// "All · Claude · Codex · Cursor": segments that share the picker's width, 3pt inside it.
private struct AgentPicker: View {
    let items: [PickerItemModel]
    let selected: AgentFilter
    let onSelect: (AgentFilter) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let isSelected = item.filter == selected
                HStack(spacing: 5) {
                    if let agent = item.agent { AgentDot(agent: agent) }
                    Text(item.name)
                        .font(TypeScale.font(TypeScale.secondary, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.primary : Theme.name)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                // The selected agent sits on a lighter pill inside the picker's track.
                .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Theme.lift(0.22) : .clear))
                .clickable(item.name) { onSelect(item.filter) }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.15)))
    }
}

// MARK: - Frame 4: every agent

private struct AllAgentsView: View {
    let model: AllAgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: GlassStyle.spacing) {
            if model.headline != nil || !model.limits.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if let headline = model.headline {
                        Text(headline)
                            .font(TypeScale.bodyFont)
                            .lineSpacing(2)
                            .foregroundStyle(Theme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.limits.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            CapsHeader(title: "LIMITS", trailing: "used · frees up")
                            ForEach(model.limits) { LimitListRow(model: $0) }
                        }
                    }
                }
            }
            if !model.rows.isEmpty {
                AgentTable(model: model).sectionDivider()
            }
            if !model.whereRows.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("WHERE THE TIME WENT").capsLabel()
                    ForEach(model.whereRows) { TimeRow(model: $0, labelWidth: 180) }
                }
                .sectionDivider()
            }
        }
    }
}

/// "● Claude 5-hour  [bar]  62%  16:40", in fixed lanes so the rows line up.
private struct LimitListRow: View {
    let model: LimitListRowModel

    var body: some View {
        HStack(spacing: 8) {
            AgentDot(agent: model.agent)
            Text(model.name)
                .font(TypeScale.secondaryFont)
                .foregroundStyle(Theme.name)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            if let fraction = model.fraction {
                ProgressBar(fraction: fraction, height: 4, fill: model.isNearlyUsed ? Theme.amber : Theme.primary)
                    .frame(width: 76)
                Text(model.used)
                    .font(TypeScale.font(TypeScale.secondary, model.isNearlyUsed ? .semibold : .regular))
                    .foregroundStyle(model.isNearlyUsed ? Theme.amber : Theme.primary)
                    .frame(width: 30, alignment: .trailing)
                Text(model.freesUp)
                    .font(TypeScale.secondaryFont)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(width: 46, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
                Text(model.freesUp).font(TypeScale.secondaryFont).foregroundStyle(Theme.faint)
            }
        }
        .staticDigits()
    }
}

/// Time, tokens and spend per agent, with the "All agents" total under a line.
private struct AgentTable: View {
    let model: AllAgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                // Real weeks run to "886.8M" and "$464.46", so each column is wide enough
                // for its longest number and the rows never touch.
                Text(model.tableTitle).capsLabel().frame(width: 112, alignment: .leading)
                header("time", width: 60)
                header("tokens", width: 56)
                header("spend", width: 60)
            }
            ForEach(model.rows) { row(for: $0, bold: false) }
            if let total = model.total {
                row(for: total, bold: true)
                    .padding(.top, 7)
                    .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            }
        }
    }

    private func header(_ text: String, width: CGFloat) -> some View {
        Text(text).font(TypeScale.captionFont).foregroundStyle(Theme.label).frame(width: width, alignment: .trailing)
    }

    private func row(for row: AgentTableRowModel, bold: Bool) -> some View {
        let weight: Font.Weight = bold ? .semibold : .regular
        return HStack(spacing: 0) {
            HStack(spacing: 7) {
                if let agent = row.agent { AgentDot(agent: agent) }
                Text(row.name).font(TypeScale.font(TypeScale.body, weight)).foregroundStyle(Theme.primary)
            }
            .frame(width: 112, alignment: .leading)
            cell(row.time, width: 60, weight: weight)
            cell(row.tokens, width: 56, weight: weight)
            cell(row.spend, width: 60, weight: weight)
        }
        .staticDigits()
    }

    private func cell(_ value: String?, width: CGFloat, weight: Font.Weight) -> some View {
        Text(value ?? "n/a")
            .font(TypeScale.font(TypeScale.body, weight))
            .foregroundStyle(value == nil ? Theme.faint : Theme.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
    }
}

/// "● MS · Video generation  50%  2h 58m".
private struct TimeRow: View {
    let model: TimeRowModel
    let labelWidth: CGFloat
    var showsPercent = true

    var body: some View {
        HStack(spacing: 8) {
            if showsPercent {
                Group {
                    if let agent = model.agent { AgentDot(agent: agent) } else { Color.clear }
                }
                .frame(width: 6, height: 6)
            }
            Text(model.label)
                .font(TypeScale.secondaryFont)
                .foregroundStyle(Theme.name)
                .lineLimit(1)
                .frame(maxWidth: showsPercent ? labelWidth : .infinity, alignment: .leading)
            if showsPercent {
                Text(model.percent ?? "").font(TypeScale.secondaryFont).foregroundStyle(Theme.primary)
                    .frame(width: 32, alignment: .trailing)
            }
            Text(model.time)
                .font(TypeScale.secondaryFont)
                .foregroundStyle(showsPercent ? Theme.secondary : Theme.primary)
                .fixedSize()
                .frame(minWidth: 46, alignment: .trailing)
        }
        .staticDigits()
    }
}

// MARK: - Frames 5 and 6: one agent

private struct AgentUsageView: View {
    let model: AgentUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = model.note {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title).font(TypeScale.font(TypeScale.body, .semibold)).foregroundStyle(Theme.primary)
                    Text(note.text)
                        .font(TypeScale.secondaryFont)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.lift(0.10)))
            }
            if !model.limits.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.limits.indices, id: \.self) { index in
                        BarRow(model: model.limits[index], agent: model.agent, isLimit: true)
                    }
                }
            }
            if !model.stats.isEmpty {
                if model.limits.isEmpty {
                    StatsRow(stats: model.stats)
                } else {
                    StatsRow(stats: model.stats).sectionDivider()
                }
            }
            if let chart = model.chart {
                ChartView(model: chart, agent: model.agent)
            }
            if !model.models.isEmpty || !model.whereRows.isEmpty {
                columns.sectionDivider()
            }
        }
    }

    /// Models on the left and where the time went on the right; either alone takes the width.
    private var columns: some View {
        HStack(alignment: .top, spacing: 16) {
            if !model.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODELS").capsLabel()
                    ForEach(model.models) { row in
                        HStack {
                            Text(row.name).foregroundStyle(Theme.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(row.percent).foregroundStyle(Theme.primary)
                        }
                        .font(TypeScale.secondaryFont)
                        .staticDigits()
                    }
                }
                .frame(width: model.whereRows.isEmpty ? nil : 112, alignment: .leading)
                .frame(maxWidth: model.whereRows.isEmpty ? .infinity : nil, alignment: .leading)
            }
            if !model.whereRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHERE THE TIME WENT").capsLabel().lineLimit(1)
                    ForEach(model.whereRows) { row in
                        TimeRow(model: row, labelWidth: 180, showsPercent: model.models.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Bars per day or per week, the busiest in the agent's colour and the current one in white.
private struct ChartView: View {
    let model: ChartModel
    let agent: Agent

    var body: some View {
        let barWidth: CGFloat = model.bars.count > 4 ? 32 : 64
        VStack(alignment: .leading, spacing: 6) {
            CapsHeader(title: model.title, trailing: model.caption)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(model.bars.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    let bar = model.bars[index]
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bar.isBusiest ? Theme.agent(agent) : bar.isCurrent ? Theme.primary : Theme.lift(0.35))
                        .frame(width: barWidth, height: max(chartHeight * bar.fraction, 4))
                }
            }
            .frame(height: chartHeight, alignment: .bottom)
            HStack(spacing: 0) {
                ForEach(model.bars.indices, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 0) }
                    let bar = model.bars[index]
                    Text(bar.label)
                        .font(TypeScale.captionFont)
                        .foregroundStyle(bar.isCurrent ? Theme.primary : Theme.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: barWidth + (model.bars.count > 4 ? 4 : 8))
                        .staticDigits()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.title.capitalized): \(model.caption)")
    }

    private var chartHeight: CGFloat { model.bars.count > 4 ? 56 : 48 }
}
