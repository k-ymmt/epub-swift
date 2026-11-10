import Foundation
import Testing
import WebKit
@testable import EPUBCore
@testable import EPUBRenderer
#if canImport(AppKit)
import AppKit
#endif

/// Selection, highlights and search navigation through a real `ReaderSession` (docs/design/04-roadmap.md M3).
@Suite(.serialized) @MainActor struct SelectionHighlightSearchTests {
    static let sample = ReaderSessionTests.fixtures.appendingPathComponent("cfi-sample.epub")

    /// Selects `length` UTF-16 units of the first text node under the element `id`, from `offset`.
    private func select(_ host: SessionHost, id: String, offset: Int, length: Int) async throws {
        _ = try await host.js("""
            const el = document.getElementById("\(id)");
            const node = el.firstChild;
            const range = document.createRange();
            range.setStart(node, \(offset));
            range.setEnd(node, \(offset + length));
            const selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
            """)
    }

    private func highlightKeys(_ host: SessionHost) async throws -> [String] {
        let keys = try await host.js("return Array.from(CSS.highlights.keys());") as? [String]
        return (keys ?? []).sorted()
    }

    @Test func selectionIsReportedAndCleared() async throws {
        let host = try await SessionHost(url: Self.sample)
        var events: [SelectedText?] = []
        let stream = host.session.events
        let collector = Task { @MainActor in
            for await event in stream {
                if case .selectionChanged(let selected) = event { events.append(selected) }
            }
        }
        await host.session.loadIfNeeded()
        #expect(host.session.currentSelection == nil)

        try await select(host, id: "p1", offset: 0, length: 15)
        try await host.waitUntil { !events.isEmpty }
        let selected = try #require(host.session.currentSelection)
        #expect(selected.text == "Call me Ishmael")
        #expect(selected.range.description == "epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0[,Call me Is],/1:15[me Ishmael,. Some yea])")
        #expect(!selected.rects.isEmpty)
        for rect in selected.rects {
            #expect(rect.minX >= 0 && rect.maxX <= host.session.viewportSize.width + 1)
            #expect(rect.minY >= 0 && rect.maxY <= host.session.viewportSize.height + 1)
        }
        #expect(events == [selected])

        // Rects of the same range through the public API agree with the selection's.
        let rects = await host.session.rects(for: selected.range)
        #expect(rects == selected.rects)

        host.session.clearSelection()
        #expect(host.session.currentSelection == nil)
        try await host.waitUntil { events.last == .some(nil) }
        let collapsed = try await host.js("return window.getSelection().isCollapsed;") as? Bool
        #expect(collapsed == true)
        collector.cancel()
    }

    /// The CSS highlight key `reader.js` uses for an app annotation.
    static func key(_ annotation: Annotation) -> String {
        "reader-h-" + ("a:" + annotation.id).map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_" }.joined()
    }

    @Test func highlightsFollowTheChapterAndTheSet() async throws {
        let host = try await SessionHost(url: Self.sample)
        await host.session.loadIfNeeded()
        let publication = host.session.publication
        let inC1 = Annotation.highlight(try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0,/1:15)")), in: publication)
        let inC2 = Annotation.highlight(try #require(CFIRange("epubcfi(/6/4[c2]!/4[body]/2[p1],/1:0,/1:4)")), in: publication, color: .pink, style: .underline)
        let broken = Annotation.highlight(try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/40[nope],/1:0,/1:4)")), in: publication)
        // Bookmarks are not drawn.
        let bookmark = Annotation.bookmark(at: try #require(CFI("epubcfi(/6/2[c1]!/4[body]/4[p1]/1:0)")), in: publication)
        host.session.annotations = [inC1, inC2, broken, bookmark]

        try await host.waitUntil { (try? await self.highlightKeys(host)) == [Self.key(inC1)] }
        let rects = await host.session.rects(for: try #require(inC1.range))
        #expect(!rects.isEmpty)
        #expect(await host.session.rects(for: try #require(inC2.range)).isEmpty)
        #expect(await host.session.rects(for: try #require(broken.range)).isEmpty)
        let rule = try await host.js("return document.getElementById('__reader_highlights').textContent;") as? String
        // Solid: the palette's yellow (FFCC00) at 0.4.
        #expect(rule?.contains("::highlight(\(Self.key(inC1))) { background-color: rgba(255, 204, 0, 0.4); }") == true)

        // The next chapter draws its own highlight, with the underline style in the opaque palette color.
        await host.session.go(toSpineIndex: 1)
        try await host.waitUntil { (try? await self.highlightKeys(host)) == [Self.key(inC2)] }
        let rule2 = try await host.js("return document.getElementById('__reader_highlights').textContent;") as? String
        #expect(rule2?.contains("text-decoration: underline; text-decoration-color: rgba(255, 79, 139, 1.0)") == true)

        // Removing from the set removes the drawing.
        host.session.annotations = []
        try await host.waitUntil { (try? await self.highlightKeys(host)) == [] }
    }

    @Test func tappingAHighlightEmitsAnnotationTapped() async throws {
        let host = try await SessionHost(url: Self.sample)
        var tapped: [(Annotation.ID, [CGRect])] = []
        let stream = host.session.events
        let collector = Task { @MainActor in
            for await event in stream {
                if case .annotationTapped(let id, let rects) = event { tapped.append((id, rects)) }
            }
        }
        await host.session.loadIfNeeded()
        let range = try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0,/1:15)"))
        let highlight = Annotation.highlight(range, in: host.session.publication)
        host.session.annotations = [highlight]
        try await host.waitUntil { (try? await self.highlightKeys(host))?.count == 1 }
        let rects = await host.session.rects(for: range)
        let first = try #require(rects.first)
        _ = try await host.js("""
            const el = document.getElementById("p1");
            el.dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: \(first.midX), clientY: \(first.midY) }));
            return true;
            """)
        try await host.waitUntil { !tapped.isEmpty }
        #expect(tapped.first?.0 == highlight.id)
        #expect(tapped.first?.1 == rects)
        collector.cancel()
    }

    @Test func searchResultsNavigateWithATransientHighlight() async throws {
        let host = try await SessionHost(url: Self.sample)
        await host.session.loadIfNeeded()
        var results: [SearchResult] = []
        for try await result in host.session.search("call me") { results.append(result) }
        #expect(results.count == 3)
        #expect(results.map(\.spineIndex) == [0, 1, 1])

        func hasTransient() async throws -> Bool {
            try await host.js("return CSS.highlights.has('reader-transient');") as? Bool ?? false
        }
        await host.session.show(results[1])
        #expect(host.session.currentSpineIndex == 1)
        #expect(try await hasTransient())
        let page = try await host.renderer.pageFor(results[1].range.start)
        #expect(page == host.session.currentPageIndex)
        #expect(!(await host.session.rects(for: results[1].range)).isEmpty)

        // Back in the first chapter: the document is new, the highlight follows the result.
        await host.session.show(results[0])
        #expect(host.session.currentSpineIndex == 0)
        #expect(try await hasTransient())

        // Any page move removes it.
        await host.session.go(toSpineIndex: 1)
        await host.session.show(results[2])
        #expect(try await hasTransient())
        await host.session.go(toPageInChapter: 0)
        #expect(try await hasTransient() == false)
    }

    /// Vertical writing: the result page and rects come out in the visible page's coordinates.
    @Test func searchNavigatesInVerticalWriting() async throws {
        let host = try await SessionHost(url: VerticalWritingTests.kusamakura)
        await host.session.loadIfNeeded()
        var results: [SearchResult] = []
        for try await result in host.session.search("智に働けば角が立つ") { results.append(result) }
        let result = try #require(results.first)
        await host.session.show(result)
        #expect(host.session.currentSpineIndex == result.spineIndex)
        #expect(host.session.writingMode.isVertical)
        let page = try await host.renderer.pageFor(result.range.start)
        #expect(page == host.session.currentPageIndex)
        let rects = await host.session.rects(for: result.range)
        #expect(!rects.isEmpty)
        for rect in rects {
            #expect(rect.minY >= -1 && rect.maxY <= host.session.viewportSize.height + 1)
        }
    }

    #if canImport(AppKit)
    @Test func selectionActionsAppearInTheContextMenu() async throws {
        let host = try await SessionHost(url: Self.sample)
        await host.session.loadIfNeeded()
        var received: [SelectedText] = []
        host.session.selectionActions = [
            SelectionAction(title: "Highlight", systemImage: "highlighter") { received.append($0) },
            SelectionAction(id: "copy-cfi", title: "Copy CFI") { _ in },
        ]
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Look Up", action: nil, keyEquivalent: ""))

        // Without a selection the menu is left alone.
        host.renderer.webView.appendSelectionActions(to: menu)
        #expect(menu.items.count == 1)

        try await select(host, id: "p2", offset: 0, length: 5)
        try await host.waitUntil { host.session.currentSelection != nil }
        host.renderer.webView.appendSelectionActions(to: menu)
        #expect(menu.items.map(\.title) == ["Highlight", "Copy CFI", "", "Look Up"])
        #expect(menu.items[0].image != nil)

        let item = menu.items[0]
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        #expect(received.count == 1)
        #expect(received.first?.text == "First")
        #expect(received.first == host.session.currentSelection)
    }
    #endif
}
