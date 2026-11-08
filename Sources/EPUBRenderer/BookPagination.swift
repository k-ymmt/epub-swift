import Foundation
import EPUBCore

/// Page numbering across the whole book (docs/design/02-rendering.md §5.2, 03-api §3.3).
///
/// Linear spine items get consecutive page ranges. A chapter's page count is either *measured* (laid out by the
/// display web view or the pre-pagination service for the current layout) or *estimated* from its
/// `SpineItem.characterCount` and the characters-per-page ratio of the measured chapters. All page indices here are
/// 0-based; show `index + 1` to readers.
public struct BookPagination: Sendable, Hashable {
    public struct Chapter: Sendable, Hashable {
        public let spineIndex: Int
        public let pageCount: Int
        public let isEstimated: Bool
        /// Book page index of the chapter's first page.
        public let firstPage: Int

        public var pageRange: Range<Int> { firstPage..<(firstPage + pageCount) }
    }

    /// A page located in the spine.
    public struct Location: Sendable, Hashable {
        public let spineIndex: Int
        /// Page index within the chapter.
        public let pageIndex: Int

        public init(spineIndex: Int, pageIndex: Int) {
            self.spineIndex = spineIndex
            self.pageIndex = pageIndex
        }
    }

    /// Linear chapters in spine order.
    public let chapters: [Chapter]
    public let totalPages: Int
    /// Characters per page used for the estimates (the measured ratio, or the default before any chapter is measured).
    public let charactersPerPage: Double

    /// `false` only when every linear chapter has been measured.
    public var isEstimated: Bool { chapters.contains { $0.isEstimated } }

    /// Number of linear chapters still estimated.
    public var estimatedChapterCount: Int { chapters.filter(\.isEstimated).count }

    private let bySpineIndex: [Int: Int]

    public init(chapters: [Chapter], charactersPerPage: Double) {
        self.chapters = chapters
        self.charactersPerPage = charactersPerPage
        self.totalPages = chapters.last.map { $0.firstPage + $0.pageCount } ?? 0
        var map: [Int: Int] = [:]
        for (i, chapter) in chapters.enumerated() { map[chapter.spineIndex] = i }
        self.bySpineIndex = map
    }

    /// The default ratio before any chapter has been measured (02-rendering §5.2: 600 characters per horizontal page).
    public static func defaultCharactersPerPage(writingMode: WritingMode) -> Double {
        writingMode.isVertical ? 500 : 600
    }

    /// Builds the numbering from the measured chapter page counts (`spineIndex → pageCount`).
    public static func make(publication: Publication, measured: [Int: Int], defaultCharactersPerPage: Double = 600) -> BookPagination {
        let linear = publication.linearReadingOrder
        var measuredCharacters = 0
        var measuredPages = 0
        for item in linear {
            if let pages = measured[item.index], let characters = item.characterCount, pages > 0 {
                measuredCharacters += characters
                measuredPages += pages
            }
        }
        let ratio: Double = measuredPages > 0 && measuredCharacters > 0
            ? Double(measuredCharacters) / Double(measuredPages)
            : max(1, defaultCharactersPerPage)

        var chapters: [Chapter] = []
        chapters.reserveCapacity(linear.count)
        var next = 0
        for item in linear {
            let count: Int
            let estimated: Bool
            if let pages = measured[item.index], pages > 0 {
                count = pages
                estimated = false
            } else {
                count = max(1, Int((Double(item.characterCount ?? 0) / ratio).rounded(.up)))
                estimated = true
            }
            chapters.append(Chapter(spineIndex: item.index, pageCount: count, isEstimated: estimated, firstPage: next))
            next += count
        }
        return BookPagination(chapters: chapters, charactersPerPage: ratio)
    }

    public static let empty = BookPagination(chapters: [], charactersPerPage: 600)

    public func chapter(spineIndex: Int) -> Chapter? {
        bySpineIndex[spineIndex].map { chapters[$0] }
    }

    /// Book page indices of a linear chapter; empty for non-linear or unknown spine items.
    public func pageRange(ofSpineIndex index: Int) -> Range<Int> {
        chapter(spineIndex: index)?.pageRange ?? 0..<0
    }

    /// `true` when the chapter's count is an estimate (also for spine items that are not in the numbering).
    public func isEstimated(spineIndex index: Int) -> Bool {
        chapter(spineIndex: index)?.isEstimated ?? true
    }

    /// Book page index of page `pageIndex` of chapter `spineIndex`, clamped to the chapter's range. nil for
    /// non-linear spine items.
    public func pageIndex(spineIndex: Int, pageIndex: Int) -> Int? {
        guard let chapter = chapter(spineIndex: spineIndex) else { return nil }
        return chapter.firstPage + min(max(0, pageIndex), chapter.pageCount - 1)
    }

    /// The chapter and in-chapter page that hold book page `index`, clamped to the book. nil when there are no pages.
    public func location(ofPageIndex index: Int) -> Location? {
        guard !chapters.isEmpty else { return nil }
        let clamped = min(max(0, index), totalPages - 1)
        // Binary search on firstPage.
        var low = 0
        var high = chapters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chapters[mid].firstPage <= clamped { low = mid } else { high = mid - 1 }
        }
        let chapter = chapters[low]
        return Location(spineIndex: chapter.spineIndex, pageIndex: clamped - chapter.firstPage)
    }

    /// Fraction of the book before page `pageIndex` of `spineIndex` (0...1), or nil for non-linear items.
    public func progression(spineIndex: Int, pageIndex: Int) -> Double? {
        guard totalPages > 0, let page = self.pageIndex(spineIndex: spineIndex, pageIndex: pageIndex) else { return nil }
        return Double(page + 1) / Double(totalPages)
    }
}
