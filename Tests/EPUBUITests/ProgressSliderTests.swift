import CoreGraphics
import Testing
@testable import EPUBUI

/// The arithmetic of `ReaderProgressSlider` (docs/design/03-api.md §4.6): pages along the track, and what one press
/// (drag, tap on a mark, tap on the track) does on release.
@Suite struct ProgressSliderTests {
    let geometry = ProgressSliderGeometry(totalPages: 101, width: 220, inset: 10, isRightToLeft: false)
    var rightBound: ProgressSliderGeometry {
        var g = geometry
        g.isRightToLeft = true
        return g
    }

    @Test func pagesRunFromOneInsetEdgeToTheOther() {
        #expect(geometry.x(ofPage: 0) == 10)
        #expect(geometry.x(ofPage: 100) == 210)
        #expect(geometry.x(ofPage: 50) == 110)
        #expect(geometry.page(atX: 10) == 0)
        #expect(geometry.page(atX: 110) == 50)
        #expect(geometry.page(atX: 111) == 51)
        // Outside the track and outside the book: clamped
        #expect(geometry.page(atX: -40) == 0)
        #expect(geometry.page(atX: 900) == 100)
        #expect(geometry.x(ofPage: 400) == 210)
        #expect(geometry.x(ofPage: -3) == 10)
    }

    @Test func aRightBoundBookStartsAtTheRightEdge() {
        #expect(rightBound.x(ofPage: 0) == 210)
        #expect(rightBound.x(ofPage: 100) == 10)
        #expect(rightBound.page(atX: 210) == 0)
        #expect(rightBound.page(atX: 60) == 75)
        for page in [0, 1, 37, 99, 100] {
            #expect(rightBound.page(atX: rightBound.x(ofPage: page)) == page)
            #expect(geometry.page(atX: geometry.x(ofPage: page)) == page)
        }
    }

    @Test func progressionIsThePartOfTheBookThePageEndsAt() {
        #expect(geometry.progression(ofPage: 100) == 1)
        #expect(abs(geometry.progression(ofPage: 0) - 1.0 / 101) < 1e-9)
        #expect(ProgressSliderGeometry(totalPages: 0, width: 100, inset: 10, isRightToLeft: false).progression(ofPage: 0) == 0)
    }

    @Test func aBookOfOnePageOrATrackWithoutRoomHasOnePlace() {
        let single = ProgressSliderGeometry(totalPages: 1, width: 220, inset: 10, isRightToLeft: false)
        #expect(single.x(ofPage: 0) == 10)
        #expect(single.page(atX: 150) == 0)
        let narrow = ProgressSliderGeometry(totalPages: 50, width: 12, inset: 10, isRightToLeft: false)
        #expect(narrow.page(atX: 6) == 0)
    }

    // MARK: One press

    private func press(from start: CGFloat, to end: CGFloat? = nil, current: Int? = 50, marks: [CGFloat] = [], in geometry: ProgressSliderGeometry? = nil)
        -> (outcome: ProgressSliderInteraction.Outcome, dragged: Bool, pending: Int?)
    {
        let geometry = geometry ?? self.geometry
        var interaction = ProgressSliderInteraction()
        interaction.began(at: start, thumbX: current.map { geometry.x(ofPage: $0) }, thumbReach: 12)
        interaction.moved(to: start, geometry: geometry)
        if let end { interaction.moved(to: end, geometry: geometry) }
        let dragged = interaction.isDragging
        let pending = interaction.pendingPage
        let outcome = interaction.ended(at: end ?? start, geometry: geometry, currentPage: current, markXs: marks, markReach: 10)
        #expect(!interaction.isActive)
        return (outcome, dragged, pending)
    }

    @Test func draggingTheThumbMovesOnReleaseAndKeepsTheGrabOffset() {
        // Grabbed 6 pt right of the thumb's centre (page 50 at 110), released 40 pt further: the thumb moved 40 pt
        let result = press(from: 116, to: 156)
        #expect(result.dragged)
        #expect(result.pending == 70)
        #expect(result.outcome == .page(70))
    }

    @Test func aDragThatReturnsToThePageGoesNowhere() {
        var interaction = ProgressSliderInteraction()
        interaction.began(at: 110, thumbX: 110, thumbReach: 12)
        interaction.moved(to: 150, geometry: geometry)
        #expect(interaction.pendingPage == 70)
        interaction.moved(to: 110, geometry: geometry)
        #expect(interaction.pendingPage == 50, "still a drag: the label follows back")
        #expect(interaction.ended(at: 110, geometry: geometry, currentPage: 50, markXs: [], markReach: 10) == .none)
    }

    @Test func aPressAwayFromTheThumbBringsItUnderTheFingerOnceItMoves() {
        let result = press(from: 30, to: 40)
        #expect(result.dragged)
        #expect(result.outcome == .page(15))
    }

    @Test func aTapOnTheTrackGoesThereAndATapOnTheThumbDoesNothing() {
        #expect(press(from: 170).outcome == .page(80))
        #expect(press(from: 170, to: 172).outcome == .page(80), "movement within the slop is still a tap, at the start point")
        #expect(press(from: 114).outcome == .none)
        #expect(press(from: 110, current: 50).dragged == false)
        // No page shown (a non-linear item): nothing to grab, a tap still goes there
        #expect(press(from: 110, current: nil).outcome == .page(50))
    }

    @Test func aTapNearAMarkTakesTheMark() {
        #expect(press(from: 176, marks: [40, 170]).outcome == .mark(1))
        #expect(press(from: 181, marks: [40, 170]).outcome == .page(86), "out of the mark's reach: the track")
        // Two marks in reach: the nearer; at the same distance the later one
        #expect(press(from: 44, marks: [40, 50]).outcome == .mark(0))
        #expect(press(from: 45, marks: [40, 50]).outcome == .mark(1))
    }

    @Test func aTapBetweenTheThumbAndAMarkTakesTheNearerOne() {
        // Thumb at 110, mark at 122
        #expect(press(from: 118, marks: [122]).outcome == .mark(0))
        #expect(press(from: 113, marks: [122]).outcome == .none)
        // A drag that starts on a mark is a drag
        #expect(press(from: 170, to: 190, marks: [170]).outcome == .page(90))
    }

    @Test func aCancelledPressLeavesNothingBehind() {
        var interaction = ProgressSliderInteraction()
        interaction.began(at: 110, thumbX: 110, thumbReach: 12)
        interaction.moved(to: 190, geometry: geometry)
        interaction.cancelled()
        #expect(!interaction.isActive)
        #expect(interaction.pendingPage == nil)
        #expect(interaction.ended(at: 190, geometry: geometry, currentPage: 50, markXs: [], markReach: 10) == .none)
    }

    @Test func aRightBoundDragRunsTheOtherWay() {
        // Page 50 is at 110 either way; dragging left reads forward
        let result = press(from: 110, to: 70, in: rightBound)
        #expect(result.outcome == .page(70))
    }
}
