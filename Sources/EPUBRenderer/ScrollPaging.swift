import Foundation
import EPUBCore

/// Top and bottom insets of the reader's frame, in points (docs/design/08-continuous-scroll.md §3.2): what bars and
/// safe areas cover. The scrolled layout lets the text run under them and counts the reading line, the restored
/// position and the page height inside them. The paged layout does not use them.
public struct ReaderInsets: Hashable, Sendable {
    public var top: Double
    public var bottom: Double

    public init(top: Double = 0, bottom: Double = 0) {
        self.top = max(0, top.isFinite ? top : 0)
        self.bottom = max(0, bottom.isFinite ? bottom : 0)
    }
}

/// Which layout a book is shown in (08-continuous-scroll §1).
enum ScrollEligibility {
    /// The scrolled layout applies to a book without fixed-layout items whose pages do not progress right to left.
    /// Vertical writing is only known once a chapter has loaded (`sawVerticalChapter`); the session then stays paged.
    static func layout(requested: ReaderLayout, publication: Publication, sawVerticalChapter: Bool) -> ReaderLayout {
        guard requested == .scrolled, !sawVerticalChapter else { return .paged }
        return allowsScrolling(pageProgression: publication.pageProgression, hasFixedLayoutItem: publication.readingOrder.contains(where: \.isFixedLayout))
            ? .scrolled : .paged
    }

    static func allowsScrolling(pageProgression: PageProgression, hasFixedLayoutItem: Bool) -> Bool {
        !hasFixedLayoutItem && pageProgression != .rtl
    }
}

/// Virtual pages of the scrolled layout (08-continuous-scroll §6.1): one page is the page height P (the viewport
/// minus the insets); a chapter `h` tall has `max(1, ceil(h / P))` pages and its page `j` covers the distances
/// `[jP, (j+1)P)` from the chapter's top.
enum ScrollPaging {
    /// P for a viewport and insets; never below 1 so that divisions stay defined.
    static func pageHeight(viewportHeight: Double, insets: ReaderInsets) -> Double {
        max(1, viewportHeight - insets.top - insets.bottom)
    }

    static func pageCount(height: Double, pageHeight: Double) -> Int {
        guard pageHeight > 0, height.isFinite, height > 0 else { return 1 }
        // A height a hair above a whole number of pages (sub-pixel rounding) is that number of pages.
        return max(1, Int(((height - 0.5) / pageHeight).rounded(.up)))
    }

    /// The page the reading line is on, `offset` below the chapter's top.
    static func pageIndex(offset: Double, height: Double, pageHeight: Double) -> Int {
        guard pageHeight > 0, offset.isFinite else { return 0 }
        let count = pageCount(height: height, pageHeight: pageHeight)
        return min(count - 1, max(0, Int(((offset + 0.5) / pageHeight).rounded(.down))))
    }

    /// Distance from the chapter's top to the top of page `index` (what `go(toPage:)` puts on the reading line).
    static func offset(ofPage index: Int, pageHeight: Double) -> Double {
        Double(max(0, index)) * pageHeight
    }

    /// Where the reader is, in pages. At the very end of the book the reading line stops one page above the last
    /// chapter's end, so the pages after it never reach the line: there the position counts as the last page (§6.1).
    struct Place: Equatable {
        /// Page within the chapter at the reading line.
        var pageIndex: Int
        var chapterPageCount: Int
    }

    static func place(offset: Double, chapterHeight: Double, pageHeight: Double, isAtEnd: Bool) -> Place {
        let count = pageCount(height: chapterHeight, pageHeight: pageHeight)
        let index = isAtEnd ? count - 1 : pageIndex(offset: offset, height: chapterHeight, pageHeight: pageHeight)
        return Place(pageIndex: index, chapterPageCount: count)
    }

    /// Book page of the reading line: the last page of the book at its end, whatever chapter the line is in.
    static func currentPage(pagination: BookPagination, spineIndex: Int, pageIndex: Int, isAtEnd: Bool) -> Int? {
        guard let page = pagination.pageIndex(spineIndex: spineIndex, pageIndex: pageIndex) else { return nil }
        return isAtEnd && pagination.totalPages > 0 ? pagination.totalPages - 1 : page
    }

    /// Fraction of the book read: 1 at the end.
    static func totalProgression(pagination: BookPagination, spineIndex: Int, pageIndex: Int, isAtEnd: Bool) -> Double? {
        guard let progression = pagination.progression(spineIndex: spineIndex, pageIndex: pageIndex) else { return nil }
        return isAtEnd ? 1 : progression
    }

    /// How far the page-high band below the reading line reaches in its chapter: `visiblePages` changes when this
    /// does (or the chapter, or the pagination), not with every pixel of the offset.
    struct Band: Equatable {
        /// First and last page of the chapter with a part in the band.
        var firstPage = 0
        var lastPage = 0
        /// The band reaches past the chapter's end, into the chapters after it.
        var reachesNextChapter = false
        var isAtEnd = false
    }

    static func band(offset: Double, chapterHeight: Double, pageHeight: Double, isAtEnd: Bool) -> Band {
        let place = place(offset: offset, chapterHeight: chapterHeight, pageHeight: pageHeight, isAtEnd: isAtEnd)
        let bandEnd = offset + pageHeight
        let first = pageIndex(offset: offset, height: chapterHeight, pageHeight: pageHeight)
        var last = first
        while last + 1 < place.chapterPageCount, Double(last + 1) * pageHeight < bandEnd - 0.5 { last += 1 }
        return Band(firstPage: first, lastPage: last, reachesNextChapter: chapterHeight < bandEnd - 0.5, isAtEnd: isAtEnd)
    }

    /// Book pages with a part inside the page-high band that starts at the reading line: the page of the line and,
    /// unless the line is exactly at a page top, the next one (in this chapter or the first page of the next visible
    /// one). Ascending.
    static func visiblePages(pagination: BookPagination, spineIndex: Int, offset: Double, chapterHeight: Double, pageHeight: Double, visibleSpineIndices: [Int], isAtEnd: Bool) -> [Int] {
        let place = place(offset: offset, chapterHeight: chapterHeight, pageHeight: pageHeight, isAtEnd: isAtEnd)
        guard let current = currentPage(pagination: pagination, spineIndex: spineIndex, pageIndex: place.pageIndex, isAtEnd: isAtEnd) else { return [] }
        var pages: Set<Int> = [current]
        guard !isAtEnd else { return [current] }
        let bandEnd = offset + pageHeight
        let first = pageIndex(offset: offset, height: chapterHeight, pageHeight: pageHeight)
        var index = first + 1
        while index < place.chapterPageCount, Double(index) * pageHeight < bandEnd - 0.5 {
            if let page = pagination.pageIndex(spineIndex: spineIndex, pageIndex: index) { pages.insert(page) }
            index += 1
        }
        if chapterHeight < bandEnd - 0.5 {
            // The band reaches past the chapter's end: the following visible chapters start in it.
            for next in visibleSpineIndices where next > spineIndex {
                if let page = pagination.pageIndex(spineIndex: next, pageIndex: 0) { pages.insert(page) }
            }
        }
        return pages.sorted()
    }

    /// Heights of the chapters of a scroll document, in its order, for the blocks that stand in for the chapters
    /// outside the window (§5.2): the measured height where there is one, else the estimated page count times P.
    static func heights(spineIndices: [Int], measured: [Int: Double], pagination: BookPagination, pageHeight: Double) -> [Double] {
        spineIndices.map { index in
            if let height = measured[index], height > 0 { return height }
            return Double(max(1, pagination.chapter(spineIndex: index)?.pageCount ?? 1)) * pageHeight
        }
    }

    /// Page counts for `BookPagination.make` from the heights the display web view measured.
    static func measuredPageCounts(heights: [Int: Double], pageHeight: Double) -> [Int: Int] {
        heights.mapValues { pageCount(height: $0, pageHeight: pageHeight) }
    }
}
