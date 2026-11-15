import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

@Suite @MainActor struct PaginationCacheTests {
    private func key(width: Double, scale: Double = 1) -> LayoutKey {
        var settings = ReaderSettings()
        settings.fontScale = scale
        return LayoutKey(pageSize: CGSize(width: width, height: 600), settings: settings)
    }

    @Test func layoutKeyIgnoresThemeAndSubPointSizes() {
        var a = ReaderSettings()
        var b = ReaderSettings()
        b.theme = .dark
        #expect(LayoutKey(pageSize: CGSize(width: 400, height: 600), settings: a) == LayoutKey(pageSize: CGSize(width: 400.2, height: 599.8), settings: b))
        a.fontScale = 1.2
        #expect(LayoutKey(pageSize: CGSize(width: 400, height: 600), settings: a) != LayoutKey(pageSize: CGSize(width: 400, height: 600), settings: b))
    }

    @Test func selectingAnotherLayoutBumpsTheGenerationAndKeepsOldCounts() {
        let cache = PaginationCache(publicationID: PublicationID())
        #expect(cache.select(key(width: 400)))
        let g1 = cache.generation
        #expect(cache.store(spineIndex: 2, pageCount: 10, generation: g1))
        #expect(!cache.store(spineIndex: 2, pageCount: 10, generation: g1)) // unchanged
        #expect(!cache.select(key(width: 400))) // same key: no bump
        #expect(cache.generation == g1)

        #expect(cache.select(key(width: 400, scale: 1.5)))
        let g2 = cache.generation
        #expect(g2 == g1 + 1)
        #expect(cache.pageCount(ofSpineIndex: 2) == nil)
        // A result from a load that started under the old generation is ignored.
        #expect(!cache.store(spineIndex: 3, pageCount: 7, generation: g1))
        #expect(cache.measured.isEmpty)
        #expect(cache.store(spineIndex: 3, pageCount: 7, generation: g2))

        // Back to the first layout: its counts are still there.
        cache.select(key(width: 400))
        #expect(cache.pageCount(ofSpineIndex: 2) == 10)
        #expect(cache.layoutCount == 2)
        cache.dropOtherLayouts()
        #expect(cache.layoutCount == 1)
        cache.select(key(width: 400, scale: 1.5))
        #expect(cache.measured.isEmpty)
    }

    // MARK: The scrolled layout (08-continuous-scroll §6.3)

    private func scrolledKey(width: Double = 400, height: Double = 600, insets: ReaderInsets = ReaderInsets(), configure: (inout ReaderSettings) -> Void = { _ in }) -> LayoutKey {
        var settings = ReaderSettings()
        settings.layout = .scrolled
        configure(&settings)
        return LayoutKey(scrolledWidth: width, pageHeight: ScrollPaging.pageHeight(viewportHeight: height, insets: insets), settings: settings)
    }

    @Test func theScrolledKeyIsTheWidthThePageHeightAndTheSettings() {
        let key = scrolledKey()
        // The page height P is the frame inside the insets: other insets are another P, and another key (the height
        // limit of the pictures is P).
        #expect(scrolledKey(insets: ReaderInsets(top: 40, bottom: 20)) != key)
        #expect(scrolledKey(height: 640) != key)
        // The same P from another frame and other insets lays the chapters out the same way.
        #expect(scrolledKey(height: 660, insets: ReaderInsets(top: 40, bottom: 20)) == key)
        #expect(scrolledKey(width: 500) != key)
        #expect(scrolledKey(width: 400.3, height: 599.8) == key)
        #expect(scrolledKey { $0.fontScale = 1.2 } != key)
        #expect(scrolledKey { $0.scrolledTextWidth = 30 } != key)
        #expect(scrolledKey { $0.theme = .dark } == key)
        // What only the paged layout reads does not count.
        #expect(scrolledKey { $0.spreadPolicy = .always } == key)
        // Never the key of the paged layout of the same frame.
        #expect(LayoutKey(pageSize: CGSize(width: 400, height: 600), settings: ReaderSettings()) != key)
        var asked = ReaderSettings()
        asked.layout = .scrolled
        #expect(LayoutKey(pageSize: CGSize(width: 400, height: 600), settings: asked) != key)
    }

    @Test func heightsAreKeptPerLayoutAndTheDisplaysValueWins() {
        let cache = PaginationCache(publicationID: PublicationID())
        cache.select(scrolledKey())
        let g1 = cache.generation
        #expect(cache.storeHeight(spineIndex: 3, height: 1200, source: .measurement, generation: g1))
        #expect(!cache.storeHeight(spineIndex: 3, height: 1200, source: .measurement, generation: g1))   // unchanged
        #expect(cache.height(ofSpineIndex: 3) == 1200)
        #expect(cache.heights == [3: 1200])
        // The display web view laid the chapter out too: what the reader sees is what counts.
        #expect(cache.storeHeight(spineIndex: 3, height: 1210, source: .display, generation: g1))
        #expect(cache.height(ofSpineIndex: 3) == 1210)
        #expect(!cache.storeHeight(spineIndex: 3, height: 1200, source: .measurement, generation: g1), "a measurement does not take the display's value back")
        #expect(cache.height(ofSpineIndex: 3) == 1210)
        #expect(cache.chapterHeight(ofSpineIndex: 3) == PaginationCache.ChapterHeight(measured: 1200, displayed: 1210))
        // Nothing of another generation, nothing that is not a height.
        #expect(!cache.storeHeight(spineIndex: 4, height: 900, source: .display, generation: g1 - 1))
        #expect(!cache.storeHeight(spineIndex: 4, height: 0, source: .display, generation: g1))
        #expect(!cache.storeHeight(spineIndex: 4, height: .nan, source: .measurement, generation: g1))
        #expect(cache.height(ofSpineIndex: 4) == nil)
        // Page counts are another table: a scrolled key has none.
        #expect(cache.measured.isEmpty)
        #expect(!cache.store(spineIndex: 3, pageCount: 0, generation: g1))

        // Another page height: nothing is known, and the old layout's late results are dropped.
        #expect(cache.select(scrolledKey(insets: ReaderInsets(top: 50))))
        #expect(cache.heights.isEmpty)
        #expect(!cache.storeHeight(spineIndex: 5, height: 700, source: .measurement, generation: g1))
        #expect(cache.storeHeight(spineIndex: 5, height: 700, source: .measurement, generation: cache.generation))
        // Back: the heights are there at once.
        cache.select(scrolledKey())
        #expect(cache.heights == [3: 1210])
        #expect(cache.layoutCount == 2)
        cache.dropOtherLayouts()
        #expect(cache.layoutCount == 1)
        cache.select(scrolledKey(insets: ReaderInsets(top: 50)))
        #expect(cache.heights.isEmpty)
    }
}

/// `PaginationService` with a real hidden WKWebView (docs/design/02-rendering.md §8).
@Suite(.serialized) @MainActor struct PaginationServiceTests {
    @Test func measuresEveryChapterAndSnapshotsTheNeighbours() async throws {
        let host = try await SessionHost(url: VerticalWritingTests.kusamakura)
        var events: [BookPagination] = []
        let stream = host.session.events
        let collector = Task { @MainActor in
            for await event in stream {
                if case .paginationUpdated(let p) = event { events.append(p) }
            }
        }
        defer { collector.cancel() }
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 2)
        #expect(host.session.pagination.isEstimated)
        #expect(!host.session.pagination.isEstimated(spineIndex: 2)) // the display measured the current chapter
        #expect(host.session.pagination.chapter(spineIndex: 2)?.pageCount == host.session.chapterPageCount)

        try await host.waitUntil(timeout: .seconds(60)) { !host.session.pagination.isEstimated }
        let pagination = host.session.pagination
        #expect(pagination.chapters.count == 15)
        #expect(pagination.totalPages == pagination.chapters.map(\.pageCount).reduce(0, +))
        #expect(pagination.totalPages > 100)
        #expect(host.session.currentPage == pagination.pageRange(ofSpineIndex: 2).lowerBound)
        #expect(events.count >= 10)
        try await host.waitUntil { events.last == pagination } // the collector appends asynchronously

        // Neighbours of the current chapter have snapshots; the session hands them out at the chapter boundary.
        let service = host.session.paginationService
        #expect(service.snapshot(firstPageOf: 3) != nil)
        #expect(service.snapshot(lastPageOf: 0) != nil)
        #expect(service.snapshot(firstPageOf: 5) == nil) // not a neighbour
        await host.session.go(toPageInChapter: host.session.chapterPageCount - 1)
        let next = try #require(await host.session.pageSnapshot(.next))
        #expect(next.spineIndex == 3)
        #expect(next.pageIndex == 0)
        #expect(next.size == CGSize(width: 400, height: 600))
        await host.session.go(toPageInChapter: 0)
        let previous = try #require(await host.session.pageSnapshot(.previous))
        #expect(previous.spineIndex == 0)

        // Moving to another chapter re-targets the snapshots.
        await host.session.go(toSpineIndex: 6)
        try await host.waitUntil(timeout: .seconds(20)) { service.snapshot(firstPageOf: 7) != nil && service.snapshot(lastPageOf: 5) != nil }
        #expect(service.snapshot(firstPageOf: 3) == nil)
        #expect(!service.isWorking || host.session.pagination.isEstimated == false)
    }

    @Test func layoutChangeInvalidatesAndSwitchingBackRestoresImmediately() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let cache = host.session.paginationCache
        let generation = cache.generation
        // Let a few chapters get measured, then change the font size.
        try await host.waitUntil(timeout: .seconds(30)) { cache.measured.count >= 4 }
        let measuredBefore = host.session.pagination
        #expect(measuredBefore.chapters.filter { !$0.isEstimated }.count >= 4)

        host.session.settings.fontScale = 1.4
        try await host.waitUntil { !host.session.isLoading }
        #expect(cache.generation == generation + 1)
        // Only the current chapter (measured by the display) is known under the new layout.
        #expect(host.session.pagination.estimatedChapterCount >= measuredBefore.chapters.count - 2)
        #expect(!host.session.pagination.isEstimated(spineIndex: 6))
        #expect(host.session.pagination.chapter(spineIndex: 6)?.pageCount == host.session.chapterPageCount)
        let stale = try #require(measuredBefore.chapter(spineIndex: 6)?.pageCount)
        #expect(host.session.chapterPageCount > stale)

        // Back to the original settings: the earlier measurements are back at once, without re-measuring.
        host.session.paginationService.cancel()
        host.session.settings.fontScale = 1.0
        try await host.waitUntil { !host.session.isLoading }
        #expect(cache.generation == generation + 2)
        for chapter in measuredBefore.chapters where !chapter.isEstimated {
            #expect(host.session.pagination.chapter(spineIndex: chapter.spineIndex)?.pageCount == chapter.pageCount)
            #expect(!host.session.pagination.isEstimated(spineIndex: chapter.spineIndex))
        }
    }

    @Test func goToPageLandsInTheRightChapter() async throws {
        let host = try await SessionHost(url: VerticalWritingTests.kusamakura)
        await host.session.loadIfNeeded()
        try await host.waitUntil(timeout: .seconds(60)) { !host.session.pagination.isEstimated }
        let pagination = host.session.pagination
        let range = pagination.pageRange(ofSpineIndex: 4)
        await host.session.go(toPage: range.lowerBound + 2)
        #expect(host.session.currentSpineIndex == 4)
        #expect(host.session.currentPageIndex == 2)
        #expect(host.session.currentPage == range.lowerBound + 2)
        await host.session.go(toPage: pagination.totalPages - 1)
        #expect(host.session.isAtEnd)
        #expect(host.session.totalProgression == 1)
        await host.session.go(toPage: 0)
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == 0)
    }
}
