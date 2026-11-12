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
    var positions: [ReadingPosition] { events.compactMap { if case .positionChanged(let position) = $0 { position } else { nil } } }
    var navigations: [ReaderNavigation] { events.compactMap { if case .navigated(let navigation) = $0 { navigation } else { nil } } }
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

    /// Adds `<a id=… href=…>` at the start of the visible document's body (and optionally a target element at its end).
    private func addLink(_ id: String, href: String, targetID: String? = nil, in host: SessionHost) async throws {
        _ = try await host.js("""
            const ns = "http://www.w3.org/1999/xhtml";
            const a = document.createElementNS(ns, "a");
            a.id = \(CFIScriptTests.quoted(id)); a.setAttribute("href", \(CFIScriptTests.quoted(href))); a.textContent = "link";
            document.body.insertBefore(a, document.body.firstChild);
            const target = \(targetID.map(CFIScriptTests.quoted) ?? "null");
            if (target) { const p = document.createElementNS(ns, "p"); p.id = target; p.textContent = "target"; document.body.appendChild(p); }
            return true;
            """)
    }

    /// A link to the document on screen without a fragment goes to its first page and reports the body's start.
    @Test func linkToTheSameDocumentWithoutFragmentGoesToItsStart() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await addLink("self", href: "c1.xhtml", in: host)
        await host.session.go(toPageInChapter: 2)
        #expect(host.session.currentPageIndex == 2)
        try await click("self", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == 0)
        let cfi = try #require(recorder.internalLinks.first)
        #expect(cfi.description == "epubcfi(/6/2[c1]!/4)")
        #expect(cfi.characterOffset == nil)
    }

    /// The fragment is decoded once (in Swift): `#foo%2520bar` names the id `foo%20bar`.
    @Test func fragmentIsDecodedOnce() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await addLink("encoded", href: "#foo%2520bar", targetID: "foo%20bar", in: host)
        let page = try #require(try await host.renderer.pageForFragment("foo%20bar"))
        #expect(page > 0)
        #expect(try await host.renderer.pageForFragment("foo bar") == nil)
        try await click("encoded", in: host)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(host.session.currentPageIndex == page)
    }

    @Test func resourceLinksKeepTheirDecodedFragment() {
        let publication = Publication(id: PublicationID(), metadata: Metadata(title: "t"), manifest: [], readingOrder: [], toc: [], pageList: [], landmarks: [], layout: .reflowable, spread: .auto, pageProgression: .default, coverImagePath: nil, packageDocumentPath: "p.opf", navigationDocumentPath: nil, warnings: [])
        let id = PublicationID()
        let destination = LinkDestination.resolve("epub://\(id)/OPS/notes%20file.xhtml#%E6%B3%A8", publicationID: id, publication: publication, contains: { _ in true })
        #expect(destination == .resource(path: "OPS/notes file.xhtml", fragment: "注"))
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
        // The aside is out of the page flow: there is no place to go to.
        #expect(note.isHidden)
        // The session does not move for a noteref.
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == 0)
        #expect(recorder.internalLinks.isEmpty)
    }

    /// A note that is an ordinary paragraph of the noteref's document stays on the page: the app can go to it.
    @Test func sameDocumentNoterefToANoteOnThePageIsNotHidden() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()

        try await click("ref4", in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        let note = try #require(recorder.notes.first)
        #expect(note.isInSameDocument)
        #expect(note.fragment == "pn1")
        #expect(note.text == "4. The note that is part of the page.")
        #expect(!note.isHidden)
        #expect(host.session.currentPageIndex == 0)

        let page = try #require(try await host.renderer.pageForFragment("pn1"))
        #expect(page > 0)
        await host.session.go(to: try #require(note.cfi))
        #expect(host.session.currentSpineIndex == 0)
        #expect(host.session.currentPageIndex == page)
    }

    /// A note the publication's style shows through its content only (`display: contents`) is on the page; one it
    /// does not paint (`visibility: hidden`) is not (codex review of 99facab).
    @Test func aNotesOwnStyleDecidesWhetherItIsHidden() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()

        func isHidden(withStyle style: String) async throws -> Bool {
            recorder.reset()
            _ = try await host.js("document.getElementById('pn1').setAttribute('style', '\(style)'); return true;")
            try await click("ref4", in: host)
            try await host.waitUntil { !recorder.notes.isEmpty }
            return try #require(recorder.notes.first).isHidden
        }
        #expect(try await isHidden(withStyle: "display: contents") == false)
        #expect(try await isHidden(withStyle: "visibility: hidden") == true)
        #expect(try await isHidden(withStyle: "display: none") == true)
        #expect(try await isHidden(withStyle: "") == false)
    }

    /// The note of another document is read after the tap. When the reader moved meanwhile, the noteref's box is not
    /// on the page any more: nothing is reported (codex review of 99facab).
    @Test func aNoterefWhoseNoteIsReadAfterThePageMovedIsDropped() async throws {
        let host = try await SessionHost(url: Self.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()

        var finished = 0
        host.session.noterefLookupDidFinish = { [session = host.session] in
            await session.goForward()
            finished += 1
        }
        try await click("ref2", in: host)
        try await host.waitUntil { finished == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.session.currentPageIndex == 1)
        #expect(recorder.notes.isEmpty, "the popover's anchor is on a page that is gone")

        // The next tap is reported as usual.
        host.session.noterefLookupDidFinish = nil
        try await click("ref2", in: host)
        try await host.waitUntil { !recorder.notes.isEmpty }
        #expect(recorder.notes.first?.text == "The endnote text.")
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
        // Another document is not rendered here: whether its note is displayed is not known.
        #expect(!aside.isHidden)
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
