import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Vertical writing (`kusamakura-japanese-vertical-writing`): writing-mode detection, column stacking along y,
/// paging with `scrollTop`, the three-slot frame along y and the CFI position restore (docs/design/02-rendering.md §3.4, §1.2, §5.3).
@Suite(.serialized) @MainActor struct VerticalWritingTests {
    static let kusamakura = ReaderSessionTests.fixtures.appendingPathComponent("kusamakura-japanese-vertical-writing.epub")

    @Test func detectsVerticalWritingAndStacksPagesAlongY() async throws {
        let host = try await SessionHost(url: Self.kusamakura)
        await host.session.loadIfNeeded()
        #expect(host.session.hasLoaded)
        #expect(host.session.currentSpineIndex == 0) // 表紙
        #expect(host.session.writingMode == .verticalRL)
        #expect(host.session.isRightToLeft)

        await host.session.go(toSpineIndex: 2) // 一
        #expect(host.session.writingMode == .verticalRL)
        #expect(host.session.chapterPageCount > 10)
        // Frame: one page wide, three pages tall.
        #expect(host.renderer.webView.frame.size == CGSize(width: 400, height: 1800))
        let m = try #require(try await host.js("""
            const s = document.scrollingElement;
            const end = document.getElementById("__reader_end").getBoundingClientRect();
            return { wm: getComputedStyle(document.documentElement).writingMode,
                     attr: document.documentElement.getAttribute("data-reader-writing-mode"),
                     clientWidth: s.clientWidth, clientHeight: s.clientHeight, scrollWidth: s.scrollWidth,
                     scrollTop: s.scrollTop, scrollHeight: s.scrollHeight,
                     columnWidth: getComputedStyle(document.documentElement).columnWidth,
                     endTop: end.top };
            """) as? [String: Any])
        #expect(m["wm"] as? String == "vertical-rl")
        #expect(m["attr"] as? String == "vertical")
        #expect(m["clientWidth"] as? Int == 400)
        #expect(m["clientHeight"] as? Int == 1800)
        #expect(m["scrollWidth"] as? Int == 400) // no horizontal overflow
        #expect(m["columnWidth"] as? String == "560px") // page height 600 - 2 * 20 margin
        // Page count comes from the sentinel, not scrollHeight (which has the 3-page frame as its lower bound).
        let endTop = try #require(m["endTop"] as? Double)
        let scrollTop = try #require(m["scrollTop"] as? Double)
        #expect(Int((endTop + scrollTop) / 600) + 1 == host.session.chapterPageCount)
        #expect((m["scrollHeight"] as? Int ?? 0) >= 1800)
    }

    @Test func goToPageScrollsTopAndAlignsTheSlotVertically() async throws {
        let host = try await SessionHost(url: Self.kusamakura)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 2)
        #expect(host.renderer.visibleSlot == 0)
        #expect(host.renderer.webView.frame.origin == .zero)

        await host.session.goForward()
        #expect(host.session.currentPageIndex == 1)
        #expect(host.renderer.visibleSlot == 1)
        #expect(host.renderer.webView.frame.origin == CGPoint(x: 0, y: -600))
        var scrollTop = try await host.js("return document.scrollingElement.scrollTop") as? Int
        #expect(scrollTop == 0)

        await host.session.goForward()
        #expect(host.session.currentPageIndex == 2)
        #expect(host.renderer.visibleSlot == 1)
        scrollTop = try await host.js("return document.scrollingElement.scrollTop") as? Int
        #expect(scrollTop == 600)

        await host.session.go(toPageInChapter: 5)
        scrollTop = try await host.js("return document.scrollingElement.scrollTop") as? Int
        #expect(scrollTop == 4 * 600)
        // The first line of page 5 starts at the top-right of the visible slot.
        let head = try await host.js("""
            const r = document.caretRangeFromPoint(400 - 24 - 4, 600 + 20 + 4);
            return r && r.startContainer.nodeType === 3 ? r.startContainer.data.slice(r.startOffset, r.startOffset + 6) : null;
            """) as? String
        #expect((head?.count ?? 0) > 0)

        // Last page, then across the chapter boundary and back.
        let count = host.session.chapterPageCount
        await host.session.go(toPageInChapter: count - 1)
        #expect(host.renderer.visibleSlot == 2)
        await host.session.goForward()
        #expect(host.session.currentSpineIndex == 3)
        #expect(host.session.currentPageIndex == 0)
        await host.session.goBackward()
        #expect(host.session.currentSpineIndex == 2)
        #expect(host.session.currentPageIndex == count - 1)

        // Snapshots use the slot rect along y.
        let current = try #require(await host.session.pageSnapshot(.current))
        #expect(current.size == CGSize(width: 400, height: 600))
        #expect(CGFloat(current.image.height) == 600 * current.scale)
        #expect(await host.session.pageSnapshot(.previous) != nil)
    }

    @Test func settingsChangeKeepsThePlaceInVerticalText() async throws {
        let host = try await SessionHost(url: Self.kusamakura)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 2)
        await host.session.go(toPageInChapter: 3)
        let before = host.session.chapterPageCount
        let anchorText = try await host.js("""
            const slot = \(host.renderer.visibleSlot);
            const r = document.caretRangeFromPoint(400 - 24 - 4, slot * 600 + 20 + 4);
            return r && r.startContainer.nodeType === 3 ? r.startContainer.data.slice(r.startOffset, r.startOffset + 8) : null;
            """) as? String
        host.session.settings.fontScale = 1.5
        try await host.waitUntil { !host.session.isLoading && host.session.chapterPageCount != before }
        #expect(host.session.chapterPageCount > before)
        let visibleText = try await host.js("""
            const slot = \(host.renderer.visibleSlot);
            const texts = [];
            for (let x = 400 - 26; x > 26; x -= 10) {
              for (const y of [slot * 600 + 24, slot * 600 + 200, slot * 600 + 400]) {
                const r = document.caretRangeFromPoint(x, y);
                if (r && r.startContainer.nodeType === 3) texts.push(r.startContainer.data);
              }
            }
            return texts.join("\\n");
            """) as? String
        if let anchorText, !anchorText.isEmpty {
            #expect(visibleText?.contains(anchorText.prefix(4)) == true, "anchor \(anchorText) not on the visible page")
        }
    }
}
