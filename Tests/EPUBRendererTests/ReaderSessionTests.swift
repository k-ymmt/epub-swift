import Foundation
import Testing
import WebKit
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

#if canImport(AppKit)
import AppKit
#endif

/// Drives a `ReaderSession` through a real WKWebView hosted in an off-screen window (macOS `swift test`).
@MainActor
final class SessionHost {
    let session: ReaderSession
    #if canImport(AppKit)
    let window: NSWindow
    #endif

    init(url: URL, settings: ReaderSettings = ReaderSettings(), size: CGSize = CGSize(width: 400, height: 600)) async throws {
        let container = try await EPUBContainer(url: url)
        session = ReaderSession(container: container, settings: settings)
        #if canImport(AppKit)
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 50, y: 50), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.platformView
        window.orderFrontRegardless()
        #endif
        session.viewportSize = size
    }

    var renderer: WebViewSpineRenderer { session.renderer as! WebViewSpineRenderer }

    func js(_ body: String) async throws -> Any? {
        try await renderer.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: WebViewSpineRenderer.readerWorld)
    }

    func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { throw SessionHostError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while try await !condition() {
            if clock.now > deadline { throw SessionHostError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    enum SessionHostError: Error { case timeout }
}

@Suite(.serialized) @MainActor struct ReaderSessionTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let mobyDick = fixtures.appendingPathComponent("moby-dick.epub")
    static let childrens = fixtures.appendingPathComponent("childrens-literature.epub")

    @Test func loadsFirstLinearChapterAndReportsPageCount() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        #expect(host.session.hasLoaded)
        #expect(!host.session.isLoading)
        #expect(host.session.currentSpineIndex == 1) // cover is linear="no"; titlepage is first
        #expect(host.session.currentPageIndex == 0)
        #expect(host.session.chapterPageCount >= 1)
        #expect(host.session.writingMode == .horizontalTB)

        // Chapter 1 is long enough to have several pages at 400x600.
        await host.session.go(toSpineIndex: 6)
        #expect(host.session.currentSpineIndex == 6)
        #expect(host.session.chapterPageCount > 3)
        let measured = try await host.js("""
            const s = document.scrollingElement;
            const end = document.getElementById("__reader_end").getBoundingClientRect();
            return { clientWidth: s.clientWidth, scrollLeft: s.scrollLeft, endLeft: end.left, readyState: document.readyState,
                     contentType: document.contentType, pageWidthVar: getComputedStyle(document.documentElement).getPropertyValue("--reader-page-width").trim() };
            """) as? [String: Any]
        let m = try #require(measured)
        #expect(m["clientWidth"] as? Int == 1200)   // 3-page-wide frame
        #expect(m["scrollLeft"] as? Int == 0)
        #expect(m["contentType"] as? String == "application/xhtml+xml")
        #expect(m["pageWidthVar"] as? String == "400px")
    }

    @Test func goForwardScrollsByOnePageAndCrossesChapters() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let pageCount = host.session.chapterPageCount

        await host.session.goForward()
        #expect(host.session.currentPageIndex == 1)
        // Page 1 sits in the middle slot: scrollLeft 0, web view offset -400.
        #expect(host.renderer.visibleSlot == 1)
        #expect(host.renderer.webView.frame.origin.x == -400)

        await host.session.goForward()
        #expect(host.session.currentPageIndex == 2)
        #expect(host.renderer.visibleSlot == 1)
        let scrollLeft = try await host.js("return document.scrollingElement.scrollLeft") as? Int
        #expect(scrollLeft == 400)

        await host.session.goBackward()
        #expect(host.session.currentPageIndex == 1)

        // Jump to the last page and step over the chapter boundary.
        await host.session.go(toPageInChapter: pageCount - 1)
        #expect(host.session.currentPageIndex == pageCount - 1)
        await host.session.goForward()
        #expect(host.session.currentSpineIndex == 7)
        #expect(host.session.currentPageIndex == 0)

        await host.session.goBackward()
        #expect(host.session.currentSpineIndex == 6)
        #expect(host.session.currentPageIndex == pageCount - 1)
    }

    @Test func settingsChangeRelayoutsAndKeepsThePlace() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let before = host.session.chapterPageCount
        await host.session.go(toPageInChapter: 2)
        let anchorText = try await host.js("""
            const r = document.caretRangeFromPoint(400 + 26, 22);
            return r ? r.startContainer.data.slice(r.startOffset, r.startOffset + 20) : null;
            """) as? String

        host.session.settings.fontScale = 1.6
        try await host.waitUntil { !host.session.isLoading && host.session.chapterPageCount != before }
        #expect(host.session.chapterPageCount > before)
        // The text that was at the top of the page is still on the visible page.
        let visibleText = try await host.js("""
            const slot = \(host.renderer.visibleSlot);
            const texts = [];
            for (let y = 22; y < 580; y += 12) {
              const r = document.caretRangeFromPoint(slot * 400 + 26, y);
              if (r && r.startContainer.nodeType === 3) texts.push(r.startContainer.data);
            }
            return texts.join("\\n");
            """) as? String
        if let anchorText, !anchorText.isEmpty {
            #expect(visibleText?.contains(anchorText.prefix(10)) == true)
        }

        host.session.settings.theme = .dark
        try await host.waitUntil { !host.session.isLoading }
        let theme = try await host.js("return document.documentElement.getAttribute('data-reader-theme')") as? String
        #expect(theme == "dark")

        host.session.settings.font = .system(name: "Helvetica")
        try await host.waitUntil { !host.session.isLoading }
        let fontAttr = try await host.js("return document.documentElement.getAttribute('data-reader-font')") as? String
        #expect(fontAttr == "override")
        let family = try await host.js("return getComputedStyle(document.body).fontFamily") as? String
        #expect(family?.contains("Helvetica") == true)
    }

    @Test func fontOverrideCanBeRevertedAndCustomFontsAreDeclaredAfterLoad() async throws {
        var settings = ReaderSettings()
        settings.font = .system(name: "Helvetica")
        let host = try await SessionHost(url: Self.mobyDick, settings: settings)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let overridden = try await host.js("return getComputedStyle(document.body).fontFamily") as? String
        #expect(overridden?.contains("Helvetica") == true)

        // Back to the publisher's font: the load-time `!important` rule and the variable must both go away.
        host.session.settings.font = .publisher
        try await host.waitUntil { !host.session.isLoading }
        let attr = try await host.js("return document.documentElement.getAttribute('data-reader-font')")
        #expect(attr == nil || attr is NSNull)
        let reverted = try await host.js("return getComputedStyle(document.body).fontFamily") as? String
        #expect(reverted?.contains("Helvetica") == false)
        let styleText = try await host.js("return document.getElementById('__reader_settings').textContent") as? String
        #expect(styleText?.contains("font-family: var(--reader-font-family) !important") == false)

        // A custom font chosen after load gets its @font-face declaration and is served by the scheme handler.
        let fontFile = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")
        guard FileManager.default.fileExists(atPath: fontFile.path) else { return }
        host.session.settings.font = .custom(FontResource(familyName: "ReaderTestFont", fileURL: fontFile))
        try await host.waitUntil { !host.session.isLoading }
        let declared = try await host.js("""
            const sheet = document.getElementById('__reader_settings').sheet;
            return Array.from(sheet.cssRules).some(r => r instanceof CSSFontFaceRule && r.style.fontFamily.includes('ReaderTestFont'));
            """) as? Bool
        #expect(declared == true)
        let custom = try await host.js("return getComputedStyle(document.body).fontFamily") as? String
        #expect(custom?.contains("ReaderTestFont") == true)
    }

    @Test func goForwardDoesNotCrossChaptersWhenThePageMoveFails() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let spine = host.session.currentSpineIndex
        // Break the reader script so that goToPage throws instead of answering.
        _ = try await host.js("window.__epubReader.goToPage = () => { throw new Error('simulated failure'); }; return true")
        await host.session.goForward()
        #expect(host.session.currentSpineIndex == spine)
        #expect(host.session.currentPageIndex == 0)
    }

    @Test func snapshotsHaveThePageSize() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let current = try #require(await host.session.pageSnapshot(.current))
        #expect(current.size == CGSize(width: 400, height: 600))
        #expect(CGFloat(current.image.width) == 400 * current.scale)
        let next = try #require(await host.session.pageSnapshot(.next))
        #expect(next.pageIndex == 1)
        #expect(await host.session.pageSnapshot(.previous) == nil) // page 0 has no previous page in this chapter
    }

    @Test func navigatesToTOCEntriesWithFragments() async throws {
        let host = try await SessionHost(url: Self.childrens)
        await host.session.loadIfNeeded()
        let pub = host.session.publication
        let section = try #require(pub.toc.first)
        let bibliography = try #require(section.children.first { $0.label == "BIBLIOGRAPHY" })
        await host.session.go(to: bibliography)
        #expect(host.session.currentSpineIndex == 2)
        #expect(host.session.chapterPageCount > 50)
        // The fragment's element is on the visible page.
        let visible = try await host.js("""
            const el = document.getElementById("pgepubid00495");
            const r = el.getBoundingClientRect();
            const slot = \(host.renderer.visibleSlot);
            return r.left >= slot * 400 && r.left < (slot + 1) * 400;
            """) as? Bool
        #expect(visible == true)

        // A later entry lands on a later page.
        let nightingale = try #require(section.descendantsFlat.first { $0.label.contains("THE NIGHTINGALE") })
        let pageBefore = host.session.currentPageIndex
        await host.session.go(to: nightingale)
        #expect(host.session.currentPageIndex > pageBefore)
    }

    @Test func emitsPositionChangedEvents() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        var received: [ReaderEvent] = []
        let stream = host.session.events
        let collector = Task { @MainActor in
            for await event in stream { received.append(event) }
        }
        await host.session.loadIfNeeded()
        await host.session.goForward()
        func positions() -> [ReadingPosition] {
            received.compactMap { if case .positionChanged(let p) = $0 { return p }; return nil }
        }
        try await host.waitUntil { positions().count >= 2 }
        collector.cancel()
        #expect(received.contains { if case .paginationUpdated = $0 { return true }; return false })
        let last = positions()[1]
        #expect(last.spineIndex == host.session.currentSpineIndex)
        #expect(last == host.session.position)
        #expect(last.cfi.spineIndex == host.session.currentSpineIndex)
        // The title page is a single image: the position points at the element, not at a character.
        #expect(last.cfi.characterOffset == nil)
        #expect(last.cfi.steps.count >= 1)
        #expect(last.progressionInChapter > 0)
        #expect(last.chapterTitle == "Moby-Dick")
    }

    /// `position` is a CFI that `go(to:)` brings back after moving elsewhere, and that survives a chapter reload
    /// and a layout change (docs/design/02-rendering.md §5.3).
    @Test func positionRoundTripsThroughCFI() async throws {
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        for _ in 0..<3 { await host.session.goForward() }
        let position = try #require(host.session.position)
        #expect(position.spineIndex == 6)
        #expect(position.cfi.description.hasPrefix("epubcfi(/6/14[xchapter_001]!/4"))
        #expect(position.chapterTitle?.hasPrefix("Chapter 1.") == true)
        let page = host.session.currentPageIndex
        #expect(page == 3)

        // Somewhere else, then back by CFI: same chapter, same page.
        await host.session.go(toSpineIndex: 8)
        #expect(host.session.currentSpineIndex == 8)
        await host.session.go(to: position)
        #expect(host.session.currentSpineIndex == 6)
        #expect(host.session.currentPageIndex == page)
        #expect(host.session.position?.cfi.withoutAssertions == position.cfi.withoutAssertions)

        // Within the chapter, by a CFI of a later page.
        await host.session.go(toPageInChapter: 7)
        let later = try #require(host.session.position?.cfi)
        await host.session.go(to: position.cfi)
        #expect(host.session.currentPageIndex == page)
        await host.session.go(to: later)
        #expect(host.session.currentPageIndex == 7)
        #expect(host.session.pageIndex(for: position) == host.session.pagination.pageIndex(spineIndex: 6, pageIndex: page))

        // A chapter-level CFI (no text offset) lands on the chapter's first page; an unknown spine step is ignored.
        await host.session.go(to: CFI("epubcfi(/6/14[xchapter_001]!/4)")!)
        #expect(host.session.currentPageIndex == 0)
        await host.session.go(to: CFI("epubcfi(/6/999[nope]!/4)")!)
        #expect(host.session.currentSpineIndex == 6)
    }
}

extension TOCEntry {
    /// Depth-first flattening for tests.
    var descendantsFlat: [TOCEntry] {
        children.flatMap { [$0] + $0.descendantsFlat }
    }
}

@Suite(.serialized) @MainActor struct ReaderSessionLateLayoutTests {
    @Test func readsChildrensLiteratureToTheEndAndKeepsPlaceOnResize() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.childrens)
        await host.session.loadIfNeeded()
        var pages = 0
        while !host.session.isAtEnd, pages < 5000 {
            let before = (host.session.currentSpineIndex, host.session.currentPageIndex)
            await host.session.goForward()
            let after = (host.session.currentSpineIndex, host.session.currentPageIndex)
            #expect(before != after)
            pages += 1
        }
        #expect(host.session.currentSpineIndex == 2)
        // Images may still be loading: once they are, the count must not exceed the page we are on by more than 0.
        try await Task.sleep(for: .milliseconds(500))
        #expect(host.session.currentPageIndex == host.session.chapterPageCount - 1, "ended at \(host.session.currentPageIndex + 1)/\(host.session.chapterPageCount)")
        #expect(host.session.isAtEnd)

        // Shrinking the viewport (e.g. a status bar appearing) keeps the reader at the end of the chapter.
        let countBefore = host.session.chapterPageCount
        host.session.viewportSize = CGSize(width: 400, height: 580)
        try await host.waitUntil { !host.session.isLoading && host.session.chapterPageCount != countBefore }
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.session.currentPageIndex >= host.session.chapterPageCount - 3, "landed on \(host.session.currentPageIndex + 1)/\(host.session.chapterPageCount)")
    }

    /// A resize keeps the old page on screen as a snapshot until the position is restored in the new layout
    /// (03-api §4.5), then drops it.
    @Test func resizeShowsASnapshotUntilTheRelayoutHasRestoredThePosition() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        await host.session.loadIfNeeded()
        let chapter = try #require(host.session.publication.readingOrder.first { $0.path.hasSuffix("chapter_001.xhtml") })
        await host.session.go(toSpineIndex: chapter.index)
        for _ in 0..<3 { await host.session.goForward() }
        let pageBefore = host.session.currentPageIndex
        let countBefore = host.session.chapterPageCount
        #expect(host.session.currentSpineIndex == chapter.index)
        #expect(countBefore > 10, "chapter 1 of moby-dick is long: \(countBefore) pages")
        #expect(host.session.relayoutSnapshot == nil)

        host.session.viewportSize = CGSize(width: 300, height: 700)
        var sawSnapshot = false
        var snapshotSize: CGSize?
        try await host.waitUntil {
            if let snapshot = host.session.relayoutSnapshot { sawSnapshot = true; snapshotSize = snapshot.size }
            return !host.session.isLoading && host.session.chapterPageCount != countBefore
        }
        #expect(sawSnapshot, "the old page is shown while the document is re-laid out")
        #expect(snapshotSize == CGSize(width: 400, height: 600), "the snapshot is of the page before the resize")
        #expect(host.session.relayoutSnapshot == nil, "dropped once the position is restored")
        #expect(host.session.chapterPageCount > countBefore)
        // Narrower pages: the same text is further into the chapter.
        #expect(host.session.currentPageIndex >= pageBefore)
    }
}
