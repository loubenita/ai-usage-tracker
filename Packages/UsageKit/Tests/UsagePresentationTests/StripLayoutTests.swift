import CoreGraphics
import Testing
import UsageDomain
@testable import UsagePresentation

@Suite("Strip layout")
struct StripLayoutTests {
    @Test func theExpandedListAndCompactTabStaySmall() {
        #expect(StripLayout.expandedWidth == 236)
        #expect(StripLayout.restingWidth == 36)
        #expect(StripLayout.compactSessionLimit == 4)
        #expect(StripLayout.compactHeight == 166)
        #expect(StripLayout.compactHeight < 180)
        #expect(StripLayout.restingOverlayWidth == 76)
        #expect(StripLayout.expandedOverlayWidth == 276)
        #expect(StripLayout.railTransitionDuration == 0.42)
        #expect(StripLayout.compactContentHeight(for: 0) == 24)
        #expect(StripLayout.compactContentHeight(for: 1) == 24)
        #expect(StripLayout.compactContentHeight(for: 2) == 52)
        #expect(StripLayout.compactContentHeight(for: 3) == 80)
        #expect(StripLayout.compactContentHeight(for: 4) == 108)
        #expect(StripLayout.compactContentHeight(for: 5) == 128)
    }

    @Test func compactTabUsesFourHighestPrioritySessionsAndCountsTheRest() {
        let items = [item(id: "sixth", priority: 5), item(id: "third", priority: 2),
                     item(id: "first", priority: 0), item(id: "fifth", priority: 4),
                     item(id: "second", priority: 1), item(id: "fourth", priority: 3)]

        #expect(StripLayout.compactItems(from: items).map(\.id) == ["first", "second", "third", "fourth"])
        #expect(StripLayout.compactOverflowCount(for: items) == 2)
    }

    @Test func compactHoverExcludesTheDragHandleAndIncludesTheFirstRing() {
        #expect(!StripLayout.isCompactHoverTarget(y: 8))
        #expect(!StripLayout.isCompactHoverTarget(y: 29))
        #expect(StripLayout.isCompactHoverTarget(y: 30))
        #expect(StripLayout.isCompactHoverTarget(y: StripLayout.compactHeight - 8))
    }

    // MARK: - Dragging

    @Test func theStripFollowsThePointerFromWhereItWas() {
        // A press at -40 that moves up 10, up 60 and back down 25.
        let start: CGFloat = -40
        let limit: CGFloat = 300
        let path: [CGFloat] = [-10, -60, -35]
        #expect(path.map { StripLayout.dragged(logicalOrigin: start, by: $0, limit: limit) } == [-50, -100, -75])
        // It is where it was dropped, not where the pointer went past the edge.
        #expect(StripLayout.dragged(logicalOrigin: start, by: -900, limit: limit) == -300)
        #expect(StripLayout.dragged(logicalOrigin: start, by: 900, limit: limit) == 300)
        // A press that has not moved leaves it exactly where it was.
        #expect(StripLayout.dragged(logicalOrigin: start, by: 0, limit: limit) == start)
    }

    @Test func aDragAwayFromCentreStartsAtItsLogicalRestingOffset() {
        let logicalStart: CGFloat = -100
        let visualStart = StripLayout.place(
            contentHeight: full, restHeight: rest, available: available, offset: logicalStart
        ).offset
        let movedLogical = StripLayout.dragged(logicalOrigin: logicalStart, by: -5, limit: 300)
        let movedVisual = StripLayout.place(
            contentHeight: full, restHeight: rest, available: available, offset: movedLogical
        ).offset

        // Moving the pointer upward must move the strip upward from where it was drawn,
        // without first jumping towards the middle.
        #expect(movedVisual < visualStart)
        #expect(visualStart - movedVisual <= 5)
    }

    @Test func aDragStartsAtTheRailsDrawnPosition() {
        let logicalStart: CGFloat = -180
        let drawn = StripLayout.place(
            contentHeight: full, restHeight: rest, available: available, offset: logicalStart
        )

        // When an expanded rail collapses at drag start, its stored offset must begin at the
        // drawn centre. Otherwise the rail jumps before it can follow the pointer.
        #expect(StripLayout.dragOrigin(for: drawn) == drawn.offset)
        #expect(StripLayout.dragOrigin(for: drawn) != logicalStart)
    }

    @Test func theThresholdIsSmallEnoughToFeelImmediateAndBigEnoughToSurviveAClick() {
        #expect(StripLayout.dragThreshold == 4)
    }

    @Test func theDragHandleStaysFullyVisibleAtTheScreenEdge() {
        #expect(StripLayout.handleHitWidth == 36)
        #expect(StripLayout.handleMarkWidth == 14)
        #expect(StripLayout.handleHitWidth / 2 == 18)
    }

    // MARK: - Staying on the screen

    /// A screen 900pt tall, a resting strip of 300pt, growing to 500pt.
    let available: CGFloat = 900
    let rest: CGFloat = 300
    let full: CGFloat = 500

    @Test func inTheMiddleItGrowsBothWays() {
        let placed = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: 0)
        #expect(placed.height == full)
        // Its middle does not move, so it grows 100pt up and 100pt down.
        #expect(placed.offset == 0)
        #expect(placed.scrolls == false)
    }

    @Test func draggingThroughTheMiddleIsContinuousAndMonotonic() {
        let pointerOffsets = stride(from: CGFloat(-200), through: 200, by: 1)
        let placedOffsets = pointerOffsets.map {
            StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: $0).offset
        }

        for (previous, next) in zip(placedOffsets, placedOffsets.dropFirst()) {
            // A one-point pointer movement cannot send the strip backwards or make it jump.
            #expect(next >= previous)
            #expect(next - previous <= 1.001)
        }
    }

    @Test func theForcedDragStateMovesBeforeTheRestingHeightHasBeenMeasured() {
        let centered = StripLayout.place(contentHeight: 240, restHeight: 0, available: available, offset: 0)
        let dragged = StripLayout.place(
            contentHeight: 240, restHeight: 0, available: available,
            offset: StripLayout.forcedDragOffset
        )
        #expect(centered.offset == 0)
        #expect(abs(dragged.offset + 176) < 0.001)
    }

    @Test func nearTheTopItGrowsDownwards() {
        // Two-thirds of the way to the top, two-thirds of the added height grows downwards.
        let placed = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: -200)
        #expect(abs(placed.offset + 400 / 3) < 0.001)
        #expect(placed.offset - placed.height / 2 + available / 2 >= 0)
    }

    @Test func nearTheBottomItGrowsUpwards() {
        let placed = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: 200)
        #expect(abs(placed.offset - 400 / 3) < 0.001)
        #expect(placed.offset + placed.height / 2 + available / 2 <= available)
    }

    @Test func aStripDraggedPastAnEdgeComesBackOnAtRest() {
        // Even at rest, a strip dragged too far is pulled back onto the screen.
        let placed = StripLayout.place(contentHeight: rest, restHeight: rest, available: available, offset: -400)
        #expect(placed.offset == -(available - rest) / 2)
    }

    @Test func againstAnEdgeItIsPushedBackOn() {
        // Dragged as far up as it goes, then grown: it can only start at the top edge.
        let placed = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: -450)
        #expect(placed.offset == -(available - full) / 2)
        let bottom = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: 450)
        #expect(bottom.offset == (available - full) / 2)
    }

    @Test func aListTooLongForTheScreenFillsItAndScrolls() {
        let placed = StripLayout.place(contentHeight: 1_200, restHeight: rest, available: available, offset: -300)
        #expect(placed.height == available)
        #expect(placed.offset == 0)
        #expect(placed.scrolls)
    }

    @Test func aPanelSitsBesideTheStripAndStaysOnTheScreen() {
        // Level with the strip when there is room.
        #expect(StripLayout.place(panel: 400, available: available, beside: -100).offset == -100)
        // Pushed back on when the strip is near an edge.
        #expect(StripLayout.place(panel: 700, available: available, beside: -300).offset == -100)
        #expect(StripLayout.place(panel: 700, available: available, beside: 300).offset == 100)
        // Taller than the screen: it fills the height and scrolls.
        let tall = StripLayout.place(panel: 1_000, available: available, beside: 200)
        #expect(tall.height == available && tall.offset == 0 && tall.scrolls)
    }

    @Test func theGrowthAnchorIsThePointThatStaysStillWhileTheRailGrows() {
        let rest: CGFloat = 150
        for offset: CGFloat in [-375, -200, 0, 120, 375] {
            let anchor = StripLayout.growthAnchor(restHeight: rest, available: available, offset: offset)
            let resting = StripLayout.place(contentHeight: rest, restHeight: rest, available: available, offset: offset)
            let grown = StripLayout.place(contentHeight: 400, restHeight: rest, available: available, offset: offset)
            // The same fraction of the rail's height sits at the same height on screen.
            let before = resting.offset + (anchor - 0.5) * rest
            let after = grown.offset + (anchor - 0.5) * 400
            #expect(abs(before - after) < 0.001)
        }
        #expect(StripLayout.growthAnchor(restHeight: rest, available: available, offset: 0) == 0.5)
        #expect(StripLayout.growthAnchor(restHeight: rest, available: available, offset: 375) == 1)
        #expect(StripLayout.growthAnchor(restHeight: rest, available: available, offset: -375) == 0)
    }

    @Test func aSessionPanelLinesUpItsTopWithTheClickedRow() {
        #expect(available == 900)
        // A row 100pt from the top: the 400pt panel's top is level with it.
        #expect(StripLayout.place(panel: 400, available: available, top: 100).offset == -150)
        // A row near the bottom: the panel is pushed up until its bottom meets the screen's.
        #expect(StripLayout.place(panel: 400, available: available, top: 800).offset == 250)
        // Taller than the screen: it fills the height and scrolls.
        let tall = StripLayout.place(panel: 1_000, available: available, top: 300)
        #expect(tall.height == available && tall.offset == 0 && tall.scrolls)
    }

    @Test func theUsagePanelLinesUpItsBottomWithTheUsageButton() {
        #expect(StripLayout.place(panel: 400, available: available, bottom: 850).offset == 200)
        // A button near the top: the panel is pushed down until its top meets the screen's.
        #expect(StripLayout.place(panel: 400, available: available, bottom: 100).offset == -250)
    }

    private func item(id: String, priority: Int) -> StripItemModel {
        StripItemModel(
            id: id,
            ring: RingModel(label: "", fraction: 0, isNearlyFull: false, agent: .claudeCode),
            title: "", project: "", branch: nil, time: "", needsUser: false, pulses: false,
            highlight: .none, priority: priority, accessibilityLabel: id
        )
    }
}
