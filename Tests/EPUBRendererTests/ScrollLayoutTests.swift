import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// What the scroll controller says about itself (`window.__epubReader.debug.state()`).
struct ScrollDebugState: Decodable {
    struct View: Decodable {
        var pos: Int
        var spineIndex: Int
        var height: Double
        var loaded: Bool
        var fixed: Bool
        var top: Double
        var bottom: Double
    }

    var pad: Double
    var neg: Double
    var tail: Double
    var page: Double
    var generation: Int
    var dirty: Bool
    var scrollY: Double
    var maxScroll: Double
    var viewportHeight: Double
    var atRest: Bool
    /// The position after the last scroll event has reached Swift as a position at rest.
    var restPosted: Bool
    var interacting: Bool
    var program: Bool
    var loading: Int?
    var runwayTarget: Double
    var visibility: String
    var views: [View]

    var spineIndices: [Int] { views.map(\.spineIndex) }
    func view(_ spineIndex: Int) -> View? { views.first { $0.spineIndex == spineIndex } }
}

extension SessionHost {
    static func scrolled(url: URL = ReaderSessionTests.mobyDick, size: CGSize = CGSize(width: 400, height: 600), insets: ReaderInsets = ReaderInsets(), initialPosition: ReadingPosition? = nil, configure: (inout ReaderSettings) -> Void = { _ in }) async throws -> SessionHost {
        var settings = ReaderSettings()
        settings.layout = .scrolled
        configure(&settings)
        let host = try await SessionHost(url: url, settings: settings, size: size, initialPosition: initialPosition, insets: insets)
        return host
    }

    func scrollState() async throws -> ScrollDebugState {
        let json = try await js("return JSON.stringify(window.__epubReader.debug.state())") as? String
        return try JSONDecoder().decode(ScrollDebugState.self, from: Data(try #require(json).utf8))
    }

    /// Waits until nothing is loading and the controller is at rest with its runway settled.
    func waitForScrollRest(timeout: Duration = .seconds(10)) async throws {
        try await waitUntil(timeout: timeout) {
            let state = try await self.scrollState()
            return state.atRest && state.restPosted && state.loading == nil && !state.dirty && state.views.allSatisfy(\.loaded)
        }
    }

    /// Scrolls the document as a script does (no interaction is reported to the controller).
    func scrollDocument(to y: Double) async throws {
        _ = try await js("window.scrollTo(0, \(y)); return window.scrollY")
    }

    func scrollDocument(by dy: Double) async throws {
        _ = try await js("window.scrollBy(0, \(dy)); return window.scrollY")
    }
}

/// The scrolled layout end to end on a real web view (docs/design/08-continuous-scroll.md, milestone S1): opening,
/// which books get it, positions, jumps, steps, the window, relayout and the switch between the layouts.
@Suite(.serialized) @MainActor struct ScrollLayoutTests {
    static let mobyDick = ReaderSessionTests.mobyDick
    static let sample = ReaderSessionTests.fixtures.appendingPathComponent("scroll-sample.epub")

    @Test func opensABookAsOneScrollingDocument() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        let session = host.session
        #expect(session.hasLoaded)
        #expect(!session.isLoading)
        #expect(session.layout == .scrolled)
        #expect(session.currentSpineIndex == 1) // the cover is linear="no"
        #expect(session.currentPageIndex == 0)
        #expect(session.isAtStart)
        #expect(!session.isAtEnd)
        #expect(!session.isShowingSpread)
        #expect(session.visibleSpineIndices.first == 1)
        #expect(session.position?.spineIndex == 1)
        #expect(session.currentPage == 0)

        let state = try await host.scrollState()
        #expect(state.page == 600)
        #expect(state.scrollY == 0)
        #expect(state.pad == 0, "nothing is before the first chapter")
        #expect(state.tail > 0, "the chapters after the window are stood in for")
        #expect(state.spineIndices.first == 1)
        // The frame is the visible area, not three page slots, and the document scrolls vertically only.
        let frame = try await host.js("return {w: window.innerWidth, h: window.innerHeight, sw: document.scrollingElement.scrollWidth, sh: document.scrollingElement.scrollHeight}") as? [String: Any]
        #expect(frame?["w"] as? Int == 400)
        #expect(frame?["h"] as? Int == 600)
        #expect(frame?["sw"] as? Int == 400)
        #expect((frame?["sh"] as? Double ?? 0) > 6000)

        // The neighbours load without anybody scrolling.
        try await host.waitUntil { try await host.scrollState().spineIndices.contains(2) }
    }

    // MARK: Which books are scrolled (§1)

    @Test func aFixedLayoutBookStaysPaged() async throws {
        let host = try await SessionHost.scrolled(url: FixedLayoutSpreadTests.haruko)
        await host.session.loadIfNeeded()
        #expect(host.session.hasLoaded)
        #expect(host.session.settings.layout == .scrolled)
        #expect(host.session.layout == .paged, "the app can tell that this book is paged only")
        await host.session.goForward()
        #expect(host.session.currentSpineIndex > 0, "and it turns pages as before")
    }

    @Test func aRightToLeftBookStaysPaged() async throws {
        let host = try await SessionHost.scrolled(url: RightToLeftTests.arabic)
        await host.session.loadIfNeeded()
        #expect(host.session.hasLoaded)
        #expect(host.session.layout == .paged)
        #expect(host.session.isRightToLeft)
    }

    @Test func aBookInVerticalWritingGoesBackToPagesOnceAChapterShowsIt() async throws {
        let host = try await SessionHost.scrolled(url: VerticalWritingTests.kusamakura)
        await host.session.loadIfNeeded()
        // The first chapters may be horizontal (a cover, a title page): the book is paged at the latest when a
        // vertical chapter has been loaded, here or as a neighbour.
        try await host.waitUntil { host.session.layout == .paged && host.session.hasLoaded && !host.session.isLoading }
        let vertical = try #require(host.session.publication.linearReadingOrder.map(\.index).dropFirst(2).first)
        await host.session.go(toSpineIndex: vertical)
        try await host.waitUntil { !host.session.isLoading }
        #expect(host.session.layout == .paged)
        #expect(host.session.currentSpineIndex == vertical)
        #expect(host.session.writingMode.isVertical)
        // And it stays paged for the rest of the session, whatever is opened next.
        await host.session.go(toSpineIndex: try #require(host.session.publication.linearReadingOrder.first?.index))
        #expect(host.session.layout == .paged)
    }

    @Test func thePagedLayoutIsUntouchedByTheScrolledSettings() async throws {
        // The default is paged, and a text width for the scrolled layout changes nothing in it.
        let host = try await SessionHost(url: Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        #expect(host.session.layout == .paged)
        let pages = host.session.chapterPageCount
        host.session.settings.scrolledTextWidth = 20
        try await host.waitUntil { !host.session.isLoading }
        #expect(host.session.chapterPageCount == pages)
        let attribute = try await host.js("return document.documentElement.getAttribute('data-reader-layout')")
        #expect(attribute == nil || attribute is NSNull)
    }

    // MARK: Chapter CSS (§4.2)

    @Test func theTextIsOneColumnAsWideAsTheSettingAndCenteredInAWideFrame() async throws {
        let host = try await SessionHost.scrolled(size: CGSize(width: 1100, height: 700))
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        func box() async throws -> [String: Double] {
            let value = try await host.js("""
                const f = document.querySelector('#__reader_stage > iframe[data-spine-index="6"]');
                const d = f.contentDocument, root = d.documentElement;
                const p = d.querySelector('p');
                const r = p.getBoundingClientRect(), cs = getComputedStyle(root);
                return { left: r.left, right: r.right, frame: f.clientWidth, rem: parseFloat(cs.fontSize),
                         columns: cs.columnCount === 'auto' ? 0 : parseFloat(cs.columnCount), scrollW: root.scrollWidth };
                """) as? [String: Double]
            return try #require(value)
        }
        var b = try await box()
        #expect(b["frame"] == 1100)
        #expect(b["columns"] == 0, "no multi-column layout")
        #expect(b["scrollW"] == 1100, "nothing overflows sideways")
        let rem = try #require(b["rem"])
        // 36 em of text in the middle of the frame (the horizontal margins are outside it).
        let width = try #require(b["right"]) - (try #require(b["left"]))
        #expect(rem == 16)
        #expect(abs(width - 36 * rem) < 1, "text is \(width) px wide at \(rem) px")
        #expect(abs((try #require(b["left"])) - (1100 - (try #require(b["right"])))) < 2, "centered")

        host.session.settings.scrolledTextWidth = 24
        try await host.waitUntil { !host.session.isLoading }
        b = try await box()
        #expect(abs((try #require(b["right"])) - (try #require(b["left"])) - 24 * rem) < 1)
        // The width is in em of the body text: it grows with the font size.
        host.session.settings.fontScale = 1.5
        try await host.waitUntil { !host.session.isLoading }
        b = try await box()
        #expect(abs((try #require(b["right"])) - (try #require(b["left"])) - 24 * rem * 1.5) < 1)

        // A frame narrower than the setting: the frame less the margins.
        let narrow = try await SessionHost.scrolled(size: CGSize(width: 400, height: 600))
        await narrow.session.loadIfNeeded()
        await narrow.session.go(toSpineIndex: 6)
        let n = try #require(try await narrow.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="6"]');
            const r = f.contentDocument.querySelector('p').getBoundingClientRect();
            return { left: r.left, right: r.right };
            """) as? [String: Double])
        #expect(abs((n["left"] ?? 0) - 24) < 1)
        #expect(abs((n["right"] ?? 0) - 376) < 1)
    }

    // MARK: Position (§7)

    /// Where the text a CFI names is, in the frame's coordinates (the top of its first line box).
    func top(of cfi: CFI, in host: SessionHost) async throws -> Double? {
        try await host.js("""
            const cfi = "\(cfi.description)";
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="\(host.session.publication.spineIndex(of: cfi) ?? -1)"]');
            const bridge = f ? f.contentWindow.__epubReader : null;
            if (!bridge || !bridge.scroll) { return null; }
            const offset = bridge.scroll.offsetForCFI(cfi);
            return offset === null || offset === undefined ? null : f.getBoundingClientRect().top + offset;
            """) as? Double
    }

    @Test func thePositionIsTheTextAtTheReadingLineAndRestoresThere() async throws {
        let insets = ReaderInsets(top: 50, bottom: 30)
        let host = try await SessionHost.scrolled(insets: insets)
        await host.session.loadIfNeeded()
        #expect(try await host.scrollState().page == 520, "the page is the frame less the insets")
        await host.session.go(toSpineIndex: 6)
        // Somewhere in the middle of the chapter, not on a page boundary.
        try await host.scrollDocument(by: 1234)
        try await host.waitForScrollRest()
        let position = try #require(host.session.position)
        #expect(position.spineIndex == 6)
        let y = try #require(try await top(of: position.cfi, in: host))
        // The first line of text that reaches below the reading line (50 below the frame's top): it starts less
        // than a line above the reading line, or just below it.
        #expect(y > 50 - 40 && y < 50 + 40, "the position's text is at \(y)")
        #expect(host.session.currentPageIndex == 2, "1234 px into the chapter is the third page of 520")
        #expect(position.progressionInChapter > 0)

        // A new session opened at that position: the same text, exactly on the reading line.
        let restored = try await SessionHost.scrolled(insets: insets, initialPosition: position)
        await restored.session.loadIfNeeded()
        #expect(restored.session.currentSpineIndex == 6)
        let restoredY = try #require(try await top(of: position.cfi, in: restored))
        #expect(abs(restoredY - 50) < 1, "restored at \(restoredY)")
        #expect(restored.session.position?.cfi == position.cfi)
        // The first chapter of the book was never shown.
        #expect(try await !restored.scrollState().spineIndices.contains(1))
    }

    @Test func scrollingMovesThePositionAcrossChaptersAndReportsItAtRest() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        #expect(host.session.currentSpineIndex == 0)
        recorder.reset()

        // Scroll in steps, as a hand would, to just before the end of the cover chapter.
        let state = try await host.scrollState()
        let cover = try #require(state.view(0))
        let steps = 12
        for k in 1...steps {
            try await host.scrollDocument(to: (cover.height - 200) * Double(k) / Double(steps))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await host.waitForScrollRest()
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.visibleSpineIndices == [0, 1], "both chapters at the boundary are visible")
        // While it scrolled the position came at most once a second; at rest it always comes.
        #expect(recorder.positions.count >= 1 && recorder.positions.count <= 2)
        #expect(recorder.positions.last == host.session.position)
        #expect(recorder.navigations.isEmpty, "scrolling by hand is not reported as a jump or a page turn")

        try await host.scrollDocument(by: 300)
        try await host.waitForScrollRest()
        #expect(host.session.currentSpineIndex == 1)
        #expect(host.session.position?.spineIndex == 1)
        #expect(host.session.currentPageIndex == 0)
        #expect(!host.session.isAtStart)
    }

    // MARK: Jumps (§8.1)

    @Test func jumpsPutTheirTargetOnTheReadingLine() async throws {
        let insets = ReaderInsets(top: 40, bottom: 0)
        let host = try await SessionHost.scrolled(url: Self.sample, insets: insets)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        let start = try #require(host.session.position)

        // A chapter outside the window: a new window, the chapter's top on the reading line.
        await host.session.go(toSpineIndex: 3)
        #expect(host.session.currentSpineIndex == 3)
        #expect(!host.session.isLoading)
        #expect(host.session.relayoutSnapshot == nil)
        var state = try await host.scrollState()
        #expect(abs((try #require(state.view(3)).top) - 40) < 1)
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.jump])
        #expect(recorder.navigations.first?.from == start)
        #expect(recorder.navigations.first?.to.cfi == host.session.position?.cfi)

        // A table-of-contents entry with a fragment, in a chapter next to the window.
        let entry = try #require(host.session.publication.toc.first { $0.fragment == "c2-long" })
        await host.session.go(to: entry)
        #expect(host.session.currentSpineIndex == 2)
        let fragmentTop = try #require(try await host.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="2"]');
            return f.getBoundingClientRect().top + f.contentDocument.getElementById("c2-long").getBoundingClientRect().top;
            """) as? Double)
        #expect(abs(fragmentTop - 40) < 1, "the fragment's element is at \(fragmentTop)")

        // A page of the chapter, and a page of the book.
        await host.session.go(toPageInChapter: 1)
        #expect(host.session.currentSpineIndex == 2)
        #expect(host.session.currentPageIndex == 1)
        state = try await host.scrollState()
        #expect(abs(40 - (try #require(state.view(2)).top) - state.page) < 1, "the top of page 1 is one page below the chapter's top")
        let page = try #require(host.session.pagination.chapter(spineIndex: 1)).firstPage + 1
        await host.session.go(toPage: page)
        #expect(host.session.currentSpineIndex == 1)
        #expect(host.session.currentPage == page)

        // A CFI, and the same CFI again: nothing moves and nothing is reported.
        let there = try #require(host.session.position)
        await host.session.go(toSpineIndex: 3)
        // Events arrive on a stream: wait for the last jump's before counting from here.
        try await host.waitUntil { recorder.navigations.last?.to.cfi == host.session.position?.cfi }
        recorder.reset()
        await host.session.go(to: there)
        #expect(host.session.position?.cfi == there.cfi)
        #expect(abs((try #require(try await top(of: there.cfi, in: host))) - 40) < 1)
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.jump])
        recorder.reset()
        await host.session.go(to: there)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.navigations.isEmpty)
    }

    @Test func aNonLinearItemIsShownAloneAndTheWayBackLoadsTheFlowAgain() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 5)
        #expect(host.session.layout == .scrolled)
        #expect(host.session.currentSpineIndex == 5)
        var state = try await host.scrollState()
        #expect(state.spineIndices == [5])
        #expect(state.pad == 0 && state.tail == 0, "nothing before or after it")
        #expect(host.session.isAtStart)
        #expect(host.session.currentPage == nil, "a non-linear item has no book page")
        // Scrolling to its end does not continue into another chapter.
        try await host.scrollDocument(to: state.maxScroll)
        try await host.waitForScrollRest()
        #expect(host.session.isAtEnd)
        #expect(host.session.currentSpineIndex == 5)
        #expect(try await host.scrollState().spineIndices == [5])

        await host.session.go(toSpineIndex: 2)
        #expect(host.session.currentSpineIndex == 2)
        state = try await host.scrollState()
        #expect(state.spineIndices.contains(2))
        #expect(!state.spineIndices.contains(5))
        #expect(state.pad > 0, "the flow of the linear items is back")
    }

    // MARK: Steps (§8.2)

    @Test func forwardAndBackwardScrollOneScreenLessOneLine() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitUntil { !recorder.navigations.isEmpty }
        recorder.reset()
        let before = try await host.scrollState()
        let from = try #require(host.session.position)

        await host.session.goForward()
        let after = try await host.scrollState()
        let moved = after.scrollY - before.scrollY
        #expect(moved > 600 - 60 && moved < 600 - 10, "one screen of 600 less a line: \(moved)")
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.pageTurn])
        // The place, not the whole position: the fraction of the book moves whenever a chapter is measured.
        #expect(recorder.navigations.first?.from?.cfi == from.cfi)
        #expect(recorder.navigations.first?.to.cfi == host.session.position?.cfi)
        #expect(host.session.position?.cfi != from.cfi)

        recorder.reset()
        await host.session.goBackward()
        #expect(try await host.scrollState().scrollY == before.scrollY, "a step forward and a step back end where they started")
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.pageTurn])
    }

    @Test func stepsStopAtTheEndsOfTheBookAndReportNothingThere() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        #expect(host.session.isAtStart)
        await host.session.goBackward()
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.navigations.isEmpty)
        #expect(host.session.isAtStart)

        // The last chapter is shorter than the frame: at the very end the reading line is still in chapter 3.
        await host.session.go(toSpineIndex: 4)
        try await host.waitForScrollRest()
        try await host.waitUntil { !recorder.navigations.isEmpty }
        let state = try await host.scrollState()
        #expect(abs(state.scrollY - state.maxScroll) < 1, "the jump stops at the end of the document")
        #expect(state.tail == 0, "nothing is added after the book")
        #expect(host.session.isAtEnd)
        #expect(host.session.currentSpineIndex == 3)
        #expect(host.session.visibleSpineIndices == [3, 4])
        // There the position is the last page and all of the book (§6.1).
        #expect(host.session.currentPage == host.session.pagination.totalPages - 1)
        #expect(host.session.totalProgression == 1)
        #expect(host.session.position?.totalProgression == 1)
        // The last line of the book sits on the bottom of the frame.
        let last = try #require(state.view(4))
        #expect(abs(last.bottom - 600) < 1)

        recorder.reset()
        await host.session.goForward()
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.navigations.isEmpty)
        #expect(host.session.isAtEnd)
    }

    @Test func arrowKeysScrollAFewLinesAndHomeAndEndGoToTheChaptersEdges() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await host.waitForScrollRest()
        let before = try await host.scrollState()
        let line = try #require(try await host.js("""
            return document.querySelector('#__reader_stage > iframe[data-spine-index="1"]').contentWindow.__epubReader.scroll.lineHeight();
            """) as? Double)
        #expect(line > 15 && line < 40)

        host.session.scrollByLines(3)
        try await host.waitUntil { try await host.scrollState().scrollY > before.scrollY + 1 }
        try await host.waitForScrollRest()
        #expect(abs(try await host.scrollState().scrollY - before.scrollY - 3 * line) < 1)
        #expect(host.session.currentSpineIndex == 1)
        // Two presses in a row add up (key repeat).
        host.session.scrollByLines(3)
        host.session.scrollByLines(3)
        try await host.waitUntil { try await abs(host.scrollState().scrollY - (before.scrollY + 9 * line)) < 2 }
        try await host.waitForScrollRest()
        host.session.scrollByLines(-3)
        try await host.waitUntil { try await abs(host.scrollState().scrollY - (before.scrollY + 6 * line)) < 2 }
        try await host.waitForScrollRest()

        await host.session.goToChapterEdge(end: true)
        var state = try await host.scrollState()
        #expect(host.session.currentSpineIndex == 1)
        #expect(abs((try #require(state.view(1)).bottom) - 600) < 1, "the chapter's end is at the bottom of the frame")
        #expect(host.session.currentPageIndex == host.session.chapterPageCount - 1 || host.session.currentPageIndex == host.session.chapterPageCount - 2)
        await host.session.goToChapterEdge(end: false)
        state = try await host.scrollState()
        #expect(abs(try #require(state.view(1)).top) < 1)
        #expect(host.session.currentPageIndex == 0)
    }

    // MARK: Taps (§9)

    @Test func everyTapIsACenterTap() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        // A tap near the left edge of the frame, where the paged layout turns the page back.
        _ = try await host.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="1"]');
            const el = f.contentDocument.getElementById("c1-p3");
            const r = el.getBoundingClientRect();
            el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: 10, clientY: r.top + 5 }));
            return true;
            """)
        try await host.waitUntil { recorder.events.contains { if case .tapped = $0 { true } else { false } } }
        let taps = recorder.events.compactMap { event -> (CGPoint, TapZone)? in
            if case .tapped(let point, let zone) = event { return (point, zone) }
            return nil
        }
        #expect(taps.count == 1)
        #expect(taps.first?.1 == .center)
        // The point is in the frame's coordinates: the chapter's own offset in the document is added.
        let expected = try #require(try await host.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="1"]');
            return f.getBoundingClientRect().top + f.contentDocument.getElementById("c1-p3").getBoundingClientRect().top + 5;
            """) as? Double)
        #expect(abs(Double(taps.first?.0.y ?? 0) - expected) < 1)
        #expect(abs(Double(taps.first?.0.x ?? 0) - 10) < 1)
        #expect(await host.session.pageSnapshot(.current) == nil, "there is no page turn to draw")
    }

    // MARK: The window (§5.1)

    @Test func theWindowFollowsTheViewportAndDropsFarChaptersAtRest() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 20)
        try await host.waitForScrollRest()
        var state = try await host.scrollState()
        #expect(state.spineIndices.contains(19) && state.spineIndices.contains(21), "the neighbours of the visible chapter are loaded")
        #expect(abs(state.pad - state.runwayTarget) < 1)

        // Scroll far down in steps; chapters join below as the viewport comes near them.
        for _ in 0..<40 {
            try await host.scrollDocument(by: 1500)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await host.waitForScrollRest()
        state = try await host.scrollState()
        let current = host.session.currentSpineIndex
        #expect(current > 22)
        #expect(state.spineIndices.contains(current + 1))
        #expect(state.spineIndices == Array(state.spineIndices.first!...state.spineIndices.last!), "the window is one run of chapters")
        // At rest nothing further than eight pages from the viewport is kept.
        for view in state.views where view.spineIndex < current - 1 {
            #expect(view.bottom > -8 * state.page, "chapter \(view.spineIndex) ends \(-view.bottom) px above the viewport")
        }
        #expect(!state.spineIndices.contains(20))
        // The runway stands in for the chapters that left: the document did not shrink above the reader.
        #expect(abs(state.pad - state.runwayTarget) < 1)
        #expect(state.neg == 0)
        #expect(host.session.currentPage != nil)
    }

    @Test func aMemoryWarningShrinksTheWindowToTheVisibleChaptersAndTheirNeighbours() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 20)
        for _ in 0..<6 {
            try await host.scrollDocument(by: 1200)
            try await Task.sleep(for: .milliseconds(40))
        }
        // Hold the window as it is: the reader's hand is on the screen, so nothing is at rest.
        _ = try await host.js("return window.__epubReader.setInteraction({active: true})")
        // The chapters the scrolling passed are still in the window, and the ones ahead have arrived (on a busy
        // machine the page handles the last scroll events after this point).
        try await host.waitUntil {
            let state = try await host.scrollState()
            return state.loading == nil && state.views.count > host.session.visibleSpineIndices.count + 2
        }
        let before = try await host.scrollState()
        let visible = Set(host.session.visibleSpineIndices)
        #expect(before.views.count > visible.count + 2, "the window holds more than the visible chapters and their neighbours")
        let markedY = try #require(try await host.js("return window.__epubReader.debug.mark()") as? Double)

        host.session.didReceiveMemoryWarning()
        try await host.waitUntil { try await host.scrollState().views.count < before.views.count }
        let after = try await host.scrollState()
        let kept = Set(after.spineIndices)
        #expect(kept.isSuperset(of: visible))
        #expect(kept.count <= visible.count + 2)
        // The scroll position was not written and the text did not move.
        #expect(after.scrollY == before.scrollY)
        #expect(abs((try #require(try await host.js("return window.__epubReader.debug.markY()") as? Double)) - markedY) < 0.5)
        _ = try await host.js("return window.__epubReader.setInteraction({active: false})")
    }

    // MARK: Relayout and the switch between the layouts (§11, §7)

    @Test func aSettingsChangeKeepsTheTextAtTheReadingLine() async throws {
        let host = try await SessionHost.scrolled()
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        try await host.scrollDocument(by: 2000)
        try await host.waitForScrollRest()
        let before = try #require(host.session.position)
        let generation = host.session.scrollGeneration
        let height = try #require(try await host.scrollState().view(6)).height
        recorder.reset()

        host.session.settings.fontScale = 1.4
        #expect(host.session.isLoading)
        try await host.waitUntil { !host.session.isLoading }
        // The picture that covered the relayout goes away with it (a moment later when the chapter was loaded again).
        try await host.waitUntil(timeout: .seconds(2)) { host.session.relayoutSnapshot == nil }
        #expect(host.session.layout == .scrolled)
        #expect(host.session.scrollGeneration > generation)
        let state = try await host.scrollState()
        #expect(state.generation == host.session.scrollGeneration)
        #expect((try #require(state.view(6))).height > height * 1.2, "the chapter was laid out again")
        // The text that was at the reading line is on it again. The position is the start of the line it is in now,
        // which the new line breaks may have moved a few words back.
        #expect(abs((try #require(try await top(of: before.cfi, in: host))) - 0) < 1, "the same text is on the reading line")
        let after = try #require(host.session.position)
        #expect(abs((try #require(try await top(of: after.cfi, in: host))) - 0) < 1)
        #expect(recorder.navigations.isEmpty, "a relayout is not a move")

        // The theme alone: the heights stay, the colours change.
        let measured = host.session.scrollHeights
        host.session.settings.theme = .dark
        try await host.waitUntil { !host.session.isLoading }
        #expect(host.session.scrollHeights[6] == measured[6])
        let background = try await host.js("return getComputedStyle(document.documentElement).backgroundColor") as? String
        #expect(background != "rgb(255, 255, 255)")
        #expect(host.session.position?.cfi == after.cfi, "nothing reflowed: the position is the same text")
    }

    @Test func aNewFrameSizeOrNewInsetsLayOutAgainForTheNewPage() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        try await host.scrollDocument(by: 1500)
        try await host.waitForScrollRest()
        let before = try #require(host.session.position)
        let pages = host.session.chapterPageCount

        host.session.contentInsets = ReaderInsets(top: 60, bottom: 40)
        try await host.waitUntil { !host.session.isLoading }
        var state = try await host.scrollState()
        #expect(state.page == 500)
        #expect(host.session.chapterPageCount > pages, "shorter pages, more of them")
        #expect(host.session.position?.cfi == before.cfi, "nothing reflowed: the position is the same text")
        #expect(abs((try #require(try await top(of: before.cfi, in: host))) - 60) < 1)
        let limit = try await host.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="6"]');
            return getComputedStyle(f.contentDocument.documentElement).getPropertyValue("--reader-page-height").trim();
            """) as? String
        #expect(limit == "500px", "images are limited to the new page height")

        #if canImport(AppKit)
        host.window.setContentSize(CGSize(width: 520, height: 700))
        #endif
        host.session.viewportSize = CGSize(width: 520, height: 700)
        try await host.waitUntil { !host.session.isLoading }
        state = try await host.scrollState()
        #expect(state.page == 600)
        #expect(state.viewportHeight == 700)
        #expect(abs((try #require(try await top(of: before.cfi, in: host))) - 60) < 1, "the same text is on the reading line in the wider frame")
    }

    @Test func switchingToPagesAndBackKeepsThePositionWithinAPage() async throws {
        let host = try await SessionHost.scrolled()
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        try await host.scrollDocument(by: 1777)
        try await host.waitForScrollRest()
        let scrolled = try #require(host.session.position)

        host.session.settings.layout = .paged
        try await host.waitUntil { !host.session.isLoading && host.session.layout == .paged }
        #expect(host.session.currentSpineIndex == 6)
        // The picture that covered the relayout goes away with it (a moment later when the chapter was loaded again).
        try await host.waitUntil(timeout: .seconds(2)) { host.session.relayoutSnapshot == nil }
        // The page that holds the text is shown; the position is that page's first text.
        let page = try #require(try await host.renderer.pageFor(scrolled.cfi))
        #expect(host.session.currentPageIndex == page)
        let paged = try #require(host.session.position)
        // The paged setup is back: three page slots, no vertical scrolling.
        let frame = try await host.js("return {w: window.innerWidth, wrapper: !!window.__epubReader.isScrollWrapper}") as? [String: Any]
        #expect(frame?["w"] as? Int == 1200)
        #expect(frame?["wrapper"] as? Bool == false)
        await host.session.goForward()
        #expect(host.session.currentPageIndex == page + 1, "and pages turn")
        await host.session.goBackward()

        host.session.settings.layout = .scrolled
        try await host.waitUntil { !host.session.isLoading && host.session.layout == .scrolled }
        #expect(host.session.currentSpineIndex == 6)
        // The reading line is on the page's first text: at most a page above the text it was on before, which is
        // still on screen (§7).
        #expect(abs((try #require(try await top(of: paged.cfi, in: host))) - 0) < 1)
        let original = try #require(try await top(of: scrolled.cfi, in: host))
        #expect(original >= -1 && original < 600, "the text read before the round trip is at \(original)")
    }

    // MARK: Heights (§4.2, §4.3)

    @Test func chapterHeightsOfAnotherLayoutAreDropped() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample)
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        let generation = host.session.scrollGeneration
        let known = try #require(host.session.scrollHeights[1])
        func post(height: Double, generation: Int) async throws {
            _ = try await host.js("""
                window.webkit.messageHandlers.reader.postMessage({type: "chapterHeight", payload: {spineIndex: 1, height: \(height), generation: \(generation), fixed: false}});
                return true;
                """)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await post(height: 987_654, generation: generation - 1)
        #expect(host.session.scrollHeights[1] == known, "a height measured for the layout before this one says nothing")
        try await post(height: 987_654, generation: generation)
        #expect(host.session.scrollHeights[1] == 987_654)
        // A position of another layout is dropped the same way.
        let page = host.session.currentPageIndex
        _ = try await host.js("""
            window.webkit.messageHandlers.reader.postMessage({type: "scrolled", payload: {spineIndex: 3, offset: 4000, chapterHeight: 9000, visible: [3], atEnd: false, atStart: false, cfi: null, generation: \(generation - 1), rest: true}});
            return true;
            """)
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == page)
    }

    @Test func aCoverSizedInViewportUnitsIsOnePageTallAndStopsGrowing() async throws {
        let host = try await SessionHost.scrolled(url: Self.sample, insets: ReaderInsets(top: 40, bottom: 20))
        await host.session.loadIfNeeded()
        try await host.waitForScrollRest()
        var state = try await host.scrollState()
        let cover = try #require(state.view(0))
        #expect(cover.fixed, "the chapter's height depends on its frame: it is pinned")
        // `100vh` was resolved against a frame one page (540) tall; the caption follows it.
        let box = try #require(try await host.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="0"]');
            const d = f.contentDocument;
            return { cover: d.getElementById("cover").getBoundingClientRect().height, caption: d.getElementById("caption").getBoundingClientRect().bottom };
            """) as? [String: Double])
        #expect(cover.height > 540 && cover.height < 540 + 200, "one page and a caption: \(cover.height)")
        // Pinned means stable: the same height a second later, and the session heard it once.
        try await Task.sleep(for: .milliseconds(600))
        state = try await host.scrollState()
        #expect((try #require(state.view(0))).height == cover.height)
        #expect(host.session.scrollHeights[0] == cover.height)
        #expect((box["cover"] ?? 0) >= 540, "the cover fills at least a page (\(box["cover"] ?? 0))")
        #expect(host.session.chapterPageCount == 2)
        // The chapters after it are where its pinned height puts them.
        #expect(abs((try #require(state.view(1))).top - (40 + cover.height)) < 1)
    }
}
