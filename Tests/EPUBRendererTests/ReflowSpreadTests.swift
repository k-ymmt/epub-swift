import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Reflowable chapters as two facing pages (M4, docs/design/02-rendering.md §6.2): two columns per page in
/// horizontal writing, the vertical wrapper (two frames, adjacent pages) in vertical writing.
@Suite(.serialized) @MainActor struct ReflowSpreadTests {
    static let mobyDick = ReaderSessionTests.mobyDick
    static let kusamakura = VerticalWritingTests.kusamakura

    @Test func horizontalChapterGetsTwoColumnsAndAboutHalfThePages() async throws {
        // Reference: a single 400×600 page.
        let single = try await SessionHost(url: Self.mobyDick, size: CGSize(width: 400, height: 600))
        await single.session.loadIfNeeded()
        await single.session.go(toSpineIndex: 6)
        let singleCount = single.session.chapterPageCount
        #expect(singleCount > 4)
        #expect(!single.session.isShowingSpread)

        // 800×600, policy auto (landscape): the same chapter as two columns of the same width per page.
        let spread = try await SessionHost(url: Self.mobyDick, size: CGSize(width: 800, height: 600))
        await spread.session.loadIfNeeded()
        await spread.session.go(toSpineIndex: 6)
        let session = spread.session
        #expect(session.isShowingSpread)
        #expect(session.visibleSpineIndices == [6])
        let columns = try await spread.js("return getComputedStyle(document.documentElement).getPropertyValue('--reader-columns').trim()") as? String
        #expect(columns == "2")
        let columnWidth = try await spread.js("return parseFloat(getComputedStyle(document.documentElement).columnWidth)") as? Double
        #expect(columnWidth == 352) // (800 - 4 × 24) / 2
        let expected = (singleCount + 1) / 2
        #expect(abs(session.chapterPageCount - expected) <= 1, "\(session.chapterPageCount) pages vs \(singleCount) single pages")
        #expect(session.chapterPageCount < singleCount)

        // Page 1 starts where single page 2 starts (two single pages per face).
        await session.go(toPageInChapter: 1)
        let spreadCFI = try #require(session.position?.cfi)
        await single.session.go(toPageInChapter: 2)
        let singleCFI = try #require(single.session.position?.cfi)
        #expect(spreadCFI.description == singleCFI.description)

        // Policy never: one wide column, no spread.
        session.settings.spreadPolicy = .never
        try await spread.waitUntil { !session.isLoading }
        #expect(!session.isShowingSpread)
        let columnsAfter = try await spread.js("return getComputedStyle(document.documentElement).getPropertyValue('--reader-columns').trim()") as? String
        #expect(columnsAfter == "1")
        #expect(session.visibleSpineIndices == [6])
        // Back to auto: two columns again, position kept.
        let before = try #require(session.position?.cfi)
        session.settings.spreadPolicy = .auto
        try await spread.waitUntil { !session.isLoading }
        #expect(session.isShowingSpread)
        let page = try await spread.renderer.pageFor(before)
        #expect(page == session.currentPageIndex)
    }

    @Test func verticalChapterUsesTwoFramesWithAdjacentPages() async throws {
        let single = try await SessionHost(url: Self.kusamakura, size: CGSize(width: 400, height: 600))
        await single.session.loadIfNeeded()
        await single.session.go(toSpineIndex: 2)
        let singleCount = single.session.chapterPageCount
        #expect(singleCount > 3)

        let spread = try await SessionHost(url: Self.kusamakura, size: CGSize(width: 800, height: 600))
        await spread.session.loadIfNeeded()
        await spread.session.go(toSpineIndex: 2)
        let session = spread.session
        #expect(session.isShowingSpread)
        #expect(session.writingMode == .verticalRL)
        #expect(session.isRightToLeft)
        #expect(session.visibleSpineIndices == [2])
        #expect(session.chapterPageCount == (singleCount + 1) / 2)
        let isWrapper = try await spread.js("return !!window.__epubReader.isSpreadWrapper && window.__epubReader.kind") as? String
        #expect(isWrapper == "vertical")
        let frames = try await FixedLayoutSpreadTests.frames(spread)
        #expect(frames.count == 2)
        // vertical-rl: the first page of the pair is the right frame.
        #expect(frames[0].placement == "r" && frames[0].x == 400 && frames[0].width == 400 && frames[0].height == 600)
        #expect(frames[1].placement == "l" && frames[1].x == 0)

        func scrollTops() async throws -> [Double] {
            try await spread.js("return Array.from(document.querySelectorAll('iframe')).map(f => f.contentDocument.scrollingElement.scrollTop)") as? [Double] ?? []
        }
        var tops = try await scrollTops()
        #expect(tops == [0, 600])
        await session.goForward()
        #expect(session.currentPageIndex == 1)
        tops = try await scrollTops()
        #expect(tops == [1200, 1800])
        // The position of face k is the position of single page 2k.
        let cfi = try #require(session.position?.cfi)
        await single.session.go(toPageInChapter: 2)
        #expect(single.session.position?.cfi.description == cfi.description)
        // Rects of the visible text come back in face coordinates, clipped to the frame that shows them.
        var end = cfi.withoutAssertions
        end.characterOffset = (end.characterOffset ?? 0) + 3
        let rects = await session.rects(for: CFIRange(start: cfi.withoutAssertions, end: end))
        #expect(!rects.isEmpty)
        #expect(rects.allSatisfy { $0.minX >= 0 && $0.maxX <= 800 && $0.minY >= 0 && $0.maxY <= 600 })
        // Face 1 shows single pages 2 and 3; the first text of page 2 is on the right half (vertical-rl).
        #expect(rects.allSatisfy { $0.minX >= 400 })

        // Last face: the second frame is hidden when the chapter has an odd page count.
        await session.go(toPageInChapter: session.chapterPageCount - 1)
        let hidden = try await FixedLayoutSpreadTests.frames(spread)
        #expect(hidden[1].hidden == (singleCount % 2 == 1))

        // Settings change relayouts the wrapper in place and keeps the page.
        let anchor = try #require(session.position?.cfi)
        session.settings.fontScale = 1.2
        try await spread.waitUntil { !session.isLoading }
        #expect(session.isShowingSpread)
        let page = try await spread.renderer.pageFor(anchor)
        #expect(page == session.currentPageIndex)

        // Portrait: back to the chapter itself.
        spread.session.viewportSize = CGSize(width: 400, height: 600)
        #if os(macOS)
        spread.window.setContentSize(CGSize(width: 400, height: 600))
        #endif
        try await spread.waitUntil { !spread.session.isLoading && spread.session.viewportSize.width == 400 }
        #expect(!session.isShowingSpread)
        let wrapper = try await spread.js("return !!window.__epubReader.isSpreadWrapper") as? Bool
        #expect(wrapper == false)
        #expect(session.visibleSpineIndices == [2])
    }

    @Test func paginationServiceMeasuresSpreadFaces() async throws {
        let host = try await SessionHost(url: Self.kusamakura, size: CGSize(width: 800, height: 600))
        await host.session.loadIfNeeded()
        let session = host.session
        try await host.waitUntil(timeout: .seconds(30)) { !session.pagination.isEstimated }
        // Every measured chapter is a face count: no more than the single-page count would be, and the current
        // chapter (measured by the display) agrees with the service's later measurement.
        let current = session.chapterPageCount
        #expect(session.pagination.chapter(spineIndex: session.currentSpineIndex)?.pageCount == current)
        let next = try #require(session.pagination.chapters.first { $0.spineIndex > session.currentSpineIndex })
        await session.go(toSpineIndex: next.spineIndex)
        #expect(session.chapterPageCount == next.pageCount)
    }
}
