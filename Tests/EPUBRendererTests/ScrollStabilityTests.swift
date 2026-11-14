import Foundation
import Testing
import WebKit
#if canImport(AppKit)
import AppKit
#endif
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// The text the reader is on stays where it is while the scrolled layout changes around it
/// (docs/design/08-continuous-scroll.md §5.3–§5.4, §13): a chapter is added above, a chapter above changes its height,
/// the chapter being read grows above the reading line, a chapter above leaves the window, the runway settles.
///
/// Each trial remembers the text at the reading line (`debug.mark()`), runs the change, and checks two things, as the
/// spike did (07 §2): where that text is at every animation frame and at the end, and that a band of the window
/// looks the same in every picture taken of it while the change runs (a frame painted with the text in the wrong
/// place moves nothing a script can see). The pictures come from the window server, not from the web view's own
/// snapshot (`windowBand` says why).
///
/// Frames only come to a visible page (`visibleHost`). A trial that finds the page hidden, gets no frame, or runs out
/// of time fails: it neither passes nor waits forever. The suite is serialized, so the trials do not take frames from
/// each other.
@Suite(.serialized) @MainActor struct ScrollStabilityTests {
    static let sample = ScrollLayoutTests.sample

    struct Failure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// RGBA pixels of a snapshot at one pixel per point.
    struct Band: Sendable {
        let width: Int, height: Int
        let data: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = bytes
        }

        /// Fraction of the sampled pixels that differ by more than `tolerance` in a channel.
        func difference(from other: Band, step: Int = 2, tolerance: Int = 24) -> Double {
            guard width == other.width, height == other.height else { return 1 }
            var total = 0, different = 0
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let i = (y * width + x) * 4
                    total += 1
                    if abs(Int(data[i]) - Int(other.data[i])) > tolerance || abs(Int(data[i + 1]) - Int(other.data[i + 1])) > tolerance
                        || abs(Int(data[i + 2]) - Int(other.data[i + 2])) > tolerance { different += 1 }
                }
            }
            return Double(different) / Double(max(1, total))
        }

        var summary: String { "\(width)x\(height) px, ink \((ink * 1000).rounded() / 1000)" }

        /// Fraction of pixels that are not near white: text.
        var ink: Double {
            var count = 0
            for i in stride(from: 0, to: data.count, by: 4) where !(data[i] > 235 && data[i + 1] > 235 && data[i + 2] > 235) { count += 1 }
            return Double(count) / Double(max(1, width * height))
        }
    }

    /// Resumes a continuation once: by the snapshot or by its deadline, whichever comes first.
    @MainActor final class Once {
        private var continuation: CheckedContinuation<Band, any Error>?
        init(_ continuation: CheckedContinuation<Band, any Error>) { self.continuation = continuation }
        func succeed(_ band: Band) {
            continuation?.resume(returning: band)
            continuation = nil
        }
        func fail(_ failure: Failure) {
            continuation?.resume(throwing: failure)
            continuation = nil
        }
    }

    /// A snapshot of `rect` (view coordinates). It fails after `timeout` instead of waiting for a frame that a hidden
    /// window never gets.
    func snapshot(_ host: SessionHost, rect: CGRect, afterScreenUpdates: Bool, timeout: Duration = .seconds(3)) async throws -> Band {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width))
        configuration.afterScreenUpdates = afterScreenUpdates
        let webView = host.renderer.webView
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            webView.takeSnapshot(with: configuration) { image, error in
                #if canImport(AppKit)
                let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                let cgImage = image?.cgImage
                #endif
                let band = cgImage.map(Band.init)
                let message = error.map { "the snapshot failed: \($0)" } ?? "the snapshot has no image"
                Task { @MainActor in
                    if let band { once.succeed(band) } else { once.fail(Failure(message)) }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.fail(Failure("no snapshot within \(timeout): the window gets no frames"))
            }
        }
    }

    /// What the window shows in `rect` (the web view's coordinates) right now, one pixel per point.
    ///
    /// `WKWebView.takeSnapshot` is not that on macOS: the web process answers it by laying the page out and painting
    /// it into a bitmap, whenever the request arrives. A request that arrives between a change and the next frame
    /// shows a layout no frame ever shows: a block that has grown in the chapter being read, before the resize
    /// observer of that same frame has taken its height out of the runway. (Measured: such a snapshot differs from
    /// the one before in a fifth of its pixels while 30 to 45 captures of the window in the same 0.4 s show no change.
    /// This is the "flicker on macOS only" of the spike, docs/design/07-continuous-scroll-spike.md §2.3.) So the band
    /// is read from the window server, which has what was presented. A window of this process needs no screen
    /// recording permission and is captured whether or not other windows cover it.
    func windowBand(_ host: SessionHost, rect: CGRect) throws -> Band {
        #if canImport(AppKit)
        // CGWindowListCreateImage is not offered to Swift any more (ScreenCaptureKit, its replacement, asks the user
        // for permission); the function itself is still there.
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            throw Failure("CGWindowListCreateImage is gone: the window cannot be captured")
        }
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1, nominalResolution: UInt32 = 1 << 4
        guard let image = unsafeBitCast(symbol, to: Capture.self)(.null, includingWindow, UInt32(host.window.windowNumber), ignoreFraming | nominalResolution)?.takeRetainedValue() else {
            throw Failure("the window server gave no picture of the test window")
        }
        let frame = host.window.frame
        let inWindow = host.renderer.webView.convert(rect, to: nil)
        let scale = Double(image.width) / frame.width
        // The picture is the whole window frame with its origin at the top left.
        let crop = CGRect(x: inWindow.minX * scale, y: (frame.height - inWindow.maxY) * scale, width: inWindow.width * scale, height: inWindow.height * scale)
        guard let band = image.cropping(to: crop) else { throw Failure("the band \(rect) is outside the picture of the window") }
        return Band(band)
        #else
        throw Failure("the window can only be captured on macOS")
        #endif
    }

    /// The band once the page's latest frame is on screen.
    func presentedBand(_ host: SessionHost, rect: CGRect) async throws -> Band {
        // A snapshot after screen updates returns once the page has presented a frame; the window server composites
        // it a moment later.
        _ = try await snapshot(host, rect: rect, afterScreenUpdates: true)
        try await Task.sleep(for: .milliseconds(50))
        return try windowBand(host, rect: rect)
    }

    /// Opens `url` scrolled and makes sure the page is visible and gets frames.
    ///
    /// A page is visible when its window is: AppKit learns that from the window server in an event, and a test
    /// process does not run the application's event loop (taking the events by hand stops the main run loop, which
    /// ends the test process with status 0 in the middle of the run). So the window never counts as visible, whatever
    /// is on screen. WebKit has a switch for exactly this, used by its own tests: with the detection of window
    /// occlusion off, a web view in an ordered-in window is visible. Without the switch the trial fails as hidden.
    func visibleHost(url: URL = ScrollLayoutTests.mobyDick, insets: ReaderInsets = ReaderInsets()) async throws -> SessionHost {
        let host = try await SessionHost.scrolled(url: url, insets: insets)
        #if canImport(AppKit)
        let webView = host.renderer.webView
        let selector = Selector(("_setWindowOcclusionDetectionEnabled:"))
        if webView.responds(to: selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: selector), to: Setter.self)(webView, selector, false)
        }
        host.window.orderFrontRegardless()
        #endif
        await host.session.loadIfNeeded()
        do {
            try await host.waitUntil(timeout: .seconds(3)) { try await host.scrollState().visibility == "visible" }
        } catch {
            throw Failure("the page is hidden: it gets no frames, so the position cannot be checked")
        }
        return host
    }

    struct Outcome {
        /// Where the marked text is at the end, relative to where it was (px).
        var settled: Double
        /// Largest displacement seen at an animation frame while the change ran (px).
        var transient: Double
        /// Animation frames sampled.
        var frames: Int
        /// Band snapshots taken while the change ran, and how many differed from the one taken before it.
        var snapshots: Int
        var changed: Int
        /// The band at the end against the band before.
        var finalDifference: Double
        /// What the two bands were, for the message of a failure.
        var bands: String
        var state: ScrollDebugState
        /// What the operation returned.
        var value: Any?
    }

    /// Script helpers every operation can use.
    static let prelude = """
        const reader = window.__epubReader, dbg = reader.debug;
        function frame(i) { return document.querySelector('#__reader_stage > iframe[data-spine-index="' + i + '"]'); }
        function view(i) { return dbg.state().views.find(function (v) { return v.spineIndex === i; }) || null; }
        function until(what, pred, ms) {
          return new Promise(function (resolve, reject) {
            const t0 = performance.now();
            (function poll() {
              if (pred()) { resolve(true); }
              else if (performance.now() - t0 > (ms || 4000)) { reject(new Error("timed out waiting for " + what)); }
              else { setTimeout(poll, 10); }
            })();
          });
        }
        // Puts a block `px` tall at the top of chapter `i` and waits until its frame has that height more.
        function grow(i, px) {
          const d = frame(i).contentDocument, before = view(i).height;
          const el = d.createElement("div");
          el.setAttribute("data-test-grow", "");
          el.style.height = px + "px";
          d.body.insertBefore(el, d.body.firstChild);
          return until("chapter " + i + " to grow", function () { return Math.abs(view(i).height - before - px) < 1; });
        }
        function shrink(i) {
          const d = frame(i).contentDocument, before = view(i).height;
          const el = d.querySelector("[data-test-grow]"), px = el.getBoundingClientRect().height;
          el.remove();
          return until("chapter " + i + " to shrink", function () { return Math.abs(before - view(i).height - px) < 1; });
        }
        function settled() { return until("the runway to settle", function () { const s = dbg.state(); return s.atRest && !s.dirty && s.loading === null; }); }
        function interact(active) { reader.setInteraction({ active: active }); }
        """

    /// Marks the text at the reading line, runs `operation` (a script body; it may `await` and `return`), and reports
    /// whether the text, and the pixels, moved.
    func trial(_ host: SessionHost, _ operation: String, timeout: Duration = .seconds(12)) async throws -> Outcome {
        // A trial may start in the middle of an interaction the trial before it began: then there is no rest to wait for.
        if try await !host.scrollState().interacting { try await host.waitForScrollRest() }
        try await Task.sleep(for: .milliseconds(150))
        guard try await host.scrollState().visibility == "visible" else { throw Failure("the test window is hidden") }
        let size = host.renderer.webView.bounds.size
        // A band across the screen below the reading line, read from the window (`windowBand`) as fast as the window
        // server answers (about 70 times a second: nearly every frame).
        let band = CGRect(x: 0, y: (size.height * 0.4).rounded(), width: size.width, height: 48)
        guard let y0 = try await host.js("return window.__epubReader.debug.mark()") as? Double else { throw Failure("no text at the reading line to mark") }
        let reference = try await presentedBand(host, rect: band)
        guard reference.ink > 0.01 else { throw Failure("the band shows no text (ink \(reference.ink)): nothing would be seen moving") }

        final class Box { var result: Result<[String: Any], any Error>? }
        let box = Box()
        let script = """
            \(Self.prelude)
            const y0 = dbg.markY();
            let min = y0, max = y0, n = 0, lost = false, stop = false;
            // The text is looked at after each frame has been rendered (a message posted from the frame's callback
            // arrives after its layout, its resize observers and its paint): that is what the frame showed. Reading
            // the position inside the callback would force a layout before the observers that correct it have run.
            const channel = new MessageChannel();
            const sampling = new Promise(function (resolve) {
              channel.port1.onmessage = function () {
                const y = dbg.markY();
                if (y === null) { lost = true; } else { min = Math.min(min, y); max = Math.max(max, y); }
                n += 1;
                if (stop) { resolve(); } else { requestAnimationFrame(tick); }
              };
              function tick() { channel.port2.postMessage(0); }
              requestAnimationFrame(tick);
            });
            let value = null, failure = null;
            try { value = await (async function () { \(operation) })(); } catch (e) { failure = String(e && e.message || e); }
            // A late effect of the change (a timer, a settlement at rest) is sampled too.
            await new Promise(function (resolve) { setTimeout(resolve, 400); });
            // On a busy machine frames are rare: the trial goes on until it has seen enough of them (or fails below).
            for (let i = 0; i < 300 && n < 5; i += 1) { await new Promise(function (resolve) { setTimeout(resolve, 10); }); }
            stop = true;
            await Promise.race([sampling, new Promise(function (resolve) { setTimeout(resolve, 500); })]);
            return { y1: dbg.markY(), min: min, max: max, n: n, lost: lost, value: value === undefined ? null : value, failure: failure, visibility: document.visibilityState };
            """
        Task { @MainActor in
            do {
                let value = try await host.js(script) as? [String: Any]
                box.result = .success(value ?? [:])
            } catch {
                box.result = .failure(error)
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var snapshots = 0, changed = 0
        while box.result == nil {
            if clock.now > deadline { throw Failure("the change did not finish within \(timeout)") }
            let s = try windowBand(host, rect: band)
            snapshots += 1
            if s.difference(from: reference) > 0.004 { changed += 1 }
            try await Task.sleep(for: .milliseconds(2))
        }
        let result = try #require(box.result).get()
        if let failure = result["failure"] as? String { throw Failure("the operation failed: \(failure)") }
        guard result["visibility"] as? String == "visible" else { throw Failure("the test window was hidden while the change ran") }
        let frames = result["n"] as? Int ?? 0
        guard frames >= 5 else { throw Failure("only \(frames) animation frames while the change ran: the page was not being painted") }
        guard result["lost"] as? Bool == false, let y1 = result["y1"] as? Double, let lo = result["min"] as? Double, let hi = result["max"] as? Double else {
            throw Failure("the marked text left the document: \(result)")
        }
        try await Task.sleep(for: .milliseconds(100))
        let end = try await presentedBand(host, rect: band)
        return Outcome(settled: y1 - y0, transient: max(abs(lo - y0), abs(hi - y0)), frames: frames, snapshots: snapshots, changed: changed,
                       finalDifference: end.difference(from: reference), bands: "before \(reference.summary), after \(end.summary), \(frames) frames", state: try await host.scrollState(), value: result["value"] is NSNull ? nil : result["value"])
    }

    /// The text did not move: not at the end, not at any frame, not in any snapshot.
    func expectStill(_ outcome: Outcome, _ what: Comment, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(outcome.settled) < 0.5, "\(what): the text ended \(outcome.settled) px away", sourceLocation: sourceLocation)
        #expect(outcome.transient < 0.5, "\(what): the text was \(outcome.transient) px away at a frame", sourceLocation: sourceLocation)
        #expect(outcome.snapshots >= 5, "\(what): only \(outcome.snapshots) snapshots", sourceLocation: sourceLocation)
        #expect(outcome.changed == 0, "\(what): \(outcome.changed) of \(outcome.snapshots) snapshots of the band differ (\(outcome.bands))", sourceLocation: sourceLocation)
        #expect(outcome.finalDifference < 0.004, "\(what): the band differs at the end by \(outcome.finalDifference) (\(outcome.bands))", sourceLocation: sourceLocation)
    }

    /// Chapter 8 of the book with the reading line well inside it, chapters 7 and 9 around it and nothing loading.
    func hostInsideChapter8() async throws -> SessionHost {
        let host = try await visibleHost()
        await host.session.go(toSpineIndex: 8)
        try await host.scrollDocument(by: 2400)
        try await host.waitForScrollRest()
        let state = try await host.scrollState()
        #expect(state.spineIndices == [7, 8, 9], "the window around chapter 8 is \(state.spineIndices)")
        #expect((try #require(state.view(8))).top < -2000)
        return host
    }

    // MARK: The method itself

    @Test func aBandSnapshotSeesTextThatMoves() async throws {
        let host = try await hostInsideChapter8()
        let outcome = try await trial(host, "window.scrollBy(0, 7); await new Promise(function (r) { setTimeout(r, 200); });")
        #expect(abs(outcome.settled + 7) < 0.5, "the mark follows the text: \(outcome.settled)")
        #expect(outcome.changed > 0, "a 7 px move shows in the band (\(outcome.snapshots) snapshots)")
        #expect(outcome.finalDifference > 0.004)
    }

    // MARK: A chapter is added above (§5.3)

    @Test func addingAChapterAboveMovesNothing() async throws {
        let host = try await hostInsideChapter8()
        let before = try await host.scrollState()
        let outcome = try await trial(host, "const added = await dbg.prepend(); await settled(); return added;")
        #expect(outcome.value as? Int == 6)
        expectStill(outcome, "a chapter added above at rest")
        // The runway gave its place to the chapter: it is what is before the window again.
        #expect(outcome.state.pad < before.pad)
        #expect(abs(outcome.state.pad - outcome.state.runwayTarget) < 0.5)
        #expect(outcome.state.neg == 0)
    }

    @Test func addingAChapterAboveWhileTheReaderScrollsDoesNotWriteTheScrollPosition() async throws {
        let host = try await hostInsideChapter8()
        let before = try await host.scrollState()
        // The reader's hands are on the document: the correction goes into the runway, the scroll position is theirs.
        let during = try await trial(host, "interact(true); const added = await dbg.prepend(); await new Promise(function (r) { setTimeout(r, 300); }); return added;")
        #expect(during.value as? Int == 6)
        expectStill(during, "a chapter added above during an interaction")
        #expect(during.state.interacting)
        #expect(during.state.scrollY == before.scrollY, "nothing wrote the scroll position")
        // The chapter's real height is not its estimate: the runway is off its target until the reader lets go.
        let estimateError = during.state.pad - during.state.neg - during.state.runwayTarget
        #expect(abs(estimateError) > 1, "the estimate of chapter 6 happened to be exact; the test needs another chapter")

        let after = try await trial(host, "interact(false); await settled();")
        expectStill(after, "the settlement after the interaction")
        #expect(abs(after.state.pad - after.state.runwayTarget) < 0.5)
        #expect(after.state.neg == 0)
        #expect(abs(after.state.scrollY - before.scrollY + estimateError) < 1, "the scroll position took the difference")
    }

    // MARK: Heights change above the reading line (§5.3)

    @Test func aChapterAboveChangingItsHeightMovesNothing() async throws {
        let host = try await hostInsideChapter8()
        let before = try await host.scrollState()
        var outcome = try await trial(host, "await grow(7, 333); await settled();")
        expectStill(outcome, "the chapter above grew")
        #expect(abs((try #require(outcome.state.view(7))).height - (try #require(before.view(7))).height - 333) < 1)
        outcome = try await trial(host, "await shrink(7); await settled();")
        expectStill(outcome, "the chapter above shrank")
        #expect(abs(outcome.state.scrollY - before.scrollY) < 1)
    }

    @Test func theChapterBeingReadGrowingAboveTheReadingLineMovesNothing() async throws {
        let host = try await hostInsideChapter8()
        var outcome = try await trial(host, "await grow(8, 333); await settled();")
        expectStill(outcome, "the chapter being read grew above the line")
        outcome = try await trial(host, "await shrink(8); await settled();")
        expectStill(outcome, "the chapter being read shrank above the line")
    }

    @Test func anInlineImageGrowingInTheParagraphBeingReadMovesNothing() async throws {
        let host = try await visibleHost(url: Self.sample)
        let entry = try #require(host.session.publication.toc.first { $0.fragment == "c2-long" })
        await host.session.go(to: entry)
        // A few lines into the paragraph: the picture at its start is above the reading line, in the same paragraph.
        try await host.scrollDocument(by: 90)
        try await host.waitForScrollRest()
        let geometry = try #require(try await host.js("""
            const f = document.querySelector('#__reader_stage > iframe[data-spine-index="2"]'), top = f.getBoundingClientRect().top;
            const p = f.contentDocument.getElementById("c2-long").getBoundingClientRect();
            const image = f.contentDocument.getElementById("c2-inline").getBoundingClientRect();
            return { top: top + p.top, bottom: top + p.bottom, image: top + image.bottom };
            """) as? [String: Double])
        #expect(try #require(geometry["image"]) < 0, "the picture is above the reading line")
        #expect(try #require(geometry["top"]) < 0 && (try #require(geometry["bottom"])) > 40, "the reading line is inside the paragraph")

        let outcome = try await trial(host, """
            const image = frame(2).contentDocument.getElementById("c2-inline"), before = view(2).height;
            // Taller, not wider: the line it is on grows and the lines after it keep their words.
            image.style.width = image.getBoundingClientRect().width + "px";
            image.style.height = "97px";
            await until("the paragraph to grow", function () { return view(2).height > before + 40; });
            await settled();
            return view(2).height - before;
            """)
        #expect((outcome.value as? Double ?? 0) > 40, "the first line of the paragraph got taller")
        expectStill(outcome, "a picture grew at the start of the paragraph being read")
    }

    // MARK: A chapter leaves the window (§5.1)

    @Test func removingTheChapterAboveMovesNothing() async throws {
        let host = try await hostInsideChapter8()
        let before = try await host.scrollState()
        let height = try #require(before.view(7)).height
        let outcome = try await trial(host, "const removed = dbg.remove(7); await new Promise(function (r) { setTimeout(r, 200); }); return removed;")
        #expect(outcome.value as? Bool == true)
        expectStill(outcome, "the chapter above left the window")
        #expect(!outcome.state.spineIndices.contains(7) || outcome.state.spineIndices == [7, 8, 9], "it is out, or the window put it back")
        if !outcome.state.spineIndices.contains(7) {
            #expect(abs(outcome.state.pad - before.pad - height) < 1, "the runway stands in for it")
        }
        #expect(outcome.state.scrollY == before.scrollY)
    }

    @Test func removingTheChapterAboveWhileTheReaderScrollsMovesNothing() async throws {
        // The window's limit and a memory warning take chapters out in the middle of a scroll (§5.1).
        let host = try await hostInsideChapter8()
        let before = try await host.scrollState()
        let height = try #require(before.view(7)).height
        let outcome = try await trial(host, "interact(true); const removed = dbg.remove(7); await new Promise(function (r) { setTimeout(r, 300); }); return removed;")
        #expect(outcome.value as? Bool == true)
        expectStill(outcome, "the chapter above left the window during an interaction")
        #expect(outcome.state.scrollY == before.scrollY, "nothing wrote the scroll position")
        if !outcome.state.spineIndices.contains(7) {
            #expect(abs(outcome.state.pad - before.pad - height) < 1)
        }
        let after = try await trial(host, "interact(false); await settled();")
        expectStill(after, "the rest after the removal")
    }

    /// The very end of the sample book (the reading line is in chapter 3, chapter 4 fills the bottom) with
    /// chapter 2 in the window above them.
    func hostAtTheVeryBottom() async throws -> SessionHost {
        let host = try await visibleHost(url: Self.sample)
        await host.session.go(toSpineIndex: 4)
        try await host.waitForScrollRest()
        var state = try await host.scrollState()
        if !state.spineIndices.contains(2) {
            _ = try await host.js("return await window.__epubReader.debug.prepend()")
            try await host.waitForScrollRest()
            state = try await host.scrollState()
        }
        #expect(state.spineIndices.contains(2) && state.spineIndices.last == 4, "the window is \(state.spineIndices)")
        #expect(state.scrollY == state.maxScroll, "at the very bottom")
        #expect(host.session.isAtEnd)
        return host
    }

    @Test func removingAChapterAboveAtTheVeryBottomMovesNothing() async throws {
        let host = try await hostAtTheVeryBottom()
        let outcome = try await trial(host, """
            const removed = dbg.remove(2);
            await new Promise(function (r) { setTimeout(r, 200); });
            return removed;
            """)
        #expect(outcome.value as? Bool == true)
        expectStill(outcome, "a chapter above left the window at the very bottom")
        #expect(outcome.state.scrollY == outcome.state.maxScroll)
        #expect(abs((try #require(outcome.state.view(4))).bottom - 600) < 0.5, "the book's last line is still on the bottom edge")
    }

    // MARK: Settlement (§5.4)

    @Test func settlingAShorterRunwayAtTheVeryBottomMovesNothing() async throws {
        let host = try await hostAtTheVeryBottom()
        // A chapter above grows and the runway settles; then it shrinks under the reader's hands: the runway takes
        // the difference and is taller than what is before the window.
        var outcome = try await trial(host, "await grow(2, 300); await settled();")
        expectStill(outcome, "a chapter above grew at the very bottom")
        outcome = try await trial(host, "interact(true); await shrink(2); await new Promise(function (r) { setTimeout(r, 200); });")
        expectStill(outcome, "a chapter above shrank during an interaction at the very bottom")
        let during = outcome.state
        #expect(abs(during.pad - during.neg - during.runwayTarget - 300) < 1, "the runway holds the 300 px the chapter lost")

        // At rest the runway shrinks back. The document gets shorter and the browser clamps the scroll position;
        // the settlement measures the text in the viewport and puts it back.
        outcome = try await trial(host, "interact(false); await settled();")
        expectStill(outcome, "the settlement at the very bottom")
        #expect(abs(outcome.state.pad - outcome.state.runwayTarget) < 0.5)
        #expect(outcome.state.neg == 0)
        #expect(outcome.state.scrollY == outcome.state.maxScroll)
        #expect(abs(outcome.state.scrollY - during.scrollY + 300) < 1)
        #expect(abs((try #require(outcome.state.view(4))).bottom - 600) < 0.5)
    }

    // MARK: A very tall document (§14)

    /// The runway stands for every chapter before the window: in a long book it is millions of pixels tall, and the
    /// engine cannot lay out more than 2^25 px (33,554,432). The runway stops at `core.maxSpace` (8,000,000 px), so a
    /// book of any length keeps the text where it is, painted, with an exact scroll position.
    @Test(arguments: [3_000_000.0, 40_000_000.0, 400_000_000.0])
    func aBookOfMillionsOfPixelsKeepsTheTextInPlaceAndPainted(extra: Double) async throws {
        let host = try await hostInsideChapter8()
        let before = try await host.scrollState()
        let expected = min(8_000_000, before.pad + extra)
        // The estimate of a chapter before the window (one that was never displayed: a measured height is not replaced
        // by an estimate) becomes `extra` px taller; at rest the runway and the scroll position take it.
        let outcome = try await trial(host, """
            const heights = dbg.heights();
            heights[4] += \(Int(extra));
            reader.setEstimates(heights);
            await until("the runway to take the estimate", function () { const s = dbg.state(); return s.atRest && !s.dirty && Math.abs(s.pad - s.runwayTarget) < 1 && s.pad >= \(Int(expected)); });
            return document.scrollingElement.scrollHeight;
            """)
        expectStill(outcome, "the book grew by \(Int(extra)) px above the window")
        let after = outcome.state
        #expect(abs(after.pad - expected) < 1, "the runway is \(after.pad) px")
        #expect(abs((after.scrollY - before.scrollY) - (expected - before.pad)) < 1, "the scroll position is exact at \(after.scrollY)")
        #expect(after.maxScroll > after.scrollY)
        let scrollHeight = try #require(outcome.value as? Double)
        #expect(scrollHeight > expected && scrollHeight < 17_000_000, "the document is as tall as its blocks say: \(scrollHeight)")

        // Scrolling there works as anywhere: a screen forward and back, and the text is still painted.
        await host.session.goForward()
        try await host.waitForScrollRest()
        let forward = try await host.scrollState()
        #expect(forward.scrollY > after.scrollY + 300)
        await host.session.goBackward()
        try await host.waitForScrollRest()
        let back = try await host.scrollState()
        #expect(abs(back.scrollY - after.scrollY) < 1)
        let size = host.renderer.webView.bounds.size
        let band = try await snapshot(host, rect: CGRect(x: 0, y: (size.height * 0.4).rounded(), width: size.width, height: 48), afterScreenUpdates: true)
        #expect(band.ink > 0.01, "the text is painted at \(back.scrollY) px: ink \(band.ink)")
    }

    @Test func aChapterAboveGrowingWithNoRunwayUsesANegativeMarginAndSettlesAtRest() async throws {
        // The first chapter of the book is in the window: there is no runway to shrink.
        let host = try await visibleHost()
        await host.session.go(toSpineIndex: 2)
        try await host.scrollDocument(by: 500)
        try await host.waitForScrollRest()
        let before = try await host.scrollState()
        #expect(before.spineIndices.first == 1)
        #expect(before.pad == 0 && before.neg == 0)
        #expect((try #require(before.view(2))).top < 0, "the reading line is in chapter 2, below chapter 1")

        let during = try await trial(host, "interact(true); await grow(1, 280); await new Promise(function (r) { setTimeout(r, 300); });")
        expectStill(during, "the chapter above grew with no runway, during an interaction")
        #expect(during.state.pad == 0)
        #expect(abs(during.state.neg - 280) < 1, "the stage is pulled up by the growth")
        #expect(during.state.scrollY == before.scrollY, "nothing wrote the scroll position")

        let after = try await trial(host, "interact(false); await settled();")
        expectStill(after, "the settlement of the negative margin")
        #expect(after.state.pad == 0 && after.state.neg == 0)
        #expect(abs(after.state.scrollY - before.scrollY - 280) < 1, "the scroll position took the growth")

        // At rest the same change settles at once.
        let atRest = try await trial(host, "await grow(1, 120); await settled();")
        expectStill(atRest, "the chapter above grew with no runway, at rest")
        #expect(atRest.state.neg == 0)
    }
}
