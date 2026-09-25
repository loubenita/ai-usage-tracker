import SwiftUI
import UsageDomain

/// Colours, type and glass taken from the Paper file "AI Usage Tracker", Overlay page.
enum Theme {
    /// "Needs you", and a limit at 85% or more.
    static let amber = Color(red: 1, green: 0xB2 / 255, blue: 0x3E / 255)
    static let amberText = Color(red: 1, green: 0xD0 / 255, blue: 0x8A / 255)
    /// "Context nearly full".
    static let red = Color(red: 1, green: 0x6B / 255, blue: 0x5E / 255)
    /// The outline drawn around the amber dot so it separates from the ring.
    static let dotOutline = Color(red: 40 / 255, green: 30 / 255, blue: 60 / 255).opacity(0.55)

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Each agent's colour, from the Paper tokens `--color-agent-*`: the dot beside its name,
    /// its bars and its chart's busiest bar.
    static func agent(_ agent: Agent) -> Color {
        switch agent {
        case .claudeCode: hex(0xE8845C)
        case .codex: hex(0xDADDE2)
        case .cursor: hex(0x7FA7FF)
        case .antigravity: hex(0x62D2C4)
        case .kiro: hex(0xC49BFF)
        case .opencode: hex(0xF2D45C)
        }
    }

    /// A session's ring. The frames draw Claude's rings in the text colour; every other agent's
    /// ring takes the agent's colour, so their sessions tell apart on the strip.
    static func ringColor(_ agent: Agent) -> Color {
        agent == .claudeCode ? primary : self.agent(agent)
    }

    // Text and lines adapt to light and dark mode, so they stay readable on the glass over a
    // bright wallpaper as well as a dark one. Named by what they are for, with the frames'
    // dark-mode opacity beside each.
    static let primary = Color.primary
    /// Timers on the strip: #FFFFFFEB.
    static let timer = Color.primary.opacity(0.92)
    /// Names in lists and the picker: #FFFFFFDB.
    static let name = Color.primary.opacity(0.86)
    /// Details and captions: #FFFFFFB8.
    static let secondary = Color.secondary
    /// Stat labels, caps labels, unselected tabs: #FFFFFF99.
    static let label = Color.primary.opacity(0.60)
    /// "n/a" and "no data": #FFFFFF80.
    static let faint = Color.primary.opacity(0.45)
    /// Bar tracks: #FFFFFF2E.
    static let track = Color.primary.opacity(0.18)
    /// Section lines: #FFFFFF24.
    static let divider = Color.primary.opacity(0.14)
    /// A fill that lifts a part of a module: the selected tab, a note, an item under the pointer.
    static func lift(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }

    static let pulseDuration: Double = 1.6
}

/// The type scale, in one place. The panels use these five sizes and no others.
enum TypeScale {
    /// 11: caps section labels, stat labels and captions.
    static let caption: CGFloat = 11
    /// 12: secondary text and table rows.
    static let secondary: CGFloat = 12
    /// 13: body text and tabs.
    static let body: CGFloat = 13
    /// 15 semibold: key numbers.
    static let value: CGFloat = 15
    /// 17 semibold: a session's title.
    static let title: CGFloat = 17

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    static let captionFont = font(caption)
    static let secondaryFont = font(secondary)
    static let bodyFont = font(body)
    static let valueFont = font(value, .semibold)
    static let titleFont = font(title, .semibold)
}

/// Liquid Glass. The panel and the strip are each one piece of it, as the Paper frames draw
/// them, and it is their only background: no fill, no gradient and no layer sits behind the
/// content, so the desktop shows through, blurred and bent at the edges. Paper cannot draw
/// glass, so its frames only stand in for it.
///
/// Nothing inside draws glass of its own, because glass over glass turns dark. The few pieces
/// the frames lift — the status pill, the picker's track and selected pill, and the round
/// buttons — are translucent white instead.
enum GlassStyle {
    /// The gap between the strip and the panel; also the container's merge distance.
    static let spacing: CGFloat = 8
    static let panelRadius: CGFloat = 22
    static let stripRadius: CGFloat = 22

    static func glass(tint: Color? = nil, interactive: Bool = false) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// A panel wide enough for descriptive labels and individual sub-agent metrics, with its
    /// content inset 16pt, on glass and nothing else.
    func glassPanel(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(width: StripLayout.panelWidth, alignment: .leading)
            .glassEffect(GlassStyle.glass(), in: .rect(cornerRadius: GlassStyle.panelRadius))
    }

    /// Something to click in the overlay. The overlay's window never becomes key, so SwiftUI
    /// buttons in it can swallow their clicks; a tap, as the strip's rings use, always arrives.
    func clickable(_ label: String, action: @escaping () -> Void) -> some View {
        contentShape(.rect)
            .onTapGesture(perform: action)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    /// Digits change in place, with no rolling animation.
    func staticDigits() -> some View {
        contentTransition(.identity).transaction { $0.animation = nil }
    }

    /// A line across the top of a section, 12pt above its content, as the frames separate blocks.
    func sectionDivider(paddingTop: CGFloat = 12) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, paddingTop)
            .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    /// Caps section labels: 11pt semibold, tracked 0.06em.
    func capsLabel() -> some View {
        font(TypeScale.font(TypeScale.caption, .semibold)).tracking(0.66).foregroundStyle(Theme.label)
    }
}
