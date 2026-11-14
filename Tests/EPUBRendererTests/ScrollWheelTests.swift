#if canImport(AppKit)
import AppKit
import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Scroll-wheel events as a trackpad sends them: a gesture (`began`, `changed`…, `ended`) and the momentum the system
/// adds after it (`began`, `changed`…, `ended`). They are handed to the web view as AppKit would hand them, so they
/// pass the session's own handler (which decides whether the reader's hands are on the document, and withholds the
/// rest of a gesture that was stopped) and scroll the page as WebKit scrolls for a real trackpad.
@MainActor
struct TrackpadEvents {
    let view: NSView

    enum Phase: Int64 { case none = 0, began = 1, changed = 2, ended = 4, mayBegin = 128 }
    enum Momentum: Int64 { case none = 0, began = 1, changed = 2, ended = 3 }

    /// One event; `dy` > 0 scrolls the document down (the content moves up), as a two-finger swipe up does.
    func send(dy: Int, phase: Phase = .none, momentum: Momentum = .none) throws {
        let window = try #require(view.window)
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-dy), wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum.rawValue)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(-dy))
        // Over the middle of the view, in the window: without the window the event has no place in it.
        let inWindow = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        event.location = CGPoint(x: onScreen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - onScreen.y)
        // kCGMouseEventWindowUnderMousePointer and …ThatCanHandleThisEvent.
        event.setIntegerValueField(try #require(CGEventField(rawValue: 91)), value: Int64(window.windowNumber))
        event.setIntegerValueField(try #require(CGEventField(rawValue: 92)), value: Int64(window.windowNumber))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    }

    /// The fingers go down and move: `frames` events of `dy` each, one per display frame.
    func drag(dy: Int, frames: Int) async throws {
        try send(dy: 0, phase: .mayBegin)
        try send(dy: dy, phase: .began)
        for _ in 1..<frames {
            try await Task.sleep(for: .milliseconds(16))
            try send(dy: dy, phase: .changed)
        }
    }

    /// The fingers lift and the momentum starts.
    func release(dy: Int) throws {
        try send(dy: 0, phase: .ended)
        try send(dy: dy, momentum: .began)
    }
}

/// The scrolled layout under a trackpad on macOS (docs/design/08-continuous-scroll.md §5.6, §14): the interaction
/// is seen, a chapter added above during the momentum goes into the runway, and a jump stops the momentum.
@Suite(.serialized) @MainActor struct ScrollWheelTests {
    struct Sample: Decodable {
        var markY: Double?
        var scrollY: Double
        var pad: Double
        var neg: Double
        var interacting: Bool
        var views: [Int]
    }

    func sample(_ host: SessionHost) async throws -> Sample {
        let json = try #require(try await host.js("""
            const d = window.__epubReader.debug, s = d.state();
            return JSON.stringify({ markY: d.markY(), scrollY: s.scrollY, pad: s.pad, neg: s.neg, interacting: s.interacting, views: s.views.map(function (v) { return v.spineIndex; }) });
            """) as? String)
        return try JSONDecoder().decode(Sample.self, from: Data(json.utf8))
    }

    struct LogEvent: Decodable {
        var ev: String
        var t: Double
        var by: Double?
        var reason: String?
        var index: Int?
        var active: Bool?
    }

    func drainLog(_ host: SessionHost) async throws -> [LogEvent] {
        let json = try #require(try await host.js("return JSON.stringify(window.__epubReader.debug.drainLog())") as? String)
        return try JSONDecoder().decode([LogEvent].self, from: Data(json.utf8))
    }

    @Test func aGestureAndItsMomentumAreOneInteractionAndRestComesAfterThem() async throws {
        let host = try await ScrollStabilityTests().hostInsideChapter8()
        let trackpad = TrackpadEvents(view: host.renderer.webView)
        let start = try await host.scrollState()
        #expect(!start.interacting && start.atRest)

        try await trackpad.drag(dy: 30, frames: 8)
        var state = try await host.scrollState()
        #expect(state.interacting, "fingers on the trackpad")
        #expect(state.scrollY > start.scrollY + 100, "the document follows the fingers: \(state.scrollY - start.scrollY)")
        #expect(!host.session.isAtStart)

        try trackpad.release(dy: 28)
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 20, momentum: .changed)
        }
        state = try await host.scrollState()
        #expect(state.interacting, "the momentum is still the reader's scroll")
        #expect(!state.atRest)
        let moving = state.scrollY

        try trackpad.send(dy: 0, momentum: .ended)
        try await host.waitUntil { try await !host.scrollState().interacting }
        try await host.waitForScrollRest()
        state = try await host.scrollState()
        #expect(state.atRest && !state.dirty)
        #expect(state.scrollY >= moving)
        // The position follows: the session publishes the place the scroll ended at.
        let location = try #require(try await host.renderer.locationAtReadingLine())
        #expect(host.session.position?.cfi == location.cfi)
    }

    @Test func aChapterAddedAboveDuringTheMomentumGoesIntoTheRunway() async throws {
        let host = try await ScrollStabilityTests().hostInsideChapter8()
        let trackpad = TrackpadEvents(view: host.renderer.webView)
        _ = try await host.js("const d = window.__epubReader.debug; d.setLogging(true); return d.mark()")
        let start = try await sample(host)
        #expect(start.views == [7, 8, 9])

        try await trackpad.drag(dy: 12, frames: 6)
        try trackpad.release(dy: 12)
        var samples = [try await sample(host)]
        var delivered = 12 * 6 + 12
        var velocity = 12.0
        for frame in 0..<60 {
            try await Task.sleep(for: .milliseconds(16))
            velocity = max(2, velocity * 0.97)
            try trackpad.send(dy: Int(velocity.rounded()), momentum: .changed)
            delivered += Int(velocity.rounded())
            if frame == 6 {
                // A chapter joins above while the document is moving.
                Task { @MainActor in _ = try? await host.js("return await window.__epubReader.debug.prepend()") }
            }
            samples.append(try await sample(host))
        }
        let moving = try #require(samples.last)
        #expect(moving.interacting)
        #expect(moving.views.first == 6, "the chapter joined during the momentum: \(moving.views)")

        // Between two looks the text moved by what the document scrolled, and by nothing else: no jump when the
        // chapter was added, measured, or corrected for.
        for (a, b) in zip(samples, samples.dropFirst()) {
            let text = try #require(b.markY) - (try #require(a.markY))
            let scrolled = b.scrollY - a.scrollY
            #expect(abs(text + scrolled) < 0.5, "the text moved \(text) while the document scrolled \(scrolled)")
            #expect(scrolled >= 0 && scrolled < 40, "the scroll went on at the momentum's pace: \(scrolled)")
        }
        // The scroll position is the sum of the events: nothing else wrote it.
        #expect(abs(moving.scrollY - start.scrollY - Double(delivered)) <= 2, "scrolled \(moving.scrollY - start.scrollY) for \(delivered) px of events")
        let during = try await drainLog(host)
        #expect(during.contains { $0.ev == "loaded" && $0.index == 6 })
        #expect(during.contains { $0.ev == "shift" }, "the difference between the estimate and the real height went into the runway")
        #expect(!during.contains { $0.ev == "correct" }, "no scroll position is written during an interaction")
        #expect(abs(moving.pad - moving.neg - (try await host.scrollState()).runwayTarget) > 1, "the runway is off its target until the rest")

        // At rest the runway settles; the text stays.
        try trackpad.send(dy: 0, momentum: .ended)
        try await host.waitUntil { try await !host.scrollState().interacting }
        let before = try await sample(host)
        try await host.waitUntil { let s = try await host.scrollState(); return s.atRest && !s.dirty }
        let after = try await sample(host)
        #expect(abs((try #require(after.markY)) - (try #require(before.markY))) < 0.5, "the settlement moved the text")
        #expect(after.neg == 0)
        #expect(abs(after.pad - (try await host.scrollState()).runwayTarget) < 0.5)
        #expect(try await drainLog(host).contains { $0.ev == "correct" && $0.reason == "settle" })
    }

    @Test func aJumpStopsTheMomentumAndTheRestOfItIsWithheld() async throws {
        let host = try await ScrollStabilityTests().hostInsideChapter8()
        let trackpad = TrackpadEvents(view: host.renderer.webView)
        try await trackpad.drag(dy: 30, frames: 6)
        try trackpad.release(dy: 30)
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 28, momentum: .changed)
        }
        #expect(try await host.scrollState().interacting)

        // The reader picks a chapter from the table of contents while the document is still coasting. The system
        // keeps sending the momentum's events; the session takes them and the web view never sees them.
        let jump = Task { @MainActor in await host.session.go(toSpineIndex: 9) }
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 24, momentum: .changed)
        }
        await jump.value
        try await host.waitForScrollRest()
        var state = try await host.scrollState()
        #expect(host.session.currentSpineIndex == 9)
        #expect(abs(try #require(state.view(9)).top) < 0.5, "the target is on the reading line, not where the momentum would have carried it")
        #expect(!state.interacting)

        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 24, momentum: .changed)
        }
        try trackpad.send(dy: 0, momentum: .ended)
        try await Task.sleep(for: .milliseconds(100))
        state = try await host.scrollState()
        #expect(abs(try #require(state.view(9)).top) < 0.5, "the rest of the stopped momentum moved nothing")

        // A new gesture scrolls again.
        try await trackpad.drag(dy: 20, frames: 5)
        state = try await host.scrollState()
        #expect(state.interacting)
        #expect((try #require(state.view(9))).top < -50)
        try trackpad.send(dy: 0, phase: .ended)
    }

    @Test func anArrowKeyDuringTheMomentumStopsItAndScrollsItsLines() async throws {
        let host = try await ScrollStabilityTests().hostInsideChapter8()
        let trackpad = TrackpadEvents(view: host.renderer.webView)
        try await trackpad.drag(dy: 30, frames: 6)
        try trackpad.release(dy: 30)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 28, momentum: .changed)
        }
        #expect(try await host.scrollState().interacting)

        // ↓ while the document is coasting: the key writes the scroll position, so the momentum ends there.
        host.session.scrollByLines(3)
        try await host.waitUntil { try await !host.scrollState().interacting }
        let from = try await host.scrollState().scrollY
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 24, momentum: .changed)
        }
        try trackpad.send(dy: 0, momentum: .ended)
        try await host.waitForScrollRest()
        let moved = try await host.scrollState().scrollY - from
        // 30 events of 24 px would be 720 px; three lines of text are well under 150.
        #expect(moved >= 0 && moved < 150, "the lines of the key, and nothing of the stopped momentum: \(moved) px")
    }

    @Test func aJumpToAChapterOutsideTheFlowStopsTheMomentumToo() async throws {
        let host = try await ScrollStabilityTests().visibleHost(url: ScrollLayoutTests.sample)
        await host.session.go(toSpineIndex: 1)
        try await host.scrollDocument(by: 900)
        try await host.waitForScrollRest()
        let trackpad = TrackpadEvents(view: host.renderer.webView)
        try await trackpad.drag(dy: 30, frames: 6)
        try trackpad.release(dy: 30)
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 28, momentum: .changed)
        }
        #expect(try await host.scrollState().interacting)

        // The reader follows a link to the item that is not part of the flow: another document is loaded. The
        // momentum's events keep coming while it loads and after it.
        let jump = Task { @MainActor in await host.session.go(toSpineIndex: 5) }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 24, momentum: .changed)
        }
        await jump.value
        try await host.waitUntil { host.session.currentSpineIndex == 5 && !host.session.isLoading }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(16))
            try trackpad.send(dy: 24, momentum: .changed)
        }
        try trackpad.send(dy: 0, momentum: .ended)
        try await host.waitForScrollRest()
        let state = try await host.scrollState()
        #expect(state.spineIndices == [5])
        #expect(abs(try #require(state.view(5)).top) < 0.5, "the new document was scrolled by the old momentum: \(state.scrollY) px")
    }
}
#endif
