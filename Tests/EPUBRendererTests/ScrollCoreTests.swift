import Foundation
import JavaScriptCore
import Testing
@testable import EPUBRenderer

/// The rules of the scrolled layout that need no DOM (`Reader/scroll-core.js`, docs/design/08-continuous-scroll.md
/// §5): the script the scroll controller runs is loaded into JavaScriptCore and called with numbers.
@Suite struct ScrollCoreTests {
    let context: JSContext

    init() throws {
        let url = try #require(WebViewSpineRenderer.readerScriptURL(named: "scroll-core"))
        let context = try #require(JSContext())
        context.exceptionHandler = { _, exception in
            Issue.record("JavaScript exception: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        self.context = context
    }

    /// Evaluates an expression with `core` bound to the rules and returns it through JSON.
    func eval<T: Decodable>(_ expression: String, as type: T.Type = T.self) throws -> T {
        let value = context.evaluateScript("(function () { const core = globalThis.__epubScrollCore; return JSON.stringify(\(expression)); })()")
        let json = try #require(value?.toString())
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    struct Upper: Decodable, Equatable { var pad: Double; var neg: Double }
    struct Settlement: Decodable, Equatable { var needed: Bool; var pad: Double; var neg: Double }
    struct Fit: Decodable, Equatable { var height: Double; var fixed: Bool }
    struct Step: Decodable, Equatable { var top: Double; var moved: Bool }

    // MARK: The space above the window

    @Test func aCorrectionComesOutOfTheRunway() throws {
        // The text at the reading line moved 300 px down (a chapter above grew): the runway gives 300 px back.
        #expect(try eval("core.correction(1000, 0, 300)") == Upper(pad: 700, neg: 0))
        // It moved up (a chapter above shrank): the runway grows.
        #expect(try eval("core.correction(1000, 0, -120)") == Upper(pad: 1120, neg: 0))
    }

    @Test func aCorrectionLargerThanTheRunwayBecomesANegativeMargin() throws {
        #expect(try eval("core.correction(200, 0, 300)") == Upper(pad: 0, neg: 100))
        #expect(try eval("core.correction(0, 0, 50)") == Upper(pad: 0, neg: 50))
        // And a later correction the other way takes the margin back before the runway grows again.
        #expect(try eval("core.correction(0, 100, -40)") == Upper(pad: 0, neg: 60))
        #expect(try eval("core.correction(0, 100, -250)") == Upper(pad: 150, neg: 0))
    }

    @Test func theRunwayIsTheChaptersBeforeTheWindowAndTheTailTheOnesAfterIt() throws {
        #expect(try eval("core.runwayTarget([100, 200, 300, 400], 0)", as: Double.self) == 0.0)
        #expect(try eval("core.runwayTarget([100, 200, 300, 400], 2)", as: Double.self) == 300.0)
        #expect(try eval("core.tailTarget([100, 200, 300, 400], 1)", as: Double.self) == 700.0)
        // The last chapter is in the window: nothing is added after the book (§0).
        #expect(try eval("core.tailTarget([100, 200, 300, 400], 3)", as: Double.self) == 0.0)
        // A book taller than the engine can lay out: each space stops at the limit (the last chapter still ends the tail).
        #expect(try eval("core.maxSpace", as: Double.self) == 8_000_000.0)
        #expect(try eval("core.runwayTarget([30000000, 30000000, 300, 400], 2)", as: Double.self) == 8_000_000.0)
        #expect(try eval("core.runwayTarget([30000000, 30000000, 300, 400], 0)", as: Double.self) == 0.0)
        #expect(try eval("core.tailTarget([100, 200, 30000000, 30000000], 1)", as: Double.self) == 8_000_000.0)
        #expect(try eval("core.tailTarget([100, 200, 30000000, 30000000], 3)", as: Double.self) == 0.0)
    }

    @Test func theSettlementPutsTheRunwayOnItsTargetAndClearsTheMargin() throws {
        #expect(try eval("core.settlement(700, 0, 1000)") == Settlement(needed: true, pad: 1000, neg: 0))
        #expect(try eval("core.settlement(0, 80, 0)") == Settlement(needed: true, pad: 0, neg: 0))
        #expect(try eval("core.settlement(1000, 0, 1000.2)", as: Settlement.self).needed == false)
    }

    @Test func theSettledScrollPositionFollowsTheTextInTheViewport() throws {
        // The runway grew by 300: the text moved 300 down in the viewport, the scroll position follows.
        #expect(try eval("core.settledScrollTop(5000, 100, 400, 90000)", as: Double.self) == 5300.0)
        // At the document's end the browser already clamped the position when the runway shrank: the text did not
        // move in the viewport, and nothing is added on top.
        #expect(try eval("core.settledScrollTop(8000, 250, 250, 8000)", as: Double.self) == 8000.0)
        // Never outside the scroll range.
        #expect(try eval("core.settledScrollTop(100, 400, 100, 9000)", as: Double.self) == 0.0)
        #expect(try eval("core.settledScrollTop(8900, 0, 500, 9000)", as: Double.self) == 9000.0)
    }

    // MARK: The window

    @Test func aChapterJoinsWithinTwoPagesOfTheViewport() throws {
        let far = "{busy: false, pageHeight: 600, above: 5000, below: 5000, hasPrevious: true, hasNext: true}"
        #expect(try eval("core.windowAction(\(far))", as: String?.self) == nil)
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 5000, below: 1199, hasPrevious: true, hasNext: true})", as: String.self) == "append")
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 1199, below: 5000, hasPrevious: true, hasNext: true})", as: String.self) == "prepend")
        // Both ends are near: the nearer one first, the end below on a tie.
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 100, below: 300, hasPrevious: true, hasNext: true})", as: String.self) == "prepend")
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 300, below: 300, hasPrevious: true, hasNext: true})", as: String.self) == "append")
    }

    @Test func nothingJoinsWhileAChapterLoadsOrAtTheEndsOfTheBook() throws {
        #expect(try eval("core.windowAction({busy: true, pageHeight: 600, above: 0, below: 0, hasPrevious: true, hasNext: true})", as: String?.self) == nil)
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 0, below: 0, hasPrevious: false, hasNext: false})", as: String?.self) == nil)
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 0, below: 9000, hasPrevious: false, hasNext: true})", as: String?.self) == nil)
    }

    @Test func theNeighbourOfAVisibleChapterJoinsHoweverLongTheChapterIs() throws {
        // One chapter 20 pages long fills the window and the viewport is in its middle: both ends are far, but the
        // chapters before and after it still load (the window is "the visible chapters and one more on each side").
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 6000, below: 6001, hasPrevious: true, hasNext: true, firstVisible: true, lastVisible: true})", as: String.self) == "prepend")
        #expect(try eval("core.windowAction({busy: false, pageHeight: 600, above: 6000, below: 6000, hasPrevious: false, hasNext: true, firstVisible: true, lastVisible: true})", as: String.self) == "append")
    }

    /// Chapters 1000 px tall stacked from `top`, as `removals` takes them.
    func views(count: Int, top: Double, keep: Set<Int> = []) -> String {
        let items = (0..<count).map { k in
            "{pos: \(k), top: \(top + Double(k) * 1000), bottom: \(top + Double(k + 1) * 1000), keep: \(keep.contains(k))}"
        }
        return "[" + items.joined(separator: ", ") + "]"
    }

    @Test func farChaptersLeaveOnlyAtRest() throws {
        // Viewport 600 tall inside chapter 12 of 14: chapters more than 8 pages (4800 px) above it are far.
        let window = views(count: 14, top: -12_000)
        #expect(try eval("core.removals({views: \(window), viewportHeight: 600, pageHeight: 600, atRest: false})", as: [Int].self).isEmpty)
        // At rest the far ones go, from the end inwards: chapter 7 ends 4000 px above the viewport and stays.
        #expect(try eval("core.removals({views: \(window), viewportHeight: 600, pageHeight: 600, atRest: true})", as: [Int].self) == [0, 1, 2, 3, 4, 5, 6])
        // VoiceOver is running: they stay.
        #expect(try eval("core.removals({views: \(window), viewportHeight: 600, pageHeight: 600, atRest: true, holdFar: true})", as: [Int].self).isEmpty)
    }

    @Test func theWindowIsCappedEvenWhileScrolling() throws {
        // 30 chapters, the viewport in the last one, the reader's finger still down.
        let window = views(count: 30, top: -29_000)
        let removed = try eval("core.removals({views: \(window), viewportHeight: 600, pageHeight: 600, atRest: false})", as: [Int].self)
        #expect(removed == [0, 1, 2, 3, 4, 5], "the furthest go until 24 are left")
        // A smaller limit, the viewport in the middle: both ends give way, the far side first.
        let middle = views(count: 9, top: -4_000)
        #expect(try eval("core.removals({views: \(middle), viewportHeight: 600, pageHeight: 600, atRest: false, limit: 5})", as: [Int].self) == [8, 0, 7, 1])
    }

    @Test func visibleChaptersTheirNeighboursAndKeptChaptersStay() throws {
        // The viewport shows chapters 3 and 4 (the boundary is on screen).
        let window = views(count: 8, top: -3_700)
        // A memory warning trims everything but the visible chapters and one on each side.
        #expect(try eval("core.removals({views: \(window), viewportHeight: 600, pageHeight: 600, atRest: false, trim: true})", as: [Int].self) == [0, 1, 7, 6])
        // A chapter that holds the selection stays, and so does everything between it and the viewport (the window
        // is one run of chapters).
        let selecting = views(count: 8, top: -3_700, keep: [1])
        #expect(try eval("core.removals({views: \(selecting), viewportHeight: 600, pageHeight: 600, atRest: false, trim: true})", as: [Int].self) == [0, 7, 6])
    }

    @Test func aWindowTheViewportRanPastKeepsItsNearestChapter() throws {
        // The viewport is 20,000 px below the window's end (a very fast scroll, §5.5).
        let window = views(count: 5, top: -25_000)
        let removed = try eval("core.removals({views: \(window), viewportHeight: 600, pageHeight: 600, atRest: true})", as: [Int].self)
        #expect(removed == [0, 1, 2], "the last chapter and its neighbour stay so the window can grow from there")
    }

    // MARK: Frames

    @Test func aFrameTakesTheHeightOfItsContent() throws {
        // The content is 2400 px whatever the frame's height.
        #expect(try eval("(function () { let frame = 600; return core.fit(frame, 2400, function () { return 2400; }, function (h) { frame = h; }); })()") == Fit(height: 2400, fixed: false))
        // Already fitted: nothing changes.
        #expect(try eval("(function () { let calls = 0; const r = core.fit(2400, 2400, function () { return 2400; }, function () { calls++; }); return {height: r.height, fixed: r.fixed && calls === 0}; })()") == Fit(height: 2400, fixed: false))
    }

    @Test func aContentThatSettlesAfterOneMoreStepIsNotPinned() throws {
        // A footer pinned to the bottom adds 40 px once the frame is as tall as the content, then stays.
        let script = """
        (function () {
          let frame = 600;
          const measure = function () { return frame < 2400 ? 2400 : 2440; };
          return core.fit(frame, 2400, measure, function (h) { frame = h; });
        })()
        """
        #expect(try eval(script) == Fit(height: 2440, fixed: false))
    }

    @Test func aContentSizedInViewportUnitsIsPinnedToItsFirstHeight() throws {
        // `height: 100vh` plus a caption: the content is always 80 px taller than its frame. Loaded in a frame one
        // page (600) tall it was 680; fitting the frame makes it grow again, every time.
        let script = """
        (function () {
          let frame = 600, applied = [];
          const r = core.fit(frame, 680, function () { return frame + 80; }, function (h) { frame = h; applied.push(h); });
          return {height: r.height, fixed: r.fixed && frame === 680 && applied.length === 4};
        })()
        """
        #expect(try eval(script) == Fit(height: 680, fixed: true))
    }

    // MARK: Steps

    @Test func aPageStepIsOnePageLessOneLine() throws {
        #expect(try eval("core.scrollTarget({pages: 1, pageHeight: 600, lineHeight: 26, scrollY: 1000, maxScroll: 90000})") == Step(top: 1574, moved: true))
        #expect(try eval("core.scrollTarget({pages: -1, pageHeight: 600, lineHeight: 26, scrollY: 1000, maxScroll: 90000})") == Step(top: 426, moved: true))
        #expect(try eval("core.scrollTarget({lines: 3, pageHeight: 600, lineHeight: 26, scrollY: 1000, maxScroll: 90000})") == Step(top: 1078, moved: true))
    }

    @Test func aStepStopsAtTheEndsAndSaysWhenNothingMoved() throws {
        #expect(try eval("core.scrollTarget({pages: 1, pageHeight: 600, lineHeight: 26, scrollY: 89900, maxScroll: 90000})") == Step(top: 90000, moved: true))
        #expect(try eval("core.scrollTarget({pages: 1, pageHeight: 600, lineHeight: 26, scrollY: 90000, maxScroll: 90000})") == Step(top: 90000, moved: false))
        #expect(try eval("core.scrollTarget({pages: -1, pageHeight: 600, lineHeight: 26, scrollY: 0, maxScroll: 90000})") == Step(top: 0, moved: false))
    }

    @Test func aStepDuringAnAnimatedScrollStartsFromItsTarget() throws {
        // A second ↓ while the first is still animating: three more lines from where the first one ends.
        #expect(try eval("core.scrollTarget({lines: 3, pageHeight: 600, lineHeight: 26, scrollY: 1010, from: 1078, maxScroll: 90000})") == Step(top: 1156, moved: true))
    }
}
