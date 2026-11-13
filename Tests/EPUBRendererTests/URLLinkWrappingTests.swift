import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Links whose text is their URL wrap inside the URL (docs/design/02-rendering.md §3.7) on `url-sample.epub`, whose
/// paragraphs are justified by the publisher's stylesheet. Without it the whole URL moves to the next line and the
/// line it left is stretched character by character.
@Suite(.serialized) @MainActor struct URLLinkWrappingTests {
    static let sample = ReaderSessionTests.fixtures.appendingPathComponent("url-sample.epub")

    struct Link: Decodable {
        /// `data-reader-url` is set.
        var marked: Bool
        var wordBreak: String
        /// Line boxes the link takes.
        var lines: Int
        /// The link starts on the line the text before it ends on.
        var startsOnLineOfTextBefore: Bool
        /// Largest distance between the left edges of two neighbouring characters of the text before the link that
        /// are on one line, in em of the paragraph.
        var widestAdvance: Double
        var textAlign: String
    }

    func measure(_ id: String, in host: SessionHost) async throws -> Link {
        let json = try await host.js("""
            const a = document.getElementById("\(id)");
            const p = a.parentElement;
            const before = a.previousSibling;
            const box = function (node, i) {
              const r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + 1);
              return r.getBoundingClientRect();
            };
            let last = before.data.length - 1;
            while (last > 0 && /\\s/.test(before.data[last])) { last--; }
            const em = parseFloat(getComputedStyle(p).fontSize);
            let widest = 0;
            for (let i = 0; i < last; i++) {
              const b = box(before, i), n = box(before, i + 1);
              if (Math.abs(b.top - n.top) < 2) { widest = Math.max(widest, (n.left - b.left) / em); }
            }
            const rects = a.getClientRects();
            return JSON.stringify({
              marked: a.hasAttribute("data-reader-url"),
              wordBreak: getComputedStyle(a).wordBreak,
              lines: rects.length,
              startsOnLineOfTextBefore: Math.abs(rects[0].top - box(before, last).top) < em / 2,
              widestAdvance: widest,
              textAlign: getComputedStyle(p).textAlign,
            });
            """) as? String
        return try JSONDecoder().decode(Link.self, from: Data(try #require(json).utf8))
    }

    @Test(arguments: ["url", "nested", "www"])
    func urlLinkWrapsInsteadOfStretchingTheLineBeforeIt(id: String) async throws {
        let host = try await SessionHost(url: Self.sample)
        await host.session.loadIfNeeded()
        let link = try await measure(id, in: host)
        #expect(link.textAlign == "justify", "the fixture's paragraphs are justified")
        #expect(link.marked)
        #expect(link.wordBreak == "break-all")
        #expect(link.startsOnLineOfTextBefore, "the URL begins where the text before it ends")
        #expect(link.lines == 2, "and continues on the next line")
        #expect(link.widestAdvance < 1.5, "the text before the URL keeps its natural spacing (\(link.widestAdvance) em)")
    }

    /// A link of ordinary words is not a URL: its words stay whole. Neither is a link whose text only starts with a
    /// URL, nor an `a` without `href` (not a link).
    @Test(arguments: ["words", "sentence", "plain"])
    func otherLinksKeepTheirWordsWhole(id: String) async throws {
        let host = try await SessionHost(url: Self.sample)
        await host.session.loadIfNeeded()
        let link = try await measure(id, in: host)
        #expect(!link.marked)
        #expect(link.wordBreak == "normal")
    }

    /// The mark is in place before the document reports `ready`, so the page count measured there (and by
    /// `PaginationService`) already has the wrapped layout.
    @Test func linksAreMarkedBeforeTheDocumentIsReady() async throws {
        let host = try await SessionHost(url: Self.sample)
        await host.session.loadIfNeeded()
        let marked = try await host.js("""
            return Array.from(document.querySelectorAll("[data-reader-url]")).map(function (a) { return a.id; }).join(",");
            """) as? String
        #expect(marked == "url,nested,www")
    }
}
