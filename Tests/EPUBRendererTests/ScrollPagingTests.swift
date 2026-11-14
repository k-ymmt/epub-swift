import Foundation
import Testing
import EPUBCore
@testable import EPUBRenderer

/// Virtual pages of the scrolled layout (docs/design/08-continuous-scroll.md §6.1), which books are scrolled (§1),
/// and when the reader's hands count as scrolling (§5.6): the parts that need no web view.
@Suite struct ScrollPagingTests {
    // MARK: Pages

    @Test func thePageHeightIsTheFrameInsideTheInsets() {
        #expect(ScrollPaging.pageHeight(viewportHeight: 800, insets: ReaderInsets(top: 60, bottom: 40)) == 700)
        #expect(ScrollPaging.pageHeight(viewportHeight: 800, insets: ReaderInsets()) == 800)
        // Insets larger than the frame never make a page of zero or negative height.
        #expect(ScrollPaging.pageHeight(viewportHeight: 50, insets: ReaderInsets(top: 60, bottom: 40)) == 1)
        // Negative and non-finite insets are no insets.
        #expect(ReaderInsets(top: -5, bottom: .nan) == ReaderInsets())
    }

    @Test func aChapterHasItsHeightInPagesRoundedUp() {
        #expect(ScrollPaging.pageCount(height: 1400, pageHeight: 700) == 2)
        #expect(ScrollPaging.pageCount(height: 1401, pageHeight: 700) == 3)
        #expect(ScrollPaging.pageCount(height: 30, pageHeight: 700) == 1)
        #expect(ScrollPaging.pageCount(height: 0, pageHeight: 700) == 1)
        // A sub-pixel overshoot of the layout is not another page.
        #expect(ScrollPaging.pageCount(height: 1400.3, pageHeight: 700) == 2)
    }

    @Test func pageJCoversTheDistancesFromJPToTheNextPage() {
        #expect(ScrollPaging.pageIndex(offset: 0, height: 2000, pageHeight: 700) == 0)
        #expect(ScrollPaging.pageIndex(offset: 699, height: 2000, pageHeight: 700) == 0)
        #expect(ScrollPaging.pageIndex(offset: 700, height: 2000, pageHeight: 700) == 1)
        #expect(ScrollPaging.pageIndex(offset: 1999, height: 2000, pageHeight: 700) == 2)
        // The line never counts as a page the chapter does not have.
        #expect(ScrollPaging.pageIndex(offset: 5000, height: 2000, pageHeight: 700) == 2)
        #expect(ScrollPaging.pageIndex(offset: -20, height: 2000, pageHeight: 700) == 0)
        // `go(toPage:)` puts the top of a page on the reading line, and that reads back as the same page.
        for page in 0..<3 {
            let offset = ScrollPaging.offset(ofPage: page, pageHeight: 700)
            #expect(ScrollPaging.pageIndex(offset: offset, height: 2000, pageHeight: 700) == page)
        }
    }

    @Test func atTheEndOfTheBookThePositionIsTheLastPage() {
        // The last chapter is 2000 tall and the page 700: at the very end the reading line is 1300 below the
        // chapter's top, on page 1; page 2 never reaches the line.
        #expect(ScrollPaging.place(offset: 1300, chapterHeight: 2000, pageHeight: 700, isAtEnd: false) == ScrollPaging.Place(pageIndex: 1, chapterPageCount: 3))
        #expect(ScrollPaging.place(offset: 1300, chapterHeight: 2000, pageHeight: 700, isAtEnd: true) == ScrollPaging.Place(pageIndex: 2, chapterPageCount: 3))
    }

    /// Three linear chapters of 3, 1 and 2 pages (spine 0, 1, 2).
    func pagination() -> BookPagination {
        BookPagination(chapters: [
            .init(spineIndex: 0, pageCount: 3, isEstimated: false, firstPage: 0),
            .init(spineIndex: 1, pageCount: 1, isEstimated: false, firstPage: 3),
            .init(spineIndex: 2, pageCount: 2, isEstimated: true, firstPage: 4),
        ], charactersPerPage: 600)
    }

    @Test func theBookPageAndTheProgressionReachTheEndWhateverChapterTheLineIsIn() {
        let pagination = pagination()
        #expect(ScrollPaging.currentPage(pagination: pagination, spineIndex: 0, pageIndex: 1, isAtEnd: false) == 1)
        #expect(ScrollPaging.currentPage(pagination: pagination, spineIndex: 2, pageIndex: 0, isAtEnd: false) == 4)
        // The last chapter is shorter than the frame: at the end of the book the line is still in the chapter
        // before it, and the position is the book's last page all the same.
        #expect(ScrollPaging.currentPage(pagination: pagination, spineIndex: 1, pageIndex: 0, isAtEnd: true) == 5)
        #expect(ScrollPaging.totalProgression(pagination: pagination, spineIndex: 1, pageIndex: 0, isAtEnd: true) == 1)
        // Anywhere else it is the pagination's own value, as in the paged layout.
        #expect(ScrollPaging.totalProgression(pagination: pagination, spineIndex: 0, pageIndex: 1, isAtEnd: false) == pagination.progression(spineIndex: 0, pageIndex: 1))
        // A non-linear item has no book page.
        #expect(ScrollPaging.currentPage(pagination: pagination, spineIndex: 9, pageIndex: 0, isAtEnd: true) == nil)
    }

    @Test func theVisiblePagesAreTheOnesInThePageBelowTheLine() {
        let pagination = pagination()
        // Chapter 0 is 2000 tall (pages of 700). The line 350 below its top: pages 0 and 1 are in the band.
        #expect(ScrollPaging.visiblePages(pagination: pagination, spineIndex: 0, offset: 350, chapterHeight: 2000, pageHeight: 700, visibleSpineIndices: [0], isAtEnd: false) == [0, 1])
        // Exactly at a page top: that page alone.
        #expect(ScrollPaging.visiblePages(pagination: pagination, spineIndex: 0, offset: 700, chapterHeight: 2000, pageHeight: 700, visibleSpineIndices: [0], isAtEnd: false) == [1])
        // The band runs past the chapter's end: the next visible chapter starts in it.
        #expect(ScrollPaging.visiblePages(pagination: pagination, spineIndex: 0, offset: 1700, chapterHeight: 2000, pageHeight: 700, visibleSpineIndices: [0, 1], isAtEnd: false) == [2, 3])
        // At the end of the book: the last page.
        #expect(ScrollPaging.visiblePages(pagination: pagination, spineIndex: 1, offset: 100, chapterHeight: 500, pageHeight: 700, visibleSpineIndices: [1, 2], isAtEnd: true) == [5])
    }

    @Test func unmeasuredChaptersAreAsTallAsTheirEstimatedPages() {
        let pagination = pagination()
        let heights = ScrollPaging.heights(spineIndices: [0, 1, 2], measured: [0: 1950.5], pagination: pagination, pageHeight: 700)
        #expect(heights == [1950.5, 700, 1400])
        #expect(ScrollPaging.measuredPageCounts(heights: [0: 1950.5, 2: 90], pageHeight: 700) == [0: 3, 2: 1])
    }

    // MARK: Which books scroll

    @Test func onlyHorizontalReflowableBooksAreScrolled() {
        #expect(ScrollEligibility.allowsScrolling(pageProgression: .ltr, hasFixedLayoutItem: false))
        #expect(ScrollEligibility.allowsScrolling(pageProgression: .default, hasFixedLayoutItem: false))
        #expect(!ScrollEligibility.allowsScrolling(pageProgression: .rtl, hasFixedLayoutItem: false))
        #expect(!ScrollEligibility.allowsScrolling(pageProgression: .ltr, hasFixedLayoutItem: true))
    }

    // MARK: Scroll view flags (iOS)

    @Test func aFingerOrMomentumIsAnInteraction() {
        #expect(!ScrollViewInteraction.isActive(isTracking: false, isDragging: false, isDecelerating: false))
        // A finger resting on the screen (tracking, not moving) is not "at rest".
        #expect(ScrollViewInteraction.isActive(isTracking: true, isDragging: false, isDecelerating: false))
        #expect(ScrollViewInteraction.isActive(isTracking: false, isDragging: true, isDecelerating: false))
        #expect(ScrollViewInteraction.isActive(isTracking: false, isDragging: false, isDecelerating: true))
    }
}

/// The phases of scroll-wheel events on macOS as an interaction (docs/design/08-continuous-scroll.md §5.6).
@Suite struct WheelInteractionTests {
    typealias Event = WheelInteraction.Event

    /// The state behind a reference, so the calls that change it can stand inside `#expect`.
    final class Wheel {
        var state = WheelInteraction()
        func handle(_ event: Event) -> Bool { state.handle(event) }
        @discardableResult func stop(at time: TimeInterval) -> Bool { state.stop(at: time) }
        func isActive(at time: TimeInterval) -> Bool { state.isActive(at: time) }
        func deadline(after time: TimeInterval) -> TimeInterval? { state.deadline(after: time) }
    }

    @Test func aTrackpadGestureIsActiveFromItsStartThroughItsMomentum() {
        let wheel = Wheel()
        #expect(!wheel.isActive(at: 0))
        #expect(wheel.handle(Event(phase: .began, time: 1.00)))
        #expect(wheel.isActive(at: 1.00))
        #expect(wheel.handle(Event(phase: .changed, time: 1.05)))
        // Fingers resting on the trackpad send nothing for a long time: still the reader's.
        #expect(wheel.isActive(at: 9.00))
        #expect(wheel.handle(Event(phase: .ended, time: 9.10)))
        // The momentum starts a moment after the fingers lift; the gap is not rest.
        #expect(wheel.isActive(at: 9.15))
        #expect(wheel.handle(Event(momentumPhase: .began, time: 9.16)))
        #expect(wheel.handle(Event(momentumPhase: .changed, time: 9.50)))
        #expect(wheel.isActive(at: 20))
        #expect(wheel.handle(Event(momentumPhase: .ended, time: 10.2)))
        #expect(!wheel.isActive(at: 10.2))
    }

    @Test func aGestureWithoutMomentumEndsAfterTheGrace() {
        let wheel = Wheel()
        _ = wheel.handle(Event(phase: .began, time: 1))
        _ = wheel.handle(Event(phase: .ended, time: 2))
        #expect(wheel.isActive(at: 2.05))
        #expect(wheel.deadline(after: 2.05) == 2 + WheelInteraction.momentumGrace)
        #expect(!wheel.isActive(at: 2.11))
        #expect(wheel.deadline(after: 2.2) == nil)
    }

    @Test func aWheelWithoutPhasesIsActiveUntilItHasBeenQuiet() {
        let wheel = Wheel()
        #expect(wheel.handle(Event(time: 5.00)))
        #expect(wheel.isActive(at: 5.10))
        #expect(wheel.handle(Event(time: 5.10)))
        #expect(wheel.isActive(at: 5.24))
        #expect(!wheel.isActive(at: 5.26))
        #expect(wheel.deadline(after: 5.11) == 5.10 + WheelInteraction.phaselessTail)
    }

    @Test func stoppingWithholdsTheRestOfTheGestureAndItsMomentum() {
        let wheel = Wheel()
        _ = wheel.handle(Event(phase: .began, time: 1.0))
        _ = wheel.handle(Event(phase: .changed, time: 1.1))
        #expect(wheel.stop(at: 1.2))
        #expect(!wheel.isActive(at: 1.2), "the position may be written now")
        // The fingers keep moving: the web view does not hear of it.
        #expect(!wheel.handle(Event(phase: .changed, time: 1.3)))
        #expect(!wheel.isActive(at: 1.3))
        // The closing event is passed on, so the web view sees the gesture end.
        #expect(wheel.handle(Event(phase: .ended, time: 1.4)))
        // Its momentum is withheld too, up to the event that ends it.
        #expect(!wheel.handle(Event(momentumPhase: .began, time: 1.45)))
        #expect(!wheel.handle(Event(momentumPhase: .changed, time: 1.6)))
        #expect(!wheel.isActive(at: 1.6))
        #expect(wheel.handle(Event(momentumPhase: .ended, time: 2.0)))
        // The next gesture is the reader's again.
        #expect(wheel.handle(Event(phase: .began, time: 3.0)))
        #expect(wheel.handle(Event(phase: .changed, time: 3.1)))
        #expect(wheel.isActive(at: 3.1))
    }

    @Test func stoppingDuringMomentumWithholdsWhatIsLeftOfIt() {
        let wheel = Wheel()
        _ = wheel.handle(Event(phase: .began, time: 1.0))
        _ = wheel.handle(Event(phase: .ended, time: 1.2))
        _ = wheel.handle(Event(momentumPhase: .began, time: 1.25))
        #expect(wheel.stop(at: 1.5))
        #expect(!wheel.handle(Event(momentumPhase: .changed, time: 1.6)))
        #expect(wheel.handle(Event(momentumPhase: .ended, time: 1.9)))
        #expect(!wheel.isActive(at: 1.9))
        #expect(wheel.handle(Event(time: 2.5)), "nothing is withheld after the momentum ended")
    }

    @Test func aStoppedGestureWithoutMomentumStopsWithholdingAfterTheGrace() {
        let wheel = Wheel()
        _ = wheel.handle(Event(phase: .began, time: 1.0))
        wheel.stop(at: 1.1)
        _ = wheel.handle(Event(phase: .ended, time: 1.2))
        // No momentum follows. A mouse wheel right after is withheld only during the grace.
        #expect(!wheel.handle(Event(time: 1.25)))
        #expect(wheel.handle(Event(time: 1.2 + WheelInteraction.momentumGrace + 0.01)))
        #expect(wheel.isActive(at: 1.35))
    }

    @Test func stoppingAPhaselessWheelWithholdsItsTail() {
        let wheel = Wheel()
        _ = wheel.handle(Event(time: 1.00))
        #expect(wheel.stop(at: 1.05))
        #expect(!wheel.isActive(at: 1.05))
        #expect(!wheel.handle(Event(time: 1.10)), "the notches still arriving belong to the scroll that was stopped")
        #expect(wheel.handle(Event(time: 1.00 + WheelInteraction.phaselessTail + 0.01)))
    }

    @Test func stoppingWhenNothingIsInProgressDoesNothing() {
        let wheel = Wheel()
        #expect(!wheel.stop(at: 1))
        #expect(wheel.handle(Event(phase: .began, time: 2)))
        #expect(wheel.isActive(at: 2))
    }
}
