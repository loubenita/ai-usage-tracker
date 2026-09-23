import CoreGraphics
import Testing
@testable import UsagePresentation

@Suite("How many sessions fit on the strip")
struct StripLayoutTests {
    @Test func countsWholeItemsAfterThePaddingAndStopsAtFive() {
        // 24pt of padding, one 51pt item and one more every 63pt, but never more than five.
        #expect(StripLayout.restCapacity(height: 907) == 5)
        #expect(StripLayout.restCapacity(height: 24 + 51) == 1)
        #expect(StripLayout.restCapacity(height: 24 + 51 + 63) == 2)
        #expect(StripLayout.restCapacity(height: 24 + 51 + 62) == 1)
    }

    @Test func aTinyScreenStillShowsOne() {
        #expect(StripLayout.restCapacity(height: 10) == 1)
    }

    @Test func showsEverySessionWhenTheyFit() {
        #expect(StripLayout.visible(count: 4, capacity: 5) == (4, 0))
        #expect(StripLayout.visible(count: 5, capacity: 5) == (5, 0))
    }

    @Test func theChipCountsTheRestWithoutTakingASessionsPlace() {
        // Nine sessions, room for five: five rings and "+4", not four and "+5".
        #expect(StripLayout.visible(count: 9, capacity: 5) == (5, 4))
        // The band needs its own room at the foot, so a screen that fits five rings without
        // it fits four with it.
        let fiveRings = CGFloat(24 + 51 + 4 * 63)
        #expect(StripLayout.restCapacity(height: fiveRings) == 5)
        #expect(StripLayout.restCapacity(height: fiveRings, showingChip: true) == 4)
        #expect(StripLayout.restCapacity(height: fiveRings + StripLayout.restChip, showingChip: true) == 5)
    }

    // MARK: - Dragging

    @Test func onlyTheHandleStartsADragUntilTheStripHasBeenHeld() {
        // The handle is the top 14pt of the strip.
        #expect(StripLayout.canDrag(fromY: 0, isHeld: false))
        #expect(StripLayout.canDrag(fromY: 14, isHeld: false))
        #expect(!StripLayout.canDrag(fromY: 15, isHeld: false))
        #expect(!StripLayout.canDrag(fromY: 200, isHeld: false))
        // Held for five seconds, anywhere on the strip drags it.
        #expect(StripLayout.canDrag(fromY: 200, isHeld: true))
    }

    @Test func theStripFollowsThePointerFromWhereItWas() {
        // A press at -40 that moves up 10, up 60 and back down 25.
        let start: CGFloat = -40
        let limit: CGFloat = 300
        let path: [CGFloat] = [-10, -60, -35]
        #expect(path.map { StripLayout.dragged(from: start, by: $0, limit: limit) } == [-50, -100, -75])
        // It is where it was dropped, not where the pointer went past the edge.
        #expect(StripLayout.dragged(from: start, by: -900, limit: limit) == -300)
        #expect(StripLayout.dragged(from: start, by: 900, limit: limit) == 300)
        // A press that has not moved leaves it exactly where it was.
        #expect(StripLayout.dragged(from: start, by: 0, limit: limit) == start)
    }

    @Test func theThresholdIsSmallEnoughToFeelImmediateAndBigEnoughToSurviveAClick() {
        #expect(StripLayout.dragThreshold == 4)
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

    @Test func nearTheTopItGrowsDownwards() {
        // Dragged 200pt up: its top edge is 100pt from the top of the screen.
        let placed = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: -200)
        // The top edge stays at 100; the middle is then 100 + 250 = 350, which is 100 above the
        // screen's middle. Nothing is cut off the top.
        #expect(placed.offset == -100)
        #expect(placed.offset - placed.height / 2 + available / 2 >= 0)
    }

    @Test func nearTheBottomItGrowsUpwards() {
        let placed = StripLayout.place(contentHeight: full, restHeight: rest, available: available, offset: 200)
        #expect(placed.offset == 100)
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

    @Test func aTinyScreenShowsOneSessionAndCountsTheRest() {
        #expect(StripLayout.visible(count: 5, capacity: 1) == (1, 4))
    }
}
