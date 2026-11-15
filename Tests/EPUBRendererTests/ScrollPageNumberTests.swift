import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

extension SessionHost {
    /// The linear reading order: the chapters the scrolled layout numbers.
    var linearIndices: [Int] { session.publication.linearReadingOrder.map(\.index) }

    /// Waits until every chapter of the linear reading order has a height in the layout in effect and the hidden web
    /// view has nothing left to do.
    ///
    /// The timeout is for a whole test run: alone, the 142 chapters of Moby-Dick take two to three seconds; next to
    /// the other suites (their web views are in windows, the hidden one is not, and its process gets what is left)
    /// they took two a second.
    func waitForMeasurement(timeout: Duration = .seconds(180), sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let indices = linearIndices
        do {
            try await waitUntil(timeout: timeout, sourceLocation: sourceLocation) {
                let heights = self.session.scrollHeights
                return indices.allSatisfy { heights[$0] != nil } && !self.session.paginationService.isWorking
            }
        } catch {
            let service = session.paginationService
            let missing = indices.filter { session.scrollHeights[$0] == nil }
            Issue.record(
                "not measured: layout \(session.layout) loading \(session.isLoading) working \(service.isWorking) paused \(service.isPaused) failed \(service.failedSpineIndices.sorted()) missing \(missing.count) of \(indices.count): \(missing.prefix(12))",
                sourceLocation: sourceLocation
            )
            throw error
        }
    }
}

/// The page numbers of the scrolled layout (docs/design/08-continuous-scroll.md §6, milestone S3): the hidden web
/// view measures every chapter's height, the heights are kept by layout, and a chapter's virtual pages are its height
/// over the page height.
@Suite(.serialized) @MainActor struct ScrollPageNumberTests {
    static let mobyDick = ReaderSessionTests.mobyDick
    static let sample = ScrollLayoutTests.sample

    // MARK: The measurement (§6.2)

    @Test func everyChapterIsMeasuredWithoutBeingShown() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        #expect(host.session.layout == .scrolled)
        try await host.waitForMeasurement()

        let session = host.session
        let indices = host.linearIndices
        #expect(indices.count == 142)
        let pagination = session.pagination
        #expect(!pagination.isEstimated)
        #expect(pagination.chapters.map(\.spineIndex) == indices)
        let heights = session.scrollHeights
        for chapter in pagination.chapters {
            let height = try #require(heights[chapter.spineIndex])
            #expect(chapter.pageCount == max(1, Int((height / 600).rounded(.up))), "chapter \(chapter.spineIndex), \(height) px")
        }
        #expect(pagination.totalPages == pagination.chapters.map(\.pageCount).reduce(0, +))
        #expect(pagination.totalPages > 1000)

        // The display's window held a few chapters only; the others were measured by the hidden web view.
        let cache = session.paginationCache
        let displayed = indices.filter { cache.chapterHeight(ofSpineIndex: $0)?.displayed != nil }
        #expect(displayed.count < 10)
        #expect(indices.filter { cache.chapterHeight(ofSpineIndex: $0)?.measured != nil }.count >= indices.count - displayed.count)
        // The measurement left nothing in the hidden document, and the display's document knows the heights: the
        // blocks that stand in for the chapters outside the window are as tall as those chapters.
        let leftovers = try await host.session.paginationService.renderer.webView.callAsyncJavaScript(
            "return document.querySelectorAll('#__reader_stage > iframe').length", arguments: [:], in: nil, contentWorld: WebViewSpineRenderer.readerWorld
        ) as? Int
        #expect(leftovers == 0)
        // (They are handed over a few at a time, so the last ones may still be on their way.)
        var tail = 0.0, after = 0.0
        do {
            try await host.waitUntil(timeout: .seconds(5)) {
                let state = try await host.scrollState()
                guard let last = state.views.last else { return false }
                tail = state.tail
                after = indices.filter { $0 > last.spineIndex }.compactMap { heights[$0] }.reduce(0, +)
                return abs(tail - after) < 1
            }
        } catch {
            Issue.record("tail \(tail), the chapters after the window \(after)")
        }
    }

    /// The end condition of S3: once every chapter is measured, showing the chapters does not move the page numbers.
    /// What the hidden web view measured is the height the display lays the chapter out with.
    @Test func onceEveryChapterIsMeasuredThePageNumbersStay() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        try await host.waitForMeasurement()
        let session = host.session
        let cache = session.paginationCache
        let pagination = session.pagination
        var updates = 0
        let stream = session.events
        let collector = Task { @MainActor in
            for await event in stream { if case .paginationUpdated = event { updates += 1 } }
        }
        defer { collector.cancel() }

        var differences: [(index: Int, measured: Double, displayed: Double)] = []
        var compared = 0
        for index in host.linearIndices {
            await session.go(toSpineIndex: index)
            try await host.waitForScrollRest()
            if session.isAtEnd {
                // The last chapters are shorter than the frame: the document ends before their top reaches the
                // reading line, and the position is the book's last page (§6.1).
                #expect(session.currentPage == pagination.totalPages - 1)
            } else {
                #expect(session.currentSpineIndex == index)
                #expect(session.currentPage == pagination.pageRange(ofSpineIndex: index).lowerBound)
            }
            let height = try #require(cache.chapterHeight(ofSpineIndex: index))
            let displayed = try #require(height.displayed, "chapter \(index) was laid out by the display")
            guard let measured = height.measured else { continue } // shown before the hidden web view came to it
            compared += 1
            if measured != displayed { differences.append((index, measured, displayed)) }
        }
        // Let a late event arrive.
        try await Task.sleep(for: .milliseconds(300))
        #expect(updates == 0, "the pagination was told \(updates) times after the measurement")
        #expect(session.pagination == pagination)
        #expect(compared > 130)
        #expect(differences.isEmpty, "measured ≠ displayed: \(differences.map { "\($0.index): \($0.measured) / \($0.displayed)" })")
    }

    @Test func aChapterTheDisplayShowsFirstIsNotMeasuredAgain() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        try await host.waitForMeasurement()
        let cache = host.session.paginationCache
        // The chapter the book opened at: the display's own height is the one in use.
        let first = try #require(host.linearIndices.first)
        let height = try #require(cache.chapterHeight(ofSpineIndex: first))
        #expect(height.displayed != nil)
        #expect(cache.height(ofSpineIndex: first) == height.displayed)
    }

    // MARK: Page numbers (§6.1)

    @Test func aPageNumberLeadsToItsPageAndIsThePageShown() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        try await host.waitForMeasurement()
        let session = host.session
        let pagination = session.pagination
        let total = pagination.totalPages

        // Pages in the middle of chapters, a chapter's first page and a chapter's last page.
        let long = try #require(pagination.chapters.first { $0.pageCount > 8 })
        let later = try #require(pagination.chapters.last { $0.pageCount > 8 })
        for page in [long.firstPage + 3, later.firstPage, later.firstPage + later.pageCount - 1, long.firstPage + long.pageCount - 2, total / 2] {
            await session.go(toPage: page)
            try await host.waitForScrollRest()
            let location = try #require(pagination.location(ofPageIndex: page))
            #expect(session.currentSpineIndex == location.spineIndex, "page \(page)")
            #expect(session.currentPageIndex == location.pageIndex, "page \(page)")
            #expect(session.currentPage == page)
            #expect(session.visiblePages.first == page)
            // What a mark of the progress slider is placed by.
            #expect(session.pageIndex(for: try #require(session.position)) == page)
            // The page starts at a whole number of page heights from the chapter's top.
            let state = try await host.scrollState()
            let view = try #require(state.view(location.spineIndex))
            #expect(abs(-view.top - Double(location.pageIndex) * 600) < 1, "page \(page): the chapter's top is at \(view.top)")
            // The progression is the part of the book the page ends at.
            #expect(abs(session.totalProgression - Double(page + 1) / Double(total)) < 0.000001)
        }
        #expect(session.pagination == pagination, "going to pages moved no page number")

        // The last page of the book: the document cannot scroll that page's top to the reading line unless the last
        // chapter ends on a page boundary, and the position is the last page all the same (§6.1).
        await session.go(toPage: total - 1)
        try await host.waitForScrollRest()
        #expect(session.isAtEnd)
        #expect(session.currentPage == total - 1)
        #expect(session.visiblePages.last == total - 1)
        #expect(session.totalProgression == 1)
        await session.go(toPage: 0)
        try await host.waitForScrollRest()
        #expect(session.currentPage == 0)
        #expect(session.isAtStart)
        #expect(abs(session.totalProgression - 1 / Double(total)) < 0.000001)
    }

    @Test func scrollingThroughTheBookCountsThePagesUp() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        try await host.waitForMeasurement()
        let session = host.session
        let pagination = session.pagination
        var seen: [Int] = []
        var guardCount = 0
        while !session.isAtEnd, guardCount < 400 {
            guardCount += 1
            seen.append(try #require(session.currentPage))
            try await host.scrollDocument(by: 600)
            try await host.waitForScrollRest()
        }
        seen.append(try #require(session.currentPage))
        #expect(session.pagination == pagination)
        #expect(seen.first == 0)
        #expect(seen.last == pagination.totalPages - 1)
        // One page height at a time: every step is the next page, or the first page of the next chapter (a chapter's
        // last page may be shorter than a page).
        for (a, b) in zip(seen, seen.dropFirst()) {
            #expect(b == a + 1 || b == a + 2 || (b == a && b == pagination.totalPages - 1), "\(a) → \(b)")
        }
    }

    // MARK: The cache (§6.3)

    @Test func anotherPageHeightIsMeasuredAgainAndTheFirstOneIsBackAtOnce() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        try await host.waitForMeasurement()
        let session = host.session
        let cache = session.paginationCache
        let generation = cache.generation
        let first = session.pagination
        let heights = session.scrollHeights

        // Insets that leave a shorter page: another key, so every chapter is measured again for it.
        session.contentInsets = ReaderInsets(top: 60, bottom: 40)
        try await host.waitUntil { !session.isLoading }
        #expect(cache.generation == generation + 1)
        try await host.waitForMeasurement()
        let second = session.pagination
        #expect(!second.isEstimated)
        #expect(second.totalPages > first.totalPages, "a page of 500 px holds less than one of 600 px")
        for chapter in second.chapters {
            let height = try #require(session.scrollHeights[chapter.spineIndex])
            #expect(chapter.pageCount == max(1, Int((height / 500).rounded(.up))))
        }

        // Insets that split the same page height differently are the same layout: nothing is measured again.
        session.contentInsets = ReaderInsets(top: 20, bottom: 80)
        try await host.waitUntil { !session.isLoading }
        #expect(cache.generation == generation + 1)
        #expect(session.pagination == second)

        // The first page height again: its heights are back with the relayout, without the hidden web view.
        session.paginationService.cancel()
        session.contentInsets = ReaderInsets()
        try await host.waitUntil { !session.isLoading }
        #expect(cache.generation == generation + 2)
        #expect(session.pagination == first)
        #expect(session.scrollHeights == heights)
        #expect(cache.layoutCount == 2)
    }

    @Test func thePagedLayoutAndTheScrolledLayoutKeepTheirOwnNumbers() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        try await host.waitForMeasurement()
        let session = host.session
        let scrolled = session.pagination

        session.settings.layout = .paged
        try await host.waitUntil { session.layout == .paged && !session.isLoading }
        try await host.waitUntil(timeout: .seconds(60)) { !session.pagination.isEstimated && !session.paginationService.isWorking }
        let paged = session.pagination
        #expect(session.scrollHeights.isEmpty)
        #expect(session.paginationCache.measured.count >= host.linearIndices.count)

        session.paginationService.cancel()
        session.settings.layout = .scrolled
        try await host.waitUntil { session.layout == .scrolled && !session.isLoading }
        #expect(session.pagination == scrolled, "the heights measured before are back at once")
        session.settings.layout = .paged
        try await host.waitUntil { session.layout == .paged && !session.isLoading }
        #expect(session.pagination == paged)
    }

    // MARK: What stops the measurement

    @Test func aChapterInVerticalWritingIsToldAndNotMeasured() async throws {
        // The service alone, on a book whose text chapters are vertical: nothing is loaded in the display.
        let host = try await SessionHost.scrolled(url: VerticalWritingTests.kusamakura)
        let session = host.session
        let service = session.paginationService
        var vertical: [Int] = []
        service.onVerticalChapter = { vertical.append($0) }
        let insets = ReaderInsets()
        let size = CGSize(width: 400, height: 600)
        #expect(session.paginationCache.select(LayoutKey(scrolledWidth: 400, pageHeight: 600, settings: session.settings)))
        service.configure(
            pageSize: size, settings: session.settings,
            plan: SpreadBuilder.plan(for: session.publication, policy: .never, viewportSize: size),
            generation: session.paginationCache.generation, currentSpineIndex: nil, scrolledInsets: insets
        )
        try await host.waitUntil(timeout: .seconds(60)) { !service.isWorking }
        #expect(!vertical.isEmpty)
        #expect(service.failedSpineIndices == Set(vertical))
        for index in vertical { #expect(session.paginationCache.height(ofSpineIndex: index) == nil) }
        // The chapters in horizontal writing (the cover, the title page) are measured as in any book.
        let horizontal = host.linearIndices.filter { !vertical.contains($0) }
        for index in horizontal { #expect((session.paginationCache.height(ofSpineIndex: index) ?? 0) > 0, "chapter \(index)") }
    }

    @Test func aVerticalChapterFoundByTheMeasurementSendsTheBookBackToPages() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 8)
        try await host.waitForScrollRest()
        let position = try #require(host.session.position)
        // A chapter far from the window (what the hidden web view tells for a chapter in vertical writing).
        host.session.paginationService.onVerticalChapter?(90)
        try await host.waitUntil { host.session.layout == .paged && host.session.hasLoaded && !host.session.isLoading }
        #expect(host.session.currentSpineIndex == 8)
        #expect(host.session.position?.cfi == position.cfi)
        // And the paged layout is measured as ever.
        try await host.waitUntil(timeout: .seconds(30)) { host.session.paginationCache.measured.count >= 4 }
    }

    @Test func aMemoryWarningPausesTheMeasurementUntilTheChapterChanges() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        let session = host.session
        session.didReceiveMemoryWarning()
        #expect(session.paginationService.isPaused)
        let known = session.scrollHeights.count
        #expect(known < 142)
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.scrollHeights.count <= known + 4, "only the display's window adds heights")
        await session.go(toSpineIndex: 20)
        #expect(!session.paginationService.isPaused)
        try await host.waitForMeasurement()
        #expect(!session.pagination.isEstimated)
    }

    @Test func aCrashOfTheHiddenWebViewDoesNotStopTheMeasurement() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        let session = host.session
        let service = session.paginationService
        try await host.waitUntil(timeout: .seconds(30)) { session.scrollHeights.count >= 12 }
        #expect(service.isWorking)
        RecoveryTests.crashWebContent(of: service.renderer)
        try await host.waitForMeasurement()
        #expect(!session.pagination.isEstimated)
        #expect(service.failedSpineIndices.isEmpty)
    }
}
