import CoreGraphics

/// How many sessions the strip shows: at rest the few most recently busy, and never more
/// than the screen has room for.
public enum StripLayout {
    /// The expanded strip leaves room for the agent, project and task instead of showing
    /// anonymous rings. Session and usage panels use the same wider reading column.
    public static let expandedWidth: CGFloat = 224
    public static let panelWidth: CGFloat = 360
    /// Expanded strip + gap + panel + room for the soft glass shadow.
    public static let overlayWidth: CGFloat = expandedWidth + 8 + panelWidth + 32

    /// The resting strip lists this many sessions, the most recently busy first, and counts
    /// the rest in a "+N" item.
    public static let restLimit = 5

    /// Half strip, from Paper frame 1: 12pt padding at the top and bottom, and a 51pt item
    /// (36pt half ring, 3pt gap, 12pt time) every 63pt.
    static let restPadding: CGFloat = 12 * 2
    static let restItemPitch: CGFloat = 51 + 12
    static let restItemHeight: CGFloat = 51
    /// The "+N" band across the foot of the strip, and the gap above it.
    static let restChipHeight: CGFloat = 26
    static let restChipGap: CGFloat = 10
    static let restChip: CGFloat = restChipHeight + restChipGap

    /// Sessions that fit on the half strip in `height`, and never more than `restLimit`. The
    /// "+N" chip is a small chip rather than an item, so it takes no session's place; it does
    /// take its own room, so `showingChip` leaves it.
    public static func restCapacity(height: CGFloat, showingChip: Bool = false) -> Int {
        let forItems = height - restPadding - (showingChip ? restChip : 0)
        guard forItems >= restItemHeight else { return 1 }
        return min(Int((forItems - restItemHeight) / restItemPitch) + 1, restLimit)
    }

    /// Which sessions to draw: as many as there is room for, and a "+N" chip counting the rest.
    public static func visible(count: Int, capacity: Int) -> (shown: Int, hidden: Int) {
        let shown = min(count, capacity)
        return (shown, count - shown)
    }

    // MARK: - Dragging the strip

    /// The pointer moves this far with the button down before the strip is picked up. Until
    /// then nothing changes, so a click on the handle leaves the strip as it was.
    public static let dragThreshold: CGFloat = 4
    /// The handle's band at the top of the strip: a press that starts here drags it at once.
    public static let handleBand: CGFloat = 14

    /// Whether a press may drag the strip: it started on the handle, or the strip has been
    /// held long enough to be picked up from anywhere.
    public static func canDrag(fromY y: CGFloat, isHeld: Bool) -> Bool {
        isHeld || (y >= 0 && y <= handleBand)
    }

    /// Where the strip ends up: where it was when the drag began, plus how far the pointer has
    /// moved, kept inside `limit` so the strip cannot be dragged off the screen.
    public static func dragged(from start: CGFloat, by movement: CGFloat, limit: CGFloat) -> CGFloat {
        min(max(start + movement, -limit), limit)
    }

    /// Where something of `height` sits on the edge, and whether it has to scroll.
    public struct Placement: Sendable, Equatable {
        /// The height it may take: its own, or the whole screen when it is taller.
        public let height: CGFloat
        /// How far its middle sits from the middle of the screen: negative is up.
        public let offset: CGFloat
        /// True when it did not fit, so its list scrolls inside it.
        public let scrolls: Bool
    }

    /// Where the strip goes when it grows. It grows downwards from where it sits while it is in
    /// the top half of the screen, and upwards while it is in the bottom half, so the sessions
    /// under the pointer stay where they were. Whatever happens it stays on the screen, and a
    /// list too long for the screen fills the height and scrolls.
    ///
    /// - Parameters:
    ///   - contentHeight: how tall the strip wants to be.
    ///   - restHeight: how tall it is at rest, whose edge the growth keeps.
    ///   - available: the screen's height, less the margin kept at the top and bottom.
    ///   - offset: where the person dragged it, from the middle of the screen.
    public static func place(
        contentHeight: CGFloat, restHeight: CGFloat, available: CGFloat, offset: CGFloat
    ) -> Placement {
        let height = min(contentHeight, available)
        let restTop = (available - restHeight) / 2 + offset
        // In the top half it keeps its top edge and grows downwards; in the bottom half it
        // keeps its bottom edge and grows upwards; in the middle it grows both ways.
        let wanted = switch offset {
        case ..<0: restTop
        case 0: restTop + (restHeight - height) / 2
        default: restTop + restHeight - height
        }
        let top = min(max(wanted, 0), max(available - height, 0))
        return Placement(
            height: height, offset: top + height / 2 - available / 2, scrolls: contentHeight > available
        )
    }

    /// Where a panel of `height` goes beside a strip whose middle is `beside` the screen's
    /// middle: level with the strip, but never off the screen, and scrolling when too tall.
    public static func place(panel height: CGFloat, available: CGFloat, beside: CGFloat) -> Placement {
        place(contentHeight: height, restHeight: height, available: available, offset: beside)
    }
}
