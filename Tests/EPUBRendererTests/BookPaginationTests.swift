import Foundation
import Testing
import EPUBCore
@testable import EPUBRenderer

/// `BookPagination`: estimates from character counts, measured values replacing them, and page ↔ location mapping
/// (docs/design/02-rendering.md §5.2).
@Suite struct BookPaginationTests {
    static func publication(counts: [Int?], nonLinear: Set<Int> = []) -> Publication {
        let items = counts.enumerated().map { i, count in
            SpineItem(id: "c\(i)", index: i, path: "c\(i).xhtml", mediaType: "application/xhtml+xml", isLinear: !nonLinear.contains(i), layout: .reflowable, spreadPosition: nil, characterCount: count)
        }
        let manifest = items.map { ManifestItem(id: $0.id, href: $0.path, path: $0.path, mediaType: $0.mediaType, properties: [], fallback: nil, mediaOverlay: nil) }
        return Publication(id: PublicationID(), metadata: Metadata(title: "t"), manifest: manifest, readingOrder: items, toc: [], pageList: [], landmarks: [], layout: .reflowable, spread: .auto, pageProgression: .default, coverImagePath: nil, packageDocumentPath: "p.opf", navigationDocumentPath: nil, warnings: [])
    }

    @Test func estimatesFromTheDefaultRatioBeforeAnythingIsMeasured() {
        let pub = Self.publication(counts: [600, 1500, nil, 50])
        let pagination = BookPagination.make(publication: pub, measured: [:], defaultCharactersPerPage: 600)
        #expect(pagination.isEstimated)
        #expect(pagination.chapters.map(\.pageCount) == [1, 3, 1, 1])
        #expect(pagination.totalPages == 6)
        #expect(pagination.pageRange(ofSpineIndex: 1) == 1..<4)
        #expect(pagination.isEstimated(spineIndex: 2))
        #expect(pagination.charactersPerPage == 600)
    }

    @Test func measuredChaptersReplaceEstimatesAndTeachTheRatio() {
        let pub = Self.publication(counts: [1000, 2000, 3000])
        // Chapter 1 measured at 10 pages → 200 characters per page.
        let pagination = BookPagination.make(publication: pub, measured: [1: 10], defaultCharactersPerPage: 600)
        #expect(pagination.charactersPerPage == 200)
        #expect(pagination.chapters.map(\.pageCount) == [5, 10, 15])
        #expect(pagination.chapters.map(\.isEstimated) == [true, false, true])
        #expect(pagination.isEstimated)
        #expect(pagination.estimatedChapterCount == 2)

        let all = BookPagination.make(publication: pub, measured: [0: 4, 1: 10, 2: 20], defaultCharactersPerPage: 600)
        #expect(!all.isEstimated)
        #expect(all.totalPages == 34)
        #expect(all.pageRange(ofSpineIndex: 2) == 14..<34)
    }

    @Test func shortChaptersDoNotTeachTheRatio() {
        // A 2-page cover with 20 characters must not turn 1000-character chapters into 100-page estimates.
        let pub = Self.publication(counts: [20, 1000, 1000])
        let pagination = BookPagination.make(publication: pub, measured: [0: 2], defaultCharactersPerPage: 500)
        #expect(pagination.charactersPerPage == 500)
        #expect(pagination.chapters.map(\.pageCount) == [2, 2, 2])
    }

    /// The scrolled layout knows a chapter's length more finely than in whole pages (its height over the page
    /// height, 08-continuous-scroll §6.2): that teaches the ratio, the rounded-up count does not.
    @Test func lengthsInFractionsOfAPageTeachTheRatio() {
        let pub = Self.publication(counts: [1000, 1000, 5000])
        // Two chapters 1.25 pages long: two pages each, but 800 characters fill a page, not 500.
        let pagination = BookPagination.make(publication: pub, measured: [0: 2, 1: 2], extents: [0: 1.25, 1: 1.25], defaultCharactersPerPage: 600)
        #expect(pagination.charactersPerPage == 800)
        #expect(pagination.chapters.map(\.pageCount) == [2, 2, 7])
        #expect(pagination.chapters.map(\.isEstimated) == [false, false, true])
        // Without the lengths the counts teach it, as in the paged layout.
        #expect(BookPagination.make(publication: pub, measured: [0: 2, 1: 2], extents: [:], defaultCharactersPerPage: 600).charactersPerPage == 500)
        // A length that is not one says nothing.
        #expect(BookPagination.make(publication: pub, measured: [0: 2, 1: 2], extents: [0: 0, 1: -.infinity], defaultCharactersPerPage: 600).charactersPerPage == 500)
    }

    @Test func mapsBetweenBookPagesAndChapterLocations() {
        let pub = Self.publication(counts: [0, 0, 0, 0], nonLinear: [1])
        let pagination = BookPagination.make(publication: pub, measured: [0: 3, 2: 5, 3: 2])
        #expect(pagination.chapters.map(\.spineIndex) == [0, 2, 3]) // non-linear item 1 excluded
        #expect(pagination.totalPages == 10)
        #expect(pagination.pageIndex(spineIndex: 2, pageIndex: 0) == 3)
        #expect(pagination.pageIndex(spineIndex: 2, pageIndex: 99) == 7) // clamped to the chapter
        #expect(pagination.pageIndex(spineIndex: 1, pageIndex: 0) == nil)
        #expect(pagination.pageRange(ofSpineIndex: 1).isEmpty)
        #expect(pagination.location(ofPageIndex: 0) == BookPagination.Location(spineIndex: 0, pageIndex: 0))
        #expect(pagination.location(ofPageIndex: 2) == BookPagination.Location(spineIndex: 0, pageIndex: 2))
        #expect(pagination.location(ofPageIndex: 3) == BookPagination.Location(spineIndex: 2, pageIndex: 0))
        #expect(pagination.location(ofPageIndex: 9) == BookPagination.Location(spineIndex: 3, pageIndex: 1))
        #expect(pagination.location(ofPageIndex: 50) == BookPagination.Location(spineIndex: 3, pageIndex: 1)) // clamped
        #expect(pagination.location(ofPageIndex: -1) == BookPagination.Location(spineIndex: 0, pageIndex: 0))
        #expect(pagination.progression(spineIndex: 3, pageIndex: 1) == 1)
        #expect(pagination.progression(spineIndex: 0, pageIndex: 0) == 0.1)
        #expect(BookPagination.empty.location(ofPageIndex: 0) == nil)
    }
}
