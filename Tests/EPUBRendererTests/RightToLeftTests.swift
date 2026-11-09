import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Right-to-left horizontal text (Arabic, `dir="rtl"` on html) in a right-bound book (M5, regime-anticancer-arabic).
@Suite(.serialized) @MainActor struct RightToLeftTests {
    static let arabic = ReaderSessionTests.fixtures.appendingPathComponent("regime-anticancer-arabic.epub")

    @Test func rightToLeftChapterPaginatesAndKeepsItsTextDirection() async throws {
        let host = try await SessionHost(url: Self.arabic)
        await host.session.loadIfNeeded()
        #expect(host.session.isRightToLeft)
        await host.session.go(toSpineIndex: 2)
        #expect(host.session.chapterPageCount > 3, "the long Arabic chapter is more than one page")
        let style = try await host.js("""
            const p = document.querySelector("article p") || document.querySelector("p");
            return [getComputedStyle(document.documentElement).direction, getComputedStyle(document.body).direction,
                    getComputedStyle(p).direction, document.scrollingElement.scrollLeft >= 0];
            """) as? [Any]
        #expect(style?[0] as? String == "ltr")
        #expect(style?[1] as? String == "rtl")
        #expect(style?[2] as? String == "rtl")
        #expect(style?[3] as? Bool == true)

        // Reading moves through the chapter, and positions round-trip.
        let first = try #require(host.session.position?.cfi)
        await host.session.goForward()
        await host.session.goForward()
        #expect(host.session.currentPageIndex == 2)
        let cfi = try #require(host.session.position?.cfi)
        #expect(cfi != first)
        #expect(try await host.renderer.pageFor(cfi) == 2)
        await host.session.go(toSpineIndex: 0)
        await host.session.go(to: cfi)
        #expect(host.session.currentSpineIndex == 2)
        #expect(host.session.currentPageIndex == 2)
    }

    @Test func rightBoundSpreadPutsTheFirstPageOnTheRight() async throws {
        var settings = ReaderSettings()
        settings.spreadPolicy = .always
        let host = try await SessionHost(url: Self.arabic, settings: settings, size: CGSize(width: 800, height: 600))
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 2)
        #expect(host.session.isShowingSpread)
        // The two-frame wrapper: frame 0 holds the first page of the pair, on the right half.
        let frames = try await host.js("""
            const f = Array.from(document.querySelectorAll("iframe"));
            return f.map(e => [e.getBoundingClientRect().left, e.contentDocument.scrollingElement.scrollLeft, e.style.visibility]);
            """) as? [[Any]]
        let pair = try #require(frames)
        #expect(pair.count == 2)
        let left0 = try #require(pair.first?[0] as? Double), left1 = try #require(pair.last?[0] as? Double)
        #expect(left0 >= 399 && left1 < 1, "first page right, second left")
        let pages = host.session.chapterPageCount
        #expect(pages > 1)

        await host.session.goForward()
        #expect(host.session.currentPageIndex == 1)
        let cfi = try #require(host.session.position?.cfi)
        #expect(try await host.renderer.pageFor(cfi) == 1)
        let scrolled = try await host.js("""
            const f = Array.from(document.querySelectorAll("iframe"));
            return f.map(e => e.contentDocument.scrollingElement.scrollLeft);
            """) as? [Double]
        // Child pages 2 and 3 of a 400-pt-wide frame.
        #expect(scrolled?.first.map { abs($0 - 800) < 2 } == true)
        #expect(scrolled?.last.map { abs($0 - 1200) < 2 } == true)
    }
}
