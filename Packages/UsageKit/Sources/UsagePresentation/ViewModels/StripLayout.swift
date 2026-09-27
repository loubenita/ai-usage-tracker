import CoreGraphics

/// A compact edge tab grows into the session list while keeping its placement on screen.
public enum StripLayout {
    /// The expanded strip is a compact provider mark, task and context ring. Session and usage
    /// panels keep the wider reading column beside it.
    public static let expandedWidth: CGFloat = 236
    public static let restingWidth: CGFloat = 32
    public static let panelWidth: CGFloat = 430
    /// The inset at the screen edge and room for the soft glass shadow.
    public static let overlayEdgeInset: CGFloat = 8
    public static let overlayShadowMargin: CGFloat = 32
    /// The transparent window is only as wide as its active glass state.
    public static let restingOverlayWidth = restingWidth + overlayEdgeInset + overlayShadowMargin
    public static let expandedOverlayWidth = expandedWidth + overlayEdgeInset + overlayShadowMargin
    /// Expanded strip + gap + panel + room for the soft glass shadow.
    public static let overlayWidth: CGFloat = expandedWidth + overlayEdgeInset + panelWidth + overlayShadowMargin

    // MARK: - Dragging the strip

    /// The pointer moves this far with the button down before the strip is picked up. Until
    /// then nothing changes, so a click on the handle leaves the strip as it was.
    public static let dragThreshold: CGFloat = 4
    /// The compact rail is a 52pt edge tab: handle, then one count band.
    public static let handleBand: CGFloat = 16
    public static let handleHitWidth: CGFloat = restingWidth
    public static let handleMarkWidth: CGFloat = 14
    public static let compactCountBand: CGFloat = 20
    public static let compactVerticalInset: CGFloat = 8
    public static let compactHeight = handleBand + compactCountBand + 2 * compactVerticalInset
    /// The screenshot-only drag state starts before SwiftUI has measured the resting strip.
    /// This keeps a representative 240pt expanded strip visibly above centre even then.
    public static let forcedDragOffset: CGFloat = -240

    /// Where the strip ends up: where it was when the drag began, plus how far the pointer has
    /// moved, kept inside `limit` so the strip cannot be dragged off the screen.
    public static func dragged(logicalOrigin: CGFloat, by movement: CGFloat, limit: CGFloat) -> CGFloat {
        min(max(logicalOrigin + movement, -limit), limit)
    }

    /// A drag begins at the rail's displayed centre. The expanded rail may have shifted from
    /// its saved resting offset to stay on screen, so restarting at that saved offset would
    /// make it jump when it becomes compact.
    public static func dragOrigin(for placement: Placement) -> CGFloat {
        placement.offset
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

    /// Where the strip goes when it grows. Its growth progressively favours the nearer screen
    /// edge: centred strips grow equally in both directions, while a strip resting at an edge
    /// keeps that edge fixed. The continuous blend between those positions lets a drag follow
    /// the pointer without jumping as it crosses the middle. Whatever happens it stays on the
    /// screen, and a list too long for the screen fills the height and scrolls.
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
        let restingHeight = min(restHeight, height)
        let growthOnEachSide = (height - restingHeight) / 2
        let restingTravel = max((available - restingHeight) / 2, 0)
        let edgeBias = restingTravel > 0
            ? min(max(offset / restingTravel, -1), 1)
            : 0
        let wantedOffset = offset - edgeBias * growthOnEachSide
        let limit = max((available - height) / 2, 0)
        let placedOffset = min(max(wantedOffset, -limit), limit)
        return Placement(
            height: height, offset: placedOffset, scrolls: contentHeight > available
        )
    }

    /// Where a panel of `height` goes beside a strip whose middle is `beside` the screen's
    /// middle: level with the strip, but never off the screen, and scrolling when too tall.
    public static func place(panel height: CGFloat, available: CGFloat, beside: CGFloat) -> Placement {
        place(contentHeight: height, restHeight: height, available: available, offset: beside)
    }
}
