import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// The JavaScript CFI implementation in `reader.js`, checked against the same vectors as EPUBCore
/// (`Tests/Fixtures/cfi-vectors.json`, docs/design/01-core.md §5.3) on the live WebKit DOM of `cfi-sample.epub`.
@Suite(.serialized) @MainActor struct CFIScriptTests {
    struct Vectors: Decodable {
        struct Resolve: Decodable {
            var name: String
            var cfi: String
            var text: String?
            var offset: Int?
            var elementId: String?
            var usedTextAssertion: Bool?
            var generated: String?
        }
        struct Parse: Decodable { var cfi: String; var canonical: String?; var invalid: Bool? }
        struct RangeCase: Decodable { var cfi: String; var start: String; var end: String; var canonical: String }
        var epub: String
        var resolve: [Resolve]
        var parse: [Parse]
        var ranges: [RangeCase]
    }

    static let vectorsURL = ReaderSessionTests.fixtures.appendingPathComponent("cfi-vectors.json")

    @Test func resolvesAndGeneratesTheSharedVectors() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.vectorsURL))
        let host = try await SessionHost(url: ReaderSessionTests.fixtures.appendingPathComponent(vectors.epub))
        await host.session.loadIfNeeded()
        #expect(host.session.currentSpineIndex == 0)
        for vector in vectors.resolve {
            let described = try await host.js("return window.__epubReader.cfi.describe(\(Self.quoted(vector.cfi)))")
            guard let generated = vector.generated else {
                #expect(described == nil || described is NSNull, Comment(rawValue: vector.name))
                continue
            }
            let dict = try #require(described as? [String: Any], Comment(rawValue: vector.name))
            if let text = vector.text {
                #expect(dict["text"] as? String == text, Comment(rawValue: vector.name))
                #expect(dict["offset"] as? Int == vector.offset, Comment(rawValue: vector.name))
            } else if let elementId = vector.elementId {
                #expect(dict["elementId"] as? String == elementId, Comment(rawValue: vector.name))
            }
            if let used = vector.usedTextAssertion {
                #expect(dict["usedTextAssertion"] as? Bool == used, Comment(rawValue: vector.name))
            }
            #expect(dict["generated"] as? String == generated, Comment(rawValue: vector.name))
        }
    }

    @Test func parsesAndRendersTheSharedVectors() async throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.vectorsURL))
        let host = try await SessionHost(url: ReaderSessionTests.fixtures.appendingPathComponent(vectors.epub))
        await host.session.loadIfNeeded()
        for vector in vectors.parse {
            let canonical = try await host.js("return window.__epubReader.cfi.canonical(\(Self.quoted(vector.cfi)))")
            if vector.invalid == true {
                #expect(canonical == nil || canonical is NSNull, Comment(rawValue: vector.cfi))
            } else {
                #expect(canonical as? String == vector.canonical, Comment(rawValue: vector.cfi))
            }
        }
        for vector in vectors.ranges {
            let parts = try #require(try await host.js("return window.__epubReader.cfi.rangeParts(\(Self.quoted(vector.cfi)))") as? [String: Any], Comment(rawValue: vector.cfi))
            #expect(parts["start"] as? String == vector.start, Comment(rawValue: vector.cfi))
            #expect(parts["end"] as? String == vector.end, Comment(rawValue: vector.cfi))
            #expect(parts["canonical"] as? String == vector.canonical, Comment(rawValue: vector.cfi))
        }
    }

    /// DOM Range ↔ CFI range round trip, including a selection made in the document.
    @Test func convertsDOMRangesAndSelections() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.fixtures.appendingPathComponent("cfi-sample.epub"))
        await host.session.loadIfNeeded()
        let roundTrip = try await host.js("""
            const p1 = document.getElementById("p1").firstChild;
            const em = document.getElementById("em1").firstChild;
            const r = document.createRange();
            r.setStart(p1, 5); r.setEnd(em, 3);
            const cfi = window.__epubReader.cfi.fromRange(r);
            const back = window.__epubReader.cfi.toRange(cfi);
            return { cfi: cfi, text: back.toString(), same: back.startContainer === p1 && back.startOffset === 5 && back.endContainer === em && back.endOffset === 3 };
            """) as? [String: Any]
        let dict = try #require(roundTrip)
        #expect(dict["cfi"] as? String == "epubcfi(/6/2[c1]!/4[body],/4[p1]/1:5[Call ,me Ishmael],/6[p2]/2[em1]/1:3[emp,hasised])")
        #expect(dict["same"] as? Bool == true)
        #expect((dict["text"] as? String)?.hasPrefix("me Ishmael.") == true)

        // The same range as a selection → currentSelection.
        let selection = try await host.js("""
            const sel = window.getSelection();
            sel.removeAllRanges();
            const r = document.createRange();
            r.setStart(document.getElementById("p1").firstChild, 0); r.setEnd(document.getElementById("p1").firstChild, 15);
            sel.addRange(r);
            return window.__epubReader.currentSelection();
            """) as? [String: Any]
        let sel = try #require(selection)
        #expect(sel["text"] as? String == "Call me Ishmael")
        #expect(sel["cfiRange"] as? String == "epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0[,Call me Is],/1:15[me Ishmael,. Some yea])")
        #expect(((sel["rects"] as? [[String: Any]])?.count ?? 0) >= 1)
        let bridge = try await host.renderer.currentSelection()
        #expect(bridge?.text == "Call me Ishmael")
        #expect(bridge?.range.start.description == "epubcfi(/6/2[c1]!/4[body]/4[p1]/1:0[,Call me Is])")
        try await host.renderer.clearSelection()
        #expect(try await host.renderer.currentSelection() == nil)
    }

    /// A range boundary on an element container whose child at the offset is a comment still converts (the comment
    /// is skipped), so selecting `<b>First</b>` before `<!-- c -->` is reported.
    @Test func rangeBoundaryBeforeACommentConverts() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.fixtures.appendingPathComponent("cfi-sample.epub"))
        await host.session.loadIfNeeded()
        let result = try await host.js("""
            const p = document.createElementNS("http://www.w3.org/1999/xhtml", "p");
            p.id = "cmt";
            const b = document.createElementNS("http://www.w3.org/1999/xhtml", "b");
            b.textContent = "First";
            p.appendChild(b);
            p.appendChild(document.createComment(" c "));
            p.appendChild(document.createTextNode("Second"));
            document.body.appendChild(p);
            const r = document.createRange();
            r.selectNode(b);
            const cfi = window.__epubReader.cfi.fromRange(r);
            const back = cfi ? window.__epubReader.cfi.toRange(cfi) : null;
            const tail = document.createRange();
            tail.setStart(p, 1); tail.setEnd(p, 2);
            const tailCFI = window.__epubReader.cfi.fromRange(tail);
            return { cfi: cfi, text: back ? back.toString() : null, tail: tailCFI };
            """) as? [String: Any]
        let dict = try #require(result)
        #expect(dict["cfi"] is String)
        #expect(dict["text"] as? String == "First")
        #expect(dict["tail"] is String)
    }

    /// The temporary highlight refuses a range whose spine steps name another document.
    @Test func transientHighlightChecksTheSpineSteps() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.fixtures.appendingPathComponent("cfi-sample.epub"))
        await host.session.loadIfNeeded()
        let own = "epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0,/1:4)"
        let other = "epubcfi(/6/4[c2]!/4[body]/4[p1],/1:0,/1:4)"
        let result = try await host.js("""
            return [window.__epubReader.setTransientHighlight(\(Self.quoted(other))), window.__epubReader.setTransientHighlight(\(Self.quoted(own)))];
            """) as? [Bool]
        #expect(result == [false, true])
    }

    /// `cfiForPage` / `pageFor` on a paginated chapter: every page's first text maps back to that page.
    @Test func pagePositionsRoundTrip() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let pageCount = host.session.chapterPageCount
        #expect(pageCount > 3)
        var cfis: [CFI] = []
        for page in 0..<min(pageCount, 6) {
            await host.session.go(toPageInChapter: page)
            let cfi = try #require(try await host.renderer.cfiForPage(page, margins: host.session.settings.pageMargins), "page \(page)")
            #expect(cfi.spineSteps == host.session.publication.cfiSpineSteps(forSpineIndex: 6))
            #expect(cfi.characterOffset != nil)
            #expect(cfi.textAssertion != nil)
            #expect(try await host.renderer.pageFor(cfi) == page, "page \(page): \(cfi)")
            cfis.append(cfi)
        }
        // Later pages have later positions.
        for (a, b) in zip(cfis, cfis.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
        // Pages outside the frame are reachable too (the walker fallback).
        await host.session.go(toPageInChapter: 0)
        let far = try #require(try await host.renderer.cfiForPage(pageCount - 1, margins: host.session.settings.pageMargins))
        do {
            let page = try await host.renderer.pageFor(far)
            #expect(page == pageCount - 1, "far=\(far)")
        } catch {
            Issue.record("pageFor(\(far)) threw \(error)")
        }
        // An element position and a fragment agree.
        let chapterHeading = try #require(CFI("epubcfi(/6/14[xchapter_001]!/4/2/2/2[c001s0000])"))
        #expect(try await host.renderer.pageFor(chapterHeading) == 0)
    }

    /// Search results (EPUBCore CFIs) after `script` elements address the same text as `reader.js`. WebKit removes the
    /// scripts from the DOM, so EPUBCore must not count them either (06-annotations §12.1); the paragraph has no id,
    /// so an ID assertion could not hide a wrong step.
    @Test func searchResultAfterAScriptMatchesTheDOM() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.fixtures.appendingPathComponent("cfi-sample.epub"))
        await host.session.loadIfNeeded()
        var results: [SearchResult] = []
        for try await result in host.session.search("No id after a script") { results.append(result) }
        let result = try #require(results.first)
        #expect(results.count == 1)
        let fromDOM = try await host.js("""
            const p = Array.from(document.body.children).find(function (e) { return e.textContent === "No id after a script element."; });
            const r = document.createRange();
            r.setStart(p.firstChild, 0); r.setEnd(p.firstChild, 20);
            return window.__epubReader.cfi.fromRange(r);
            """) as? String
        #expect(result.range.description == fromDOM)
        #expect(result.range.description == "epubcfi(/6/2[c1]!/4[body]/20,/1:0[,No id afte],/1:20[r a script, element.])")
        let text = try await host.js("return window.__epubReader.cfi.toRange(\(Self.quoted(result.range.description))).toString();") as? String
        #expect(text == "No id after a script")
    }

    static func quoted(_ s: String) -> String {
        let data = try! JSONEncoder().encode([s])
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())
    }
}
