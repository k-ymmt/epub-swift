import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Collects a session's events from the moment it is created.
@MainActor
final class EventRecorder {
    private(set) var events: [ReaderEvent] = []
    private var task: Task<Void, Never>?

    init(_ session: ReaderSession) {
        let stream = session.events
        task = Task { @MainActor [weak self] in
            for await event in stream { self?.events.append(event) }
        }
    }

    deinit { task?.cancel() }

    func reset() { events = [] }

    var internalLinks: [CFI] { events.compactMap { if case .internalLink(let cfi) = $0 { cfi } else { nil } } }
    var externalLinks: [URL] { events.compactMap { if case .externalLink(let url) = $0 { url } else { nil } } }
    var notes: [NoteContent] { events.compactMap { if case .noteref(let note) = $0 { note } else { nil } } }
    var images: [TappedImage] { events.compactMap { if case .imageTapped(let image) = $0 { image } else { nil } } }
    var taps: [CGPoint] { events.compactMap { if case .tapped(let point, _) = $0 { point } else { nil } } }
}

/// Links, noterefs and image taps (M5, docs/design/02-rendering.md §4.2, 03-api §3.4) on `links-sample.epub`.
@Suite(.serialized) @MainActor struct LinksNotesImagesTests {
    static let sample = ReaderSessionTests.fixtures.appendingPathComponent("links-sample.epub")

    /// Clicks the centre of the element (in the visible page; `frame` selects the iframe of a spread wrapper).
    func click(_ id: String, in host: SessionHost, frame: Int? = nil) async throws {
        let document = frame.map { "document.querySelectorAll('iframe')[\($0)].contentDocument" } ?? "document"
        let clicked = try await host.js("""
            const doc = \(document);
            const el = doc.getElementById("\(id)");
            if (!el) { return false; }
            const r = el.getClientRects()[0] || el.getBoundingClientRect();
            el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: r.left + Math.min(4, r.width / 2), clientY: r.top + r.height / 2 }));
            return true;
            """) as? Bool
        #expect(clicked == true, "no element \(id)")
    }

    @Test func linkToAnotherChapterMovesThereAndReportsTheTargetElement() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        #expect(host.session.currentSpineIndex == 0)

        try await click("to-c2", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        let cfi = try #require(recorder.internalLinks.first)
        #expect(host.session.currentSpineIndex == 1)
        #expect(host.session.publication.spineIndex(of: cfi) == 1)
        #expect(cfi.description.contains("[target]"))
        #expect(host.session.currentPageIndex > 0, "the target is far into the chapter")
        #expect(try await host.renderer.pageFor(cfi) == host.session.currentPageIndex)
        #expect(recorder.externalLinks.isEmpty)

        // Without a fragment: the first page of the chapter.
        await host.session.go(toSpineIndex: 0)
        recorder.reset()
        try await click("to-c2-start", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(host.session.currentSpineIndex == 1)
        #expect(host.session.currentPageIndex == 0)
        #expect(host.session.publication.spineIndex(of: try #require(recorder.internalLinks.first)) == 1)
    }

    @Test func linkWithinTheChapterTurnsToTheTargetPage() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await click("to-later", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        let cfi = try #require(recorder.internalLinks.first)
        #expect(cfi.description.contains("[later]"))
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex > 0)
        #expect(try await host.renderer.pageFor(cfi) == host.session.currentPageIndex)
    }

    @Test func externalLinkIsReportedWithoutNavigating() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await click("external", in: host)
        try await host.waitUntil { !recorder.externalLinks.isEmpty }
        #expect(recorder.externalLinks == [URL(string: "https://example.com/page?q=1")!])
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == 0)
        #expect(recorder.internalLinks.isEmpty)
    }

    @Test func sameDocumentNoterefCarriesTheNoteAndHidesItFromThePage() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()

        let display = try await host.js("""
            const d = id => getComputedStyle(document.getElementById(id)).display;
            return [d("fn1"), d("unreferenced"), d("hidden-div")];
            """) as? [String]
        #expect(display == ["none", "block", "none"])

        try await click("ref1", in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let note = try #require(recorder.notes.first)
        #expect(note.isInSameDocument)
        #expect(note.path == "OPS/c1.xhtml")
        #expect(note.fragment == "fn1")
        #expect(note.spineIndex == 0)
        #expect(note.text == "The first footnote.")
        #expect(note.html?.contains("<b") == true)
        #expect(note.cfi?.description.contains("[fn1]") == true)
        #expect(note.sourceRect.width > 0 && note.sourceRect.height > 0)
        #expect(note.sourceRect.minX >= 0 && note.sourceRect.maxX <= 400)
        // The session does not move for a noteref.
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == 0)
        #expect(recorder.internalLinks.isEmpty)
    }

    @Test func noterefIntoAnotherDocumentResolvesTheNoteThroughEPUBCore() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()

        try await click("ref2", in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let aside = try #require(recorder.notes.first)
        #expect(!aside.isInSameDocument)
        #expect(aside.path == "OPS/notes.xhtml")
        #expect(aside.spineIndex == 3)
        #expect(aside.html == nil)
        #expect(aside.text == "The endnote text.")
        #expect(aside.cfi?.description.contains("[en1]") == true)

        recorder.reset()
        try await click("ref3", in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let anchored = try #require(recorder.notes.first)
        #expect(anchored.text == "3. An anchored endnote in a paragraph.")
        // The app can go to the note: the non-linear notes document opens at the note.
        let cfi = try #require(anchored.cfi)
        await host.session.go(to: cfi)
        #expect(host.session.currentSpineIndex == 3)
    }

    @Test func imageTapCarriesTheBoxAndTheBytes() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()

        try await click("plain", in: host)
        try await host.waitUntil { !recorder.images.isEmpty }
        let image = try #require(recorder.images.first)
        #expect(image.path == "OPS/picture.png")
        #expect(image.alt == "A picture")
        #expect(abs(image.rect.width - 120) < 1 && abs(image.rect.height - 80) < 1)
        #expect(image.rect.minX >= 0 && image.rect.maxX <= 400)
        #expect(image.rect.contains(image.point))
        let data = try await image.data()
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(recorder.taps.isEmpty)

        // An image inside a link is the link.
        recorder.reset()
        try await click("in-link", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(recorder.images.isEmpty)
        #expect(host.session.currentSpineIndex == 1)
    }

    @Test func linksAndNotesWorkInsideAFixedLayoutWrapper() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 2)
        #expect(host.session.currentUnit?.isFixedLayout == true)
        try await host.waitUntil { (try? await host.js("return document.querySelectorAll('iframe').length")) as? Int == 1 }

        // An image on a fixed-layout page is part of the page: a plain tap.
        try await click("fxl-img", in: host, frame: 0)
        try await host.waitUntil { !recorder.taps.isEmpty }
        #expect(recorder.images.isEmpty)

        try await click("fxl-note", in: host, frame: 0)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let note = try #require(recorder.notes.first)
        #expect(note.text == "The endnote text.")
        #expect(note.sourceRect.width > 0)
        #expect(note.sourceRect.maxX <= 400 && note.sourceRect.maxY <= 600, "mapped into the wrapper (scaled page)")

        try await click("fxl-link", in: host, frame: 0)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(host.session.currentSpineIndex == 1)
        #expect(recorder.internalLinks.first?.description.contains("[target]") == true)
    }

    @Test func linkInATwoColumnSpreadTurnsToTheTargetFace() async throws {
        var settings = ReaderSettings()
        settings.spreadPolicy = .always
        let host = try await SessionHost(url: Self.sample, settings: settings, size: CGSize(width: 800, height: 600))
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        #expect(host.session.isShowingSpread)
        try await click("to-later", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        let cfi = try #require(recorder.internalLinks.first)
        #expect(host.session.currentPageIndex > 0)
        #expect(try await host.renderer.pageFor(cfi) == host.session.currentPageIndex)
    }
}
