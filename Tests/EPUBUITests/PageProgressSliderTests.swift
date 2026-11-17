import CoreGraphics
import EPUBCore
import Testing
@testable import EPUBUI

/// `PageProgressSlider` (docs/design/03-api.md §4.7): the slider as a reader of any format uses it, with page numbers
/// in place of a `ReaderSession` and reading positions, and what `ReaderProgressSlider` hands it for an EPUB.
@Suite @MainActor struct PageProgressSliderTests {
    typealias Slider = PageProgressSlider

    let geometry = ProgressSliderGeometry(totalPages: 101, width: 220, inset: 10, isRightToLeft: false)

    private func mark(_ id: String, page: Int?) -> Slider.Mark {
        Slider.Mark(id: id, page: page, label: "Previous position")
    }

    // MARK: Marks

    @Test func marksAreDrawnAtTheirPages() {
        let placed = Slider.placedMarks([mark("a", page: 0), mark("b", page: 50), mark("c", page: 100)], in: geometry)
        #expect(placed.map(\.x) == [10, 110, 210])
        #expect(placed.map(\.page) == [0, 50, 100])
        #expect(placed.map(\.mark.id) == ["a", "b", "c"])
    }

    @Test func aMarkWithoutAPageIsNotDrawnAndKeepsTheOthersIndices() {
        // The index is the accessibility identifier (`ReaderProgressSliderMark-<index>`): a mark whose page is not
        // known (an EPUB position outside the reading order) must not renumber the marks after it
        let placed = Slider.placedMarks([mark("a", page: nil), mark("b", page: 50), mark("c", page: nil), mark("d", page: 7)], in: geometry)
        #expect(placed.map(\.mark.id) == ["b", "d"])
        #expect(placed.map(\.index) == [1, 3])
    }

    @Test func aBookWithoutPagesDrawsNoMarks() {
        let empty = ProgressSliderGeometry(totalPages: 0, width: 220, inset: 10, isRightToLeft: false)
        #expect(Slider.placedMarks([mark("a", page: 0)], in: empty).isEmpty)
    }

    @Test func marksOfARightBoundBookAreMirrored() {
        var rightBound = geometry
        rightBound.isRightToLeft = true
        #expect(Slider.placedMarks([mark("a", page: 0), mark("b", page: 100)], in: rightBound).map(\.x) == [210, 10])
    }

    @Test func aMarkOutsideTheBookIsDrawnAtTheNearestEnd() {
        // Page counts are estimates while a book is being measured: a mark can be a page past the end for a moment
        #expect(Slider.placedMarks([mark("a", page: 400)], in: geometry).map(\.x) == [210])
    }

    // MARK: The label of a page

    @Test func aPageIsDescribedByItsTitleAndThePartOfTheBook() {
        #expect(Slider.description(title: "Chapter 3", progression: 0.42, separator: " · ") == "Chapter 3 · 42%")
        #expect(Slider.description(title: "Chapter 3", progression: 1, separator: ", ") == "Chapter 3, 100%")
    }

    /// The app's `pageTitle` is asked only about pages the book has: a mark past the end, or the target of a move
    /// that was started before the book got shorter, is described as the page it is drawn at.
    @Test func aPageOutsideTheBookIsTitledAsTheNearestPage() {
        #expect(Slider.titledPage(4, totalPages: 20) == 4)
        #expect(Slider.titledPage(0, totalPages: 20) == 0)
        #expect(Slider.titledPage(19, totalPages: 20) == 19)
        #expect(Slider.titledPage(90, totalPages: 20) == 19)
        #expect(Slider.titledPage(-3, totalPages: 20) == 0)
        #expect(Slider.titledPage(0, totalPages: 0) == nil)
        #expect(Slider.titledPage(5, totalPages: -1) == nil)
    }

    @Test func aPageWithoutATitleIsDescribedByThePartAlone() {
        #expect(Slider.description(title: nil, progression: 0.42, separator: " · ") == "42%")
        #expect(Slider.description(title: "", progression: 0.42, separator: " · ") == "42%")
    }

    // MARK: Steps

    @Test func aStepStartsFromEveryVisiblePage() throws {
        // Both pages of a spread: forward from the second, backward from the first
        #expect(Slider.stepOrigin(settlingPage: nil, visible: [4, 5]) == 4...5)
        #expect(Slider.stepOrigin(settlingPage: nil, visible: [4]) == 4...4)
        let book = ProgressSliderGeometry(totalPages: 10, width: 220, inset: 10, isRightToLeft: false)
        let origin = try #require(Slider.stepOrigin(settlingPage: nil, visible: [4, 5]))
        #expect(book.page(steppingFrom: origin, by: 1) == 6)
        #expect(book.page(steppingFrom: origin, by: -1) == 3)
    }

    @Test func aStepDuringAMoveStartsFromWhereTheMoveIsHeading() {
        #expect(Slider.stepOrigin(settlingPage: 9, visible: [4, 5]) == 9...9)
        #expect(Slider.stepOrigin(settlingPage: 9, visible: []) == 9...9)
    }

    @Test func nothingShownMeansNowhereToStepFrom() {
        #expect(Slider.stepOrigin(settlingPage: nil, visible: []) == nil)
        // Pages out of order are not a range (never handed over by a reader, and must not trap)
        #expect(Slider.stepOrigin(settlingPage: nil, visible: [5, 4]) == nil)
    }

    // MARK: The EPUB slider on top of it

    private func position(_ offset: Int) -> ReadingPosition {
        ReadingPosition(cfi: CFI("epubcfi(/6/4!/4/2/1:\(offset))")!, spineIndex: 1)
    }

    @Test func aReleaseOnAPageIsAPageOfTheSession() {
        #expect(ReaderProgressSlider.destination(for: .page(12), among: []) == .page(12))
    }

    @Test func aReleaseOnAMarkIsThatMarksPosition() {
        let marks = [
            ReaderProgressSlider.Mark(id: "first", position: position(3), label: "Previous position"),
            ReaderProgressSlider.Mark(id: "second", position: position(40), label: "Previous position"),
        ]
        #expect(ReaderProgressSlider.destination(for: .mark(id: "second"), among: marks) == .mark(marks[1]))
        #expect(ReaderProgressSlider.destination(for: .mark(id: "first"), among: marks) == .mark(marks[0]))
    }

    @Test func aMarkThatIsGoneGoesNowhere() {
        let marks = [ReaderProgressSlider.Mark(id: "first", position: position(3), label: "Previous position")]
        #expect(ReaderProgressSlider.destination(for: .mark(id: "gone"), among: marks) == nil)
    }
}
