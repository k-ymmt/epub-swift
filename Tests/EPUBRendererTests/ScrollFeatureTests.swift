import Foundation
import Testing
import WebKit
@testable import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer
#if canImport(AppKit)
import AppKit
#endif

extension EventRecorder {
    var scrollings: [Bool] { events.compactMap { if case .scrolling(let active) = $0 { active } else { nil } } }
    var annotationTaps: [(id: Annotation.ID, rects: [CGRect])] {
        events.compactMap { if case .annotationTapped(let id, let rects) = $0 { (id, rects) } else { nil } }
    }
    /// Every `selectionChanged`, in order; nil for "cleared".
    var selections: [SelectedText?] {
        var out: [SelectedText?] = []
        for event in events { if case .selectionChanged(let selected) = event { out.append(selected) } }
        return out
    }
    var errors: [ReaderError] { events.compactMap { if case .error(let error) = $0 { error } else { nil } } }
    /// The events that tell a move, in order: "position", "navigated(<cause>)", "scrolling+" / "scrolling-", "link".
    var moves: [String] {
        events.compactMap { event -> String? in
            switch event {
            case .positionChanged: "position"
            case .navigated(let navigation): "navigated(\(navigation.cause))"
            case .scrolling(let active): active ? "scrolling+" : "scrolling-"
            case .internalLink: "link"
            default: nil
            }
        }
    }
}

/// The features of the paged layout in the scrolled layout (docs/design/08-continuous-scroll.md §10, §12, milestone
/// S2): selection, annotations, search results, notes, images, links, the events of the reader's own scrolling,
/// recovery after a WebContent crash and memory warnings. Each test has a counterpart for pages
/// (`SelectionHighlightSearchTests`, `AnnotationRenderingTests`, `LinksNotesImagesTests`, `NavigationEventTests`,
/// `RecoveryTests`); what differs is that a chapter is a frame of the scroll document, so every rectangle is the
/// frame's rectangle moved by where the frame is, and that chapters come and go while the reader scrolls.
@Suite(.serialized) @MainActor struct ScrollFeatureTests {
    static let cfiSample = SelectionHighlightSearchTests.sample
    static let sample = ScrollLayoutTests.sample
    static let mobyDick = ReaderSessionTests.mobyDick

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// JavaScript for the frame of a chapter in the window (null when the chapter is not in it).
    static func frame(_ spineIndex: Int) -> String {
        "document.querySelector('#__reader_stage > iframe[data-spine-index=\"\(spineIndex)\"]')"
    }

    /// `links-sample.epub` without its fixed-layout page (a book with one is paged, §1): chapter one (0), chapter two
    /// (1) and the non-linear notes document (2).
    static func linksSample() throws -> URL {
        let archive = try ZIPArchive(url: LinksNotesImagesTests.sample)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-links-\(UUID().uuidString).epub")
        let writer = try ZIPWriter(url: url)
        let fixedLayoutItem = #"<itemref idref="fxl" properties="rendition:layout-pre-paginated rendition:spread-none"/>"#
        var removed = false
        for entry in archive.entryOrder where !entry.isDirectory {
            var data = try archive.data(for: entry)
            if entry.rawName.hasSuffix("package.opf") {
                let text = String(decoding: data, as: UTF8.self)
                removed = text.contains(fixedLayoutItem)
                data = Data(text.replacingOccurrences(of: fixedLayoutItem, with: "").utf8)
            }
            try writer.add(entry.rawName, data: data, method: entry.rawName == "mimetype" ? .stored : .deflate)
        }
        try writer.finish()
        guard removed else { throw Failure("links-sample has no fixed-layout itemref to remove") }
        return url
    }

    /// Selects `length` UTF-16 units of the first text node under the element `id` of a chapter, from `offset`.
    func select(_ host: SessionHost, spineIndex: Int, id: String, offset: Int, length: Int) async throws {
        let done = try await host.js("""
            const f = \(Self.frame(spineIndex));
            if (!f) { return false; }
            const doc = f.contentDocument;
            const node = doc.getElementById("\(id)").firstChild;
            const range = doc.createRange();
            range.setStart(node, \(offset));
            range.setEnd(node, \(offset + length));
            const selection = f.contentWindow.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return true;
            """) as? Bool
        #expect(done == true, "chapter \(spineIndex) is not in the window")
    }

    /// Whether a chapter's frame holds a selection; nil when the chapter is not in the window.
    func hasSelection(_ host: SessionHost, spineIndex: Int) async throws -> Bool? {
        try await host.js("""
            const f = \(Self.frame(spineIndex));
            if (!f) { return null; }
            const s = f.contentWindow.getSelection();
            return !!s && s.rangeCount > 0 && !s.isCollapsed;
            """) as? Bool
    }

    /// The highlights drawn in a chapter's frame; nil when the chapter is not in the window.
    func keys(_ host: SessionHost, spineIndex: Int) async throws -> [String]? {
        let keys = try await host.js("""
            const f = \(Self.frame(spineIndex));
            if (!f || !f.contentWindow || !f.contentWindow.CSS || !f.contentWindow.CSS.highlights) { return null; }
            return Array.from(f.contentWindow.CSS.highlights.keys()).filter(k => k.indexOf("reader-h-") === 0);
            """) as? [String]
        return keys?.sorted()
    }

    func hasTransient(_ host: SessionHost, spineIndex: Int) async throws -> Bool {
        try await host.js("""
            const f = \(Self.frame(spineIndex));
            return !!f && !!f.contentWindow.CSS && f.contentWindow.CSS.highlights.has("reader-transient");
            """) as? Bool ?? false
    }

    /// The box of the element `id` of a chapter in the reader's frame: `[x, y, width, height]` of its first line box.
    func box(_ host: SessionHost, spineIndex: Int, id: String) async throws -> CGRect {
        let values = try await host.js("""
            const f = \(Self.frame(spineIndex));
            if (!f) { return null; }
            const el = f.contentDocument.getElementById("\(id)");
            if (!el) { return null; }
            const r = el.getClientRects()[0] || el.getBoundingClientRect();
            const b = f.getBoundingClientRect();
            return [b.left + r.left, b.top + r.top, r.width, r.height];
            """) as? [Double]
        let v = try #require(values, "no element \(id) in chapter \(spineIndex)")
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    /// The first box of `length` UTF-16 units of the first text node under the element `id`, in the reader's frame:
    /// the box the chapter's own document gives, moved by where the chapter's frame is.
    func textBox(_ host: SessionHost, spineIndex: Int, id: String, offset: Int = 0, length: Int) async throws -> CGRect {
        let values = try await host.js("""
            const f = \(Self.frame(spineIndex));
            if (!f) { return null; }
            const node = f.contentDocument.getElementById("\(id)").firstChild;
            const range = f.contentDocument.createRange();
            range.setStart(node, \(offset));
            range.setEnd(node, \(offset + length));
            const r = range.getClientRects()[0];
            const b = f.getBoundingClientRect();
            return [b.left + r.left, b.top + r.top, r.width, r.height];
            """) as? [Double]
        let v = try #require(values, "no element \(id) in chapter \(spineIndex)")
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    /// Clicks the element `id` of a chapter, near the start of its first line box (or at `x` in the reader's frame).
    func click(_ id: String, spineIndex: Int, in host: SessionHost, atX x: Double? = nil) async throws {
        let clicked = try await host.js("""
            const f = \(Self.frame(spineIndex));
            if (!f) { return false; }
            const el = f.contentDocument.getElementById("\(id)");
            if (!el) { return false; }
            const r = el.getClientRects()[0] || el.getBoundingClientRect();
            const x = \(x.map { "\($0) - f.getBoundingClientRect().left" } ?? "r.left + Math.min(4, r.width / 2)");
            el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: r.top + r.height / 2 }));
            return true;
            """) as? Bool
        #expect(clicked == true, "no element \(id) in chapter \(spineIndex)")
    }

    /// Scrolls as a script does (`scrollDocument` returns once the controller has had the scroll event) and waits
    /// until the controller is at rest again.
    func scrollAndRest(_ host: SessionHost, by dy: Double) async throws {
        try await host.scrollDocument(by: dy)
        try await host.waitForScrollRest()
    }

    func firstResult(_ query: String, in host: SessionHost, where matches: (SearchResult) -> Bool = { _ in true }) async throws -> SearchResult {
        for try await result in host.session.search(query) where matches(result) { return result }
        throw Failure("nothing found for \(query)")
    }

    // MARK: Selection (§10)

    @Test func aSelectionInAChapterIsReportedInTheReadersFrameAndCleared() async throws {
        let host = try await SessionHost.scrolled(url: Self.cfiSample, insets: ReaderInsets(top: 30))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitUntil { try await host.scrollState().spineIndices == [0, 1] }
        try await host.waitForScrollRest()
        #expect(host.session.currentSelection == nil)

        // In the second chapter: its frame is below the first one, so the frame's own place counts.
        try await select(host, spineIndex: 1, id: "q3", offset: 0, length: 4)
        try await host.waitUntil { host.session.currentSelection != nil }
        let selected = try #require(host.session.currentSelection)
        #expect(selected.text == "Echo")
        #expect(selected.range.description.hasPrefix("epubcfi(/6/4[c2]!"), "\(selected.range)")
        #expect(host.session.publication.spineIndex(of: selected.range.start) == 1)
        let expected = try await textBox(host, spineIndex: 1, id: "q3", length: 4)
        let rect = try #require(selected.rects.first)
        #expect(selected.rects.count == 1)
        #expect(abs(rect.minX - expected.minX) < 1 && abs(rect.minY - expected.minY) < 1, "\(rect) at \(expected)")
        #expect(abs(rect.width - expected.width) < 1 && abs(rect.height - expected.height) < 1, "\(rect) at \(expected)")
        #expect(rect.minY > 30 + 100, "below the first chapter, not at the top of its own frame")
        #expect(recorder.selections == [selected])

        // Rects of the same range through the public API agree with the selection's.
        #expect(await host.session.rects(for: selected.range) == selected.rects)

        host.session.clearSelection()
        #expect(host.session.currentSelection == nil)
        try await host.waitUntil { recorder.selections.count == 2 }
        #expect(recorder.selections.last == .some(nil))
        try await host.waitUntil { try await self.hasSelection(host, spineIndex: 1) == false }
    }

    @Test func theChapterWithTheSelectionStaysInTheWindowUntilAMemoryWarningTakesItAndItsSelection() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        try await select(host, spineIndex: 1, id: "c1-p2", offset: 0, length: 11)
        try await host.waitUntil { host.session.currentSelection != nil }
        #expect(host.session.currentSelection?.text == "Paragraph 2")

        // Scroll on into chapter 3, as a script does (every pause is a rest: far chapters leave the window).
        for _ in 0..<120 where host.session.currentSpineIndex < 3 {
            try await host.scrollDocument(by: 900)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await host.waitForScrollRest()
        #expect(host.session.currentSpineIndex == 3)
        var state = try await host.scrollState()
        let selectedChapter = try #require(state.view(1), "the chapter with the selection left the window")
        #expect(selectedChapter.bottom < -8 * state.page, "the chapter is further away than the window keeps a chapter without a selection")
        #expect(!state.spineIndices.contains(0), "the chapter before it, without a selection, left")
        #expect(host.session.currentSelection?.text == "Paragraph 2")
        #expect(try await hasSelection(host, spineIndex: 1) == true)
        #expect(recorder.selections.count == 1)

        // A memory warning keeps only the chapters on screen and their neighbours (§12): the selection goes with its
        // chapter, and the text on screen stays where it is.
        let markedY = try #require(try await host.js("return window.__epubReader.debug.mark()") as? Double)
        let scrollY = state.scrollY
        host.session.didReceiveMemoryWarning()
        try await host.waitUntil { try await !host.scrollState().spineIndices.contains(1) }
        try await host.waitUntil { host.session.currentSelection == nil }
        #expect(recorder.selections.count == 2)
        #expect(recorder.selections.last == .some(nil))
        state = try await host.scrollState()
        #expect(state.scrollY == scrollY)
        #expect(abs((try #require(try await host.js("return window.__epubReader.debug.markY()") as? Double)) - markedY) < 0.5)
    }

    @Test func aJumpThatRebuildsTheWindowAndARelayoutClearTheSelection() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        try await host.waitUntil { try await host.scrollState().spineIndices.contains(2) }
        try await select(host, spineIndex: 1, id: "c1-p2", offset: 0, length: 11)
        try await host.waitUntil { host.session.currentSelection != nil }

        // A jump to a chapter of the window scrolls: the frames stay, and so does the selection.
        await host.session.go(toSpineIndex: 2)
        try await host.waitForScrollRest()
        #expect(host.session.currentSelection?.text == "Paragraph 2")
        #expect(try await hasSelection(host, spineIndex: 1) == true)

        // A jump to a chapter outside the window makes a new window: the selection goes with the old frames.
        try #require(try await !host.scrollState().spineIndices.contains(4))
        await host.session.go(toSpineIndex: 4)
        #expect(host.session.currentSelection == nil)
        #expect(recorder.selections.count == 2)
        #expect(recorder.selections.last == .some(nil))

        // A relayout lays the chapters out again in place: the selection is cleared there too.
        try await host.waitForScrollRest()
        try await select(host, spineIndex: 4, id: "c4-p1", offset: 0, length: 11)
        try await host.waitUntil { host.session.currentSelection != nil }
        host.session.settings.fontScale = 1.3
        try await host.waitUntil { !host.session.isLoading }
        #expect(host.session.currentSelection == nil)
        #expect(recorder.selections.count == 4)
        #expect(recorder.selections.last == .some(nil))
        try await host.waitUntil { try await self.hasSelection(host, spineIndex: 4) == false }
    }

    #if canImport(AppKit)
    @Test func selectionActionsAppearInTheContextMenu() async throws {
        let host = try await SessionHost.scrolled(url: Self.cfiSample)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        var received: [SelectedText] = []
        host.session.selectionActions = [
            SelectionAction(title: "Highlight", systemImage: "highlighter") { received.append($0) },
            SelectionAction(id: "copy-cfi", title: "Copy CFI") { _ in },
        ]
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Look Up", action: nil, keyEquivalent: ""))
        host.renderer.webView.appendSelectionActions(to: menu)
        #expect(menu.items.count == 1, "without a selection the menu is left alone")

        try await select(host, spineIndex: 0, id: "p2", offset: 0, length: 5)
        try await host.waitUntil { host.session.currentSelection != nil }
        host.renderer.webView.appendSelectionActions(to: menu)
        #expect(menu.items.map(\.title) == ["Highlight", "Copy CFI", "", "Look Up"])
        let item = menu.items[0]
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        #expect(received.count == 1)
        #expect(received.first?.text == "First")
        #expect(received.first == host.session.currentSelection)
    }
    #endif

    // MARK: Annotations (§10)

    @Test func highlightsAreDrawnInTheChaptersOfTheWindowAndInAChapterThatJoinsIt() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        let publication = host.session.publication
        let first = try await firstResult("Paragraph 2 of chapter 1", in: host)
        let third = try await firstResult("Paragraph 2 of chapter 3", in: host)
        #expect(first.spineIndex == 1 && third.spineIndex == 3)
        let inC1 = Annotation.highlight(first.range, in: publication)
        let inC3 = Annotation.highlight(third.range, in: publication, color: .pink, style: .underline)
        // Bookmarks are not drawn.
        let bookmark = Annotation.bookmark(at: first.range.start, in: publication)
        try #require(try await host.scrollState().spineIndices.contains(1))
        try #require(try await !host.scrollState().spineIndices.contains(3))
        host.session.annotations = [inC1, inC3, bookmark]

        // Each chapter of the window draws its own part.
        try await host.waitUntil { try await self.keys(host, spineIndex: 1) == [SelectionHighlightSearchTests.key(inC1)] }
        #expect(try await keys(host, spineIndex: 0) == [])
        #expect(!(await host.session.rects(for: first.range)).isEmpty)
        #expect(await host.session.rects(for: third.range).isEmpty, "the chapter is not in the window")
        let rule = try await host.js("return \(Self.frame(1)).contentDocument.getElementById('__reader_highlights').textContent;") as? String
        #expect(rule?.contains("::highlight(\(SelectionHighlightSearchTests.key(inC1))) { background-color: rgba(255, 204, 0, 0.4); }") == true)

        // A chapter that enters the window later draws what was set before it was there.
        await host.session.go(toSpineIndex: 3)
        try await host.waitUntil { try await self.keys(host, spineIndex: 3) == [SelectionHighlightSearchTests.key(inC3)] }
        let rule3 = try await host.js("return \(Self.frame(3)).contentDocument.getElementById('__reader_highlights').textContent;") as? String
        #expect(rule3?.contains("text-decoration: underline; text-decoration-color: rgba(255, 79, 139, 1.0)") == true)
        #expect(!(await host.session.rects(for: third.range)).isEmpty)

        // So does a chapter that comes back in a new window.
        try await host.waitForScrollRest()
        try #require(try await !host.scrollState().spineIndices.contains(1))
        await host.session.go(toSpineIndex: 1)
        try await host.waitUntil { try await self.keys(host, spineIndex: 1) == [SelectionHighlightSearchTests.key(inC1)] }

        // Removing from the set removes the drawing.
        host.session.annotations = []
        try await host.waitUntil { try await self.keys(host, spineIndex: 1) == [] }
    }

    @Test func tappingAHighlightReportsItsBoxesInTheReadersFrame() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample, insets: ReaderInsets(top: 30))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        // The chapter's frame starts above the reader's frame.
        try await host.scrollDocument(by: 77)
        try await host.waitForScrollRest()
        let result = try await firstResult("Paragraph 2 of chapter 1", in: host)
        let highlight = Annotation.highlight(result.range, in: host.session.publication)
        host.session.annotations = [highlight]
        try await host.waitUntil { try await self.keys(host, spineIndex: 1)?.count == 1 }
        let rects = await host.session.rects(for: result.range)
        let first = try #require(rects.first)
        // The highlight starts the paragraph: its box is the box of the paragraph's first words, where the chapter's
        // frame is (77 above the reading line, which is 30 below the reader's frame).
        let words = try await textBox(host, spineIndex: 1, id: "c1-p2", length: 11)
        #expect(abs(first.minX - words.minX) < 1 && abs(first.minY - words.minY) < 1, "\(first) at \(words)")
        #expect(try await host.scrollState().view(1)?.top == -47)

        _ = try await host.js("""
            const f = \(Self.frame(1));
            const b = f.getBoundingClientRect();
            f.contentDocument.getElementById("c1-p2").dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: \(first.midX) - b.left, clientY: \(first.midY) - b.top }));
            return true;
            """)
        try await host.waitUntil { !recorder.annotationTaps.isEmpty }
        #expect(recorder.annotationTaps.first?.id == highlight.id)
        #expect(recorder.annotationTaps.first?.rects == rects)
        #expect(recorder.taps.isEmpty)
    }

    @Test func publicationAnnotationsAreALayerUnderTheApps() async throws {
        let url = try AnnotationRenderingTests.sampleWithEmbeddedAnnotations()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitUntil { host.session.publicationAnnotations.count == 1 }
        let publicationKey = "reader-h-p_urn_x_embedded_1"
        try await host.waitUntil { try await self.keys(host, spineIndex: 0) == [publicationKey] }

        func tap() async throws {
            let rect = try #require(await host.session.rects(for: AnnotationRenderingTests.range(8, 15)).first)
            _ = try await host.js("""
                const f = \(Self.frame(0));
                const b = f.getBoundingClientRect();
                f.contentDocument.getElementById("p1").dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: \(rect.midX) - b.left, clientY: \(rect.midY) - b.top }));
                return true;
                """)
        }
        try await tap()
        try await host.waitUntil { recorder.annotationTaps.map(\.id) == ["urn:x:embedded:1"] }

        // The app's annotation on the same text is drawn above and wins the tap.
        let mine = Annotation.highlight(AnnotationRenderingTests.range(8, 15), in: host.session.publication, color: .pink)
        host.session.annotations = [mine]
        try await host.waitUntil { try await self.keys(host, spineIndex: 0)?.count == 2 }
        try await tap()
        try await host.waitUntil { recorder.annotationTaps.count == 2 }
        #expect(recorder.annotationTaps.last?.id == mine.id)

        host.session.showsPublicationAnnotations = false
        try await host.waitUntil { try await self.keys(host, spineIndex: 0) == [SelectionHighlightSearchTests.key(mine)] }
    }

    @Test func anOutlineFollowsARelayout() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        let result = try await firstResult("Paragraph 3 of chapter 1", in: host)
        host.session.annotations = [Annotation.highlight(result.range, in: host.session.publication, color: .purple, style: .outline)]

        /// The outline's box and the range's box, both in the chapter's own coordinates.
        func boxes() async throws -> (outline: [Double], range: [Double])? {
            let values = try await host.js("""
                const f = \(Self.frame(1));
                const box = f ? f.contentDocument.querySelector("#__reader_overlay > div") : null;
                if (!box) { return null; }
                const o = box.getBoundingClientRect();
                const r = f.contentWindow.__epubReader.rectsFor("\(result.range.description)")[0];
                return [o.left, o.top, o.width, o.height, r.x, r.y, r.width, r.height];
                """) as? [Double]
            return values.map { (Array($0[0..<4]), Array($0[4..<8])) }
        }
        try await host.waitUntil { try await boxes() != nil }
        let before = try #require(try await boxes())
        for k in 0..<4 { #expect(abs(before.outline[k] - before.range[k]) < 1) }

        host.session.settings.fontScale = 1.5
        try await host.waitUntil { !host.session.isLoading }
        try await host.waitForScrollRest()
        let after = try #require(try await boxes())
        #expect(after.range[3] > before.range[3] + 2, "the text is larger: \(before.range) → \(after.range)")
        for k in 0..<4 { #expect(abs(after.outline[k] - after.range[k]) < 1, "\(after.outline) around \(after.range)") }
    }

    // MARK: Search results (§10)

    @Test func aSearchResultGoesToTheReadingLineWithAHighlightThatLeavesWithTheNextMove() async throws {
        let host = try await SessionHost.scrolled(insets: ReaderInsets(top: 40))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        let near = try await firstResult("whale", in: host) { $0.spineIndex >= 6 }
        let far = try await firstResult("whale", in: host) { $0.spineIndex >= near.spineIndex + 4 }

        /// Where the result's first box is in the reader's frame.
        func top(_ result: SearchResult) async -> Double? {
            (await host.session.rects(for: result.range).first).map { Double($0.minY) }
        }

        // A chapter outside the window: a new window, the match on the reading line, marked.
        recorder.reset()
        await host.session.show(near)
        #expect(host.session.currentSpineIndex == near.spineIndex)
        #expect(try await hasTransient(host, spineIndex: near.spineIndex))
        let y = try #require(await top(near))
        #expect(abs(y - 40) < 2, "the match is at \(y)")
        #expect(recorder.navigations.map(\.cause) == [.jump])

        // Another chapter: the highlight follows the result.
        await host.session.show(far)
        #expect(host.session.currentSpineIndex == far.spineIndex)
        #expect(try await hasTransient(host, spineIndex: far.spineIndex))
        #expect(abs((try #require(await top(far))) - 40) < 2)

        // Scrolling that ends with the match still on screen keeps the highlight …
        try await scrollAndRest(host, by: -150)
        #expect(try await hasTransient(host, spineIndex: far.spineIndex))
        // … also right under the top inset's edge (the first line box is some 20 px tall) …
        try await scrollAndRest(host, by: 150 + 8)
        #expect(try await hasTransient(host, spineIndex: far.spineIndex))
        // … and scrolling that ends with it out of sight (here: under the top inset) removes it.
        try await scrollAndRest(host, by: 60)
        #expect(try await !hasTransient(host, spineIndex: far.spineIndex))
        // The session knows: showing the result again draws it again, and the next step removes that one.
        await host.session.show(far)
        #expect(try await hasTransient(host, spineIndex: far.spineIndex))
        try await scrollAndRest(host, by: 2000)
        #expect(try await !hasTransient(host, spineIndex: far.spineIndex))

        // A jump removes it,
        await host.session.show(far)
        #expect(try await hasTransient(host, spineIndex: far.spineIndex))
        await host.session.go(toPageInChapter: 0)
        #expect(try await !hasTransient(host, spineIndex: far.spineIndex))
        // and so does a step of one screen.
        await host.session.show(far)
        #expect(try await hasTransient(host, spineIndex: far.spineIndex))
        await host.session.goForward()
        #expect(try await !hasTransient(host, spineIndex: far.spineIndex))
    }

    // MARK: Links (§10)

    @Test func aLinkToAnotherChapterScrollsThereAndReportsTheTargetElement() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        #expect(host.session.layout == .scrolled)
        #expect(host.session.currentSpineIndex == 0)
        let start = try #require(host.session.position)

        try await click("to-c2", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        let cfi = try #require(recorder.internalLinks.first)
        #expect(host.session.publication.spineIndex(of: cfi) == 1)
        #expect(cfi.description.contains("[target]"))
        #expect(host.session.currentSpineIndex == 1)
        // The target is on the reading line, or as near to it as the end of the book lets it come.
        let target = try await box(host, spineIndex: 1, id: "target")
        #expect(abs(target.minY) < 1 || (host.session.isAtEnd && target.minY > 0 && target.maxY <= 600), "the target is at \(target.minY)")
        #expect(recorder.externalLinks.isEmpty)
        // The move is reported as a followed link, before `internalLink`.
        #expect(recorder.navigations.map(\.cause) == [.link])
        #expect(recorder.navigations.first?.from == start)
        #expect(recorder.navigations.first?.to.spineIndex == 1)
        #expect(recorder.moves.filter { $0 == "navigated(link)" || $0 == "link" } == ["navigated(link)", "link"])
        #expect(recorder.scrollings.isEmpty, "a followed link is not the reader's scrolling")

        // Without a fragment: the start of the chapter.
        await host.session.go(toSpineIndex: 0)
        recorder.reset()
        try await click("to-c2-start", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(host.session.currentSpineIndex == 1)
        #expect(host.session.currentPageIndex == 0)
        let chapter = try #require(try await host.scrollState().view(1))
        #expect(abs(chapter.top) < 1, "the chapter starts at \(chapter.top)")
    }

    @Test func aLinkWithinTheChapterScrollsToItsTarget() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url, insets: ReaderInsets(top: 24, bottom: 10))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()

        try await click("to-later", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(recorder.internalLinks.first?.description.contains("[later]") == true)
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex > 0)
        #expect(abs(try await box(host, spineIndex: 0, id: "later").minY - 24) < 1)
        #expect(recorder.navigations.map(\.cause) == [.link])

        // A link to the document on screen without a fragment goes to its start and reports the body.
        _ = try await host.js("""
            const doc = \(Self.frame(0)).contentDocument;
            const a = doc.createElementNS("http://www.w3.org/1999/xhtml", "a");
            a.id = "self"; a.setAttribute("href", "c1.xhtml"); a.textContent = "link";
            const later = doc.getElementById("later");
            later.insertBefore(a, later.firstChild);
            return true;
            """)
        recorder.reset()
        try await click("self", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == 0)
        #expect(host.session.isAtStart)
        #expect(recorder.internalLinks.first?.description == "epubcfi(/6/2[c1]!/4)")
    }

    @Test func anExternalLinkIsReportedWithoutMoving() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        recorder.reset()
        try await click("external", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.externalLinks.isEmpty }
        #expect(recorder.externalLinks == [URL(string: "https://example.com/page?q=1")!])
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.session.isAtStart)
        #expect(recorder.internalLinks.isEmpty && recorder.navigations.isEmpty && recorder.taps.isEmpty)
    }

    // MARK: Notes (§10)

    @Test func aNoterefOfTheSameChapterCarriesTheNoteAndTheNoteIsNotOnThePage() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url, insets: ReaderInsets(top: 30))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.scrollDocument(by: 21)
        try await host.waitForScrollRest()

        // The same rule as in pages: the aside a noteref of its document points at is out of the flow.
        let display = try await host.js("""
            const doc = \(Self.frame(0)).contentDocument;
            const d = id => doc.defaultView.getComputedStyle(doc.getElementById(id)).display;
            return [d("fn1"), d("unreferenced"), d("hidden-div")];
            """) as? [String]
        #expect(display == ["none", "block", "none"])

        let before = try #require(host.session.position)
        try await click("ref1", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let note = try #require(recorder.notes.first)
        #expect(note.isInSameDocument)
        #expect(note.path == "OPS/c1.xhtml")
        #expect(note.fragment == "fn1")
        #expect(note.spineIndex == 0)
        #expect(note.text == "The first footnote.")
        #expect(note.html?.contains("<b") == true)
        #expect(note.cfi?.description.contains("[fn1]") == true)
        #expect(note.isHidden)
        // The noteref's box, in the reader's frame (the chapter's frame is 30 − 21 below its top).
        let anchor = try await box(host, spineIndex: 0, id: "ref1")
        #expect(abs(note.sourceRect.minX - anchor.minX) < 1 && abs(note.sourceRect.minY - anchor.minY) < 1, "\(note.sourceRect) at \(anchor)")
        #expect(note.sourceRect.width > 0 && note.sourceRect.height > 0)
        // The session does not move for a noteref.
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.session.position == before)
        #expect(recorder.internalLinks.isEmpty && recorder.navigations.isEmpty)

        // A note that is an ordinary paragraph of the chapter stays on the page: the app can go to it.
        // (Its noteref is in the chapter's last lines.)
        await host.session.goToChapterEdge(end: true)
        try await host.waitForScrollRest()
        recorder.reset()
        try await click("ref4", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let onPage = try #require(recorder.notes.first)
        #expect(onPage.fragment == "pn1")
        #expect(onPage.text == "4. The note that is part of the page.")
        #expect(!onPage.isHidden)
        await host.session.go(toSpineIndex: 0)
        await host.session.go(to: try #require(onPage.cfi))
        #expect(host.session.currentSpineIndex == 0)
        #expect(abs(try await box(host, spineIndex: 0, id: "pn1").minY - 30) < 1)
    }

    @Test func aNoterefIntoAnotherDocumentResolvesTheNoteThroughEPUBCore() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()

        try await click("ref2", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let aside = try #require(recorder.notes.first)
        #expect(!aside.isInSameDocument)
        #expect(aside.path == "OPS/notes.xhtml")
        #expect(aside.spineIndex == 2)
        #expect(aside.html == nil)
        #expect(aside.text == "The endnote text.")
        #expect(!aside.isHidden)
        #expect(aside.cfi?.description.contains("[en1]") == true)
        let anchor = try await box(host, spineIndex: 0, id: "ref2")
        #expect(abs(aside.sourceRect.minX - anchor.minX) < 1 && abs(aside.sourceRect.minY - anchor.minY) < 1)

        // The app can go to the note: the non-linear notes document opens alone, at the note.
        recorder.reset()
        try await click("ref3", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let anchored = try #require(recorder.notes.first)
        #expect(anchored.text == "3. An anchored endnote in a paragraph.")
        await host.session.go(to: try #require(anchored.cfi))
        #expect(host.session.currentSpineIndex == 2)
        #expect(host.session.layout == .scrolled)
    }

    /// The note of another document is read after the tap. When the reader scrolled meanwhile, the noteref's box is
    /// somewhere else (also within the same virtual page): nothing is reported.
    @Test func aNoterefWhoseNoteIsReadAfterTheReaderScrolledIsDropped() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()

        var finished = 0
        host.session.noterefLookupDidFinish = {
            // Twenty pixels: the same virtual page, another place on screen.
            try? await self.scrollAndRest(host, by: 20)
            finished += 1
        }
        try await click("ref2", spineIndex: 0, in: host)
        try await host.waitUntil { finished == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.session.currentPageIndex == 0)
        #expect(recorder.notes.isEmpty, "the popover's anchor is not where it was")

        // A lookup during which nothing moved is reported, also when the controller reports its position meanwhile.
        host.session.noterefLookupDidFinish = {
            try? await Task.sleep(for: .milliseconds(300))
            finished += 1
        }
        try await click("ref2", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        #expect(recorder.notes.first?.text == "The endnote text.")
    }

    // MARK: Images (§10)

    @Test func anImageTapCarriesTheBoxAndTheBytesWhereverItIs() async throws {
        let url = try Self.linksSample()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost.scrolled(url: url, insets: ReaderInsets(top: 30))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.scrollDocument(by: 13)
        try await host.waitForScrollRest()

        try await click("plain", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.images.isEmpty }
        let image = try #require(recorder.images.first)
        #expect(image.path == "OPS/picture.png")
        #expect(image.alt == "A picture")
        let expected = try await box(host, spineIndex: 0, id: "plain")
        #expect(abs(image.rect.minX - expected.minX) < 1 && abs(image.rect.minY - expected.minY) < 1, "\(image.rect) at \(expected)")
        #expect(abs(image.rect.width - 120) < 1 && abs(image.rect.height - 80) < 1)
        #expect(image.rect.contains(image.point))
        // Near the left edge of the frame, where the paged layout's session reports the same thing and EPUBUI turns
        // the page: here there is nothing to turn (§3.3).
        #expect(image.point.x < 100)
        #expect(try await image.data().starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(recorder.taps.isEmpty)

        // An image inside a link is the link.
        recorder.reset()
        try await click("in-link", spineIndex: 0, in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(recorder.images.isEmpty)
        #expect(host.session.currentSpineIndex == 1)
    }

    // MARK: The reader's own scrolling (§3.2, §3.3)

    @Test func scrollingByHandIsReportedFromItsFirstMoveToItsRest() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        #expect(!host.session.isScrolling)
        #expect(recorder.scrollings.isEmpty, "loading and jumping are not the reader's scrolling")
        recorder.reset()
        let start = try #require(host.session.position)

        // A finger rests on the text: nothing has moved yet.
        _ = try await host.js("return window.__epubReader.setInteraction({active: true})")
        try await Task.sleep(for: .milliseconds(250))
        #expect(!host.session.isScrolling)
        #expect(recorder.scrollings.isEmpty)

        // It drags: one `scrolling(true)`, however many steps.
        for _ in 0..<6 {
            try await host.scrollDocument(by: 200)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await host.waitUntil { host.session.isScrolling }
        #expect(recorder.scrollings == [true])

        // It holds the text still: that is not the end.
        try await Task.sleep(for: .milliseconds(400))
        #expect(host.session.isScrolling)
        #expect(recorder.scrollings == [true])
        #expect(recorder.navigations.isEmpty)

        // It lifts, and the text is at rest.
        _ = try await host.js("return window.__epubReader.setInteraction({active: false})")
        try await host.waitUntil { recorder.scrollings == [true, false] }
        #expect(!host.session.isScrolling)
        // Before `scrolling(false)`: the position the scrolling stopped at, then the move.
        let moves = recorder.moves
        #expect(moves.last == "scrolling-")
        #expect(moves.dropLast().last == "navigated(scroll)", "\(moves)")
        #expect(moves.dropLast(2).last == "position", "\(moves)")
        #expect(recorder.navigations.map(\.cause) == [.scroll])
        #expect(recorder.navigations.first?.from == start)
        #expect(recorder.navigations.first?.to == host.session.position)
        #expect(recorder.positions.last == host.session.position)
        #expect(host.session.position != start)
    }

    @Test func scrollingThatEndsOnThePagesItBeganOnIsNotAMove() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await scrollAndRest(host, by: 100)
        recorder.reset()
        let pages = host.session.visiblePages

        _ = try await host.js("return window.__epubReader.setInteraction({active: true})")
        try await host.scrollDocument(by: 60)
        try await host.waitUntil { host.session.isScrolling }
        try await host.scrollDocument(by: -40)
        _ = try await host.js("return window.__epubReader.setInteraction({active: false})")
        try await host.waitUntil { recorder.scrollings == [true, false] }
        #expect(!host.session.isScrolling)
        #expect(host.session.visiblePages == pages)
        #expect(recorder.navigations.isEmpty)
        #expect(recorder.moves.last == "scrolling-")
        #expect(recorder.positions.last == host.session.position)
    }

    @Test func stepsAndJumpsAreNotScrollingAndTheArrowKeysAre() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        await host.session.goForward()
        await host.session.goBackward()
        await host.session.go(toSpineIndex: 3)
        await host.session.go(toPage: 1)
        try await host.waitForScrollRest()
        #expect(recorder.scrollings.isEmpty)
        #expect(!host.session.isScrolling)
        #expect(Set(recorder.navigations.map(\.cause)) == [.jump, .pageTurn])

        // ↑ ↓ scroll a few lines as the reader's own scrolling (§8.2).
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        recorder.reset()
        host.session.scrollByLines(3)
        try await host.waitUntil { recorder.scrollings.first == true }
        try await host.waitUntil { recorder.scrollings == [true, false] }
        #expect(!host.session.isScrolling)
        #expect(recorder.moves.last == "scrolling-")
        #expect(try await host.scrollState().scrollY > 0)
        #expect(recorder.navigations.allSatisfy { $0.cause == .scroll })

        // At the end of the book the key moves nothing: nothing is reported.
        await host.session.go(toSpineIndex: 4)
        try await host.scrollDocument(to: 10_000_000)
        try await host.waitForScrollRest()
        #expect(host.session.isAtEnd)
        recorder.reset()
        host.session.scrollByLines(3)
        try await Task.sleep(for: .milliseconds(400))
        #expect(recorder.scrollings.isEmpty)
    }

    @Test func aJumpEndsTheReadersScrolling() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        recorder.reset()

        _ = try await host.js("return window.__epubReader.setInteraction({active: true})")
        for _ in 0..<5 {
            try await host.scrollDocument(by: 300)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await host.waitUntil { host.session.isScrolling }
        // The finger is still down when the app jumps (a table-of-contents entry).
        await host.session.go(toSpineIndex: 3)
        #expect(!host.session.isScrolling)
        #expect(host.session.currentSpineIndex == 3)
        try await host.waitUntil { recorder.moves.contains("navigated(jump)") }
        #expect(recorder.scrollings == [true, false])
        let moves = recorder.moves
        let ended = try #require(moves.firstIndex(of: "scrolling-"))
        let jumped = try #require(moves.firstIndex(of: "navigated(jump)"))
        #expect(ended < jumped, "\(moves)")
        // The jump starts where the scrolling got to, not at the position published up to a second earlier.
        let scroll = try #require(recorder.navigations.first { $0.cause == .scroll })
        let jump = try #require(recorder.navigations.first { $0.cause == .jump })
        #expect(jump.from == scroll.to)
        #expect(scroll.to.spineIndex == 1 && scroll.to.progressionInChapter > 0)
        try await host.waitForScrollRest()
        #expect(recorder.scrollings == [true, false])
    }

    /// The controller writes the scroll position itself when it puts the runway right at rest. That write's `scroll`
    /// event arrives with the next frame: hands that come to the text in between have not moved it.
    @Test func theControllersOwnWriteOfTheScrollPositionIsNotTheReadersScrolling() async throws {
        let host = try await ScrollStabilityTests().hostInsideChapter8()
        let recorder = EventRecorder(host.session)
        // A chapter added above under the reader's hands leaves the runway off its target (its height is not the
        // estimate); when they let go the runway is settled, which writes the scroll position; they touch again at once.
        let wrote = try await host.js("""
            const reader = window.__epubReader, dbg = reader.debug;
            reader.setInteraction({ active: true });
            await dbg.prepend();
            await new Promise(function (r) { setTimeout(r, 300); });
            const before = window.scrollY;
            reader.setInteraction({ active: false });
            const wrote = window.scrollY !== before;
            reader.setInteraction({ active: true });
            await new Promise(function (r) { setTimeout(r, 300); });
            return wrote;
            """) as? Bool
        #expect(wrote == true, "the settlement wrote the scroll position (the test needs a chapter whose height is not its estimate)")
        #expect(try await host.scrollState().interacting)
        #expect(try await host.scrollState().userScrolling == false)
        #expect(!host.session.isScrolling)
        #expect(recorder.scrollings.isEmpty)
        _ = try await host.js("return window.__epubReader.setInteraction({ active: false })")
        try await host.waitForScrollRest()
        #expect(recorder.scrollings.isEmpty)
    }

    /// The rest is where the mark of a search result is dropped and the reader's scrolling ends, so it must be
    /// reported after every scroll event, also the one a jump made while it was still placing the window (a page that
    /// gets no frames, as this test's, takes longer for that than the scroll takes to be quiet).
    @Test func theRestAfterAJumpWithinTheWindowIsReported() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        for end in [true, false, true] {
            await host.session.goToChapterEdge(end: end)
            try await host.waitForScrollRest(timeout: .seconds(3))
            #expect(try await host.scrollState().restPosted)
        }
    }

    // MARK: Recovery and memory (§12)

    @Test func aCrashReloadsTheScrollDocumentAtTheSamePosition() async throws {
        let host = try await SessionHost.scrolled(insets: ReaderInsets(top: 50, bottom: 30))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        try await host.scrollDocument(by: 1234)
        try await host.waitForScrollRest()
        let before = try #require(host.session.position)
        let page = host.session.currentPageIndex
        #expect(page == 2)
        recorder.reset()

        let crashed = RecoveryTests.crashWebContent(of: host.renderer)
        try await host.waitUntil { recorder.errors.contains { if case .webContentTerminated = $0 { true } else { false } } }
        // No script call before the document is back: a killed process only returns with the next load. The position
        // is the one it was, so nothing is published for it: the load itself tells when the document is back.
        try await host.waitUntil { host.session.isLoading }
        try await host.waitUntil(timeout: .seconds(15)) { !host.session.isLoading && host.session.hasLoaded }
        #expect(recorder.positions.allSatisfy { $0 == before }, "the same text, the same position")
        #expect(host.session.layout == .scrolled)
        #expect(host.session.currentSpineIndex == 6)
        #expect(host.session.currentPageIndex == page)
        #expect(!host.renderer.isContentHidden)
        #expect(!host.session.isScrolling)
        // The text of the position is back on the reading line.
        let y = try #require(try await host.js("""
            const f = \(Self.frame(6));
            const offset = f.contentWindow.__epubReader.scroll.offsetForCFI("\(before.cfi.description)");
            return f.getBoundingClientRect().top + offset;
            """) as? Double)
        #expect(abs(y - 50) < 1, "restored at \(y)")
        #expect(host.session.position?.spineIndex == 6)
        #expect(recorder.errors.count == 1, "one webContentTerminated, nothing else (real crash: \(crashed)): \(recorder.errors)")
        #expect(recorder.navigations.isEmpty, "coming back is not a move")
        // Reading goes on.
        try await host.waitForScrollRest()
        await host.session.goForward()
        #expect(host.session.currentPageIndex == page + 1 || host.session.currentPageIndex == page)
        #expect(try await host.scrollState().scrollY > 0)
        #expect(recorder.navigations.map(\.cause) == [.pageTurn])
    }

    /// A jump that rebuilds the window is "loading" as a chapter load of the paged layout is: a crash during it is
    /// answered by going where the jump was going.
    @Test func aCrashDuringAJumpEndsAtTheJumpsTarget() async throws {
        let host = try await SessionHost.scrolled()
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        let navigation = Task { await host.session.go(toSpineIndex: 8) }
        try await host.waitUntil { host.session.isLoading }
        RecoveryTests.crashWebContent(of: host.renderer)
        await navigation.value
        do {
            try await host.waitUntil(timeout: .seconds(15)) { host.session.currentSpineIndex == 8 && !host.session.isLoading && host.session.hasLoaded }
        } catch {
            Issue.record("after the crash: chapter \(host.session.currentSpineIndex), loading \(host.session.isLoading), loaded \(host.session.hasLoaded), errors \(recorder.errors)")
            throw error
        }
        #expect(host.session.layout == .scrolled)
        #expect(recorder.errors.contains { if case .webContentTerminated = $0 { true } else { false } })
        #expect(recorder.errors.count == 1, "\(recorder.errors)")
        #expect(try await host.scrollState().spineIndices.contains(8))
    }

    /// The crash can come before the jump has asked the document for its target: while the reader's scrolling is
    /// being stopped, or while the picture that covers the rebuilt window is taken. It is a jump in progress all the
    /// same. (The crash is the session's own entry point here, so that it comes at a known moment.)
    @Test(arguments: [false, true]) func aCrashAtTheStartOfAJumpEndsAtTheJumpsTarget(onceLoading: Bool) async throws {
        let host = try await SessionHost.scrolled()
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        let navigation = Task { await host.session.go(toSpineIndex: 8) }
        // The first time the jump lets anything else run, or the first time after it has said that it is loading.
        await Task.yield()
        if onceLoading { while !host.session.isLoading { await Task.yield() } }
        host.session.webContentProcessDidTerminate()
        await navigation.value
        do {
            try await host.waitUntil(timeout: .seconds(15)) { host.session.currentSpineIndex == 8 && !host.session.isLoading && host.session.hasLoaded }
        } catch {
            Issue.record("after the crash: chapter \(host.session.currentSpineIndex), loading \(host.session.isLoading), loaded \(host.session.hasLoaded), errors \(recorder.errors)")
            throw error
        }
        try await host.waitForScrollRest()
        #expect(host.session.currentSpineIndex == 8)
        #expect(recorder.errors.count == 1, "\(recorder.errors)")
        #expect(try await host.scrollState().spineIndices.contains(8))
    }

    @Test func navigationAfterTheReloadLimitLoadsTheScrollDocumentAgain() async throws {
        let host = try await SessionHost.scrolled()
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        try await host.scrollDocument(by: 700)
        try await host.waitForScrollRest()
        let position = try #require(host.session.position)
        for crash in 1...ReaderSession.maximumAutomaticReloads {
            host.session.webContentProcessDidTerminate()
            try await host.waitUntil(timeout: .seconds(15)) {
                recorder.errors.count == crash && host.session.hasLoaded && !host.session.isLoading
            }
        }
        host.session.webContentProcessDidTerminate()
        #expect(!host.session.hasLoaded)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!host.session.hasLoaded, "no reload after the limit")
        #expect(host.renderer.isContentHidden)

        recorder.reset()
        await host.session.go(to: position)
        #expect(host.session.hasLoaded)
        #expect(host.session.layout == .scrolled)
        #expect(host.session.currentSpineIndex == 6)
        #expect(host.session.currentPageIndex == 1)
        #expect(!host.renderer.isContentHidden)
        #expect(try await host.scrollState().spineIndices.contains(6))
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.navigations.isEmpty, "loading the same place again is not a move")
    }

    @Test func aCrashWhileTheReaderScrollsEndsTheScrolling() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        recorder.reset()
        _ = try await host.js("return window.__epubReader.setInteraction({active: true})")
        try await host.scrollDocument(by: 300)
        try await host.waitUntil { host.session.isScrolling }

        // The document that would have reported the end is gone.
        RecoveryTests.crashWebContent(of: host.renderer)
        try await host.waitUntil { recorder.scrollings == [true, false] }
        #expect(!host.session.isScrolling)
        #expect(!recorder.errors.isEmpty)
        try await host.waitUntil { host.session.isLoading }
        try await host.waitUntil(timeout: .seconds(15)) { host.session.hasLoaded && !host.session.isLoading }
        #expect(recorder.scrollings == [true, false])
    }
}
