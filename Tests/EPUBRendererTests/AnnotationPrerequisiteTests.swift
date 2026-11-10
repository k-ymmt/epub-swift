import Foundation
import Testing
import WebKit
@testable import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer
#if canImport(AppKit)
import AppKit
#endif

/// The checks docs/design/06-annotations.md §12 asks for before M6: the EPUBCore DOM gives the same `textContent`
/// as WebKit (TextPositionSelector, CssSelector `:nth-child`), `::highlight()` draws `line-through`, and an overlay
/// element after `<body>` can draw outlines without changing pagination or CFIs.
@Suite(.serialized) @MainActor struct AnnotationPrerequisiteTests {
    static let fixtures = ReaderSessionTests.fixtures
    static let sample = fixtures.appendingPathComponent("cfi-sample.epub")
    static let mobyDick = ReaderSessionTests.mobyDick
    static let kusamakura = VerticalWritingTests.kusamakura
    static let haruko = fixtures.appendingPathComponent("haruko-html-jpeg.epub")

    // MARK: - textContent

    /// Per element under `body`, in document order: local name, `textContent` length in code points, element
    /// children. The reader's sentinel (`__reader_end`) is not part of the content.
    struct ElementSummary: Equatable, CustomStringConvertible {
        var name: String
        var codePoints: Int
        var childElements: Int
        var description: String { "\(name)(\(codePoints) cp, \(childElements) children)" }
    }

    /// The `.rendered` tree (the default) leaves out what WebKit leaves out with content JavaScript disabled: XHTML /
    /// SVG `script` elements and `template` children.
    static func coreSummary(_ body: EPUBCore.XMLElement) -> [ElementSummary] {
        var out: [ElementSummary] = []
        func walk(_ element: EPUBCore.XMLElement) {
            let children = element.childElements
            out.append(ElementSummary(name: element.name, codePoints: element.textContent.unicodeScalars.count, childElements: children.count))
            for child in children { walk(child) }
        }
        walk(body)
        return out
    }

    /// `path` selects the document: the main one, or the spread wrapper's frame that shows `path`.
    static let webSummaryScript = """
        let doc = document;
        if (window.__epubReader && window.__epubReader.isSpreadWrapper) {
          doc = null;
          for (const f of Array.from(document.querySelectorAll("iframe"))) {
            const d = f.contentDocument;
            if (d && decodeURIComponent(d.location.pathname).endsWith("/" + path)) { doc = d; }
          }
          if (!doc) { return null; }
        }
        const cp = function (s) { let n = 0; for (const _ of s) { n++; } return n; };
        const out = [];
        const keep = function (el) { return el.id !== "__reader_end"; };
        function walk(el) {
          const kids = Array.from(el.children).filter(keep);
          out.push([el.localName, cp(el.textContent), kids.length]);
          for (const k of kids) { walk(k); }
        }
        walk(doc.body);
        return { text: doc.body.textContent, elements: out, contentType: doc.contentType, scripts: doc.getElementsByTagName("script").length };
        """

    struct BookResult { var book: String; var documents = 0; var elements = 0; var surrogates = 0; var withScripts: [String] = []; var skipped: [String] = [] }

    /// Compares every XHTML spine item of `url` (all of them, or the first `limit`).
    func compareTextContent(_ url: URL, limit: Int? = nil) async throws -> BookResult {
        let host = try await SessionHost(url: url)
        await host.session.loadIfNeeded()
        let container = host.session.container
        let publication = host.session.publication
        var result = BookResult(book: url.lastPathComponent)
        let items = publication.readingOrder.prefix(limit ?? publication.readingOrder.count)
        for item in items {
            guard item.mediaType == "application/xhtml+xml" else { result.skipped.append("\(item.path) (\(item.mediaType))"); continue }
            let prepared = try await container.contentDocument(at: item.path)
            guard prepared.isXML else { result.skipped.append("\(item.path) (served as text/html)"); continue }
            let tree = try EPUBCore.XMLDocument(data: prepared.data)
            let body = try #require(tree.root.firstChild(named: "body"), "no body in \(item.path)")
            let core = Self.coreSummary(body)
            let coreText = body.textContent
            let source = try EPUBCore.XMLDocument(data: prepared.data, tree: .source)
            if source.root.firstDescendant(where: { $0.name == "script" || $0.name == "template" }) != nil { result.withScripts.append(item.path) }

            await host.session.go(toSpineIndex: item.index)
            #expect(host.session.currentSpineIndex == item.index)
            let value = try await host.renderer.webView.callAsyncJavaScript(Self.webSummaryScript, arguments: ["path": item.path], in: nil, contentWorld: WebViewSpineRenderer.readerWorld)
            let web = try #require(value as? [String: Any], "no document for \(item.path)")
            #expect((web["scripts"] as? NSNumber)?.intValue == 0, "WebKit kept a script element in \(item.path)")
            let webText = try #require(web["text"] as? String)
            let rows = try #require(web["elements"] as? [[Any]])
            let webSummary = rows.map { ElementSummary(name: $0[0] as! String, codePoints: ($0[1] as! NSNumber).intValue, childElements: ($0[2] as! NSNumber).intValue) }

            #expect(web["contentType"] as? String == "application/xhtml+xml", "\(item.path)")
            #expect(webText == coreText, "body textContent differs in \(item.path)")
            if webSummary != core {
                let index = (0..<min(webSummary.count, core.count)).first(where: { webSummary[$0] != core[$0] }) ?? min(webSummary.count, core.count)
                Issue.record("element summary differs in \(item.path) at element \(index): web \(webSummary.count) elements, core \(core.count); web \(index < webSummary.count ? webSummary[index].description : "-") vs core \(index < core.count ? core[index].description : "-")")
            }
            result.documents += 1
            result.elements += core.count
            result.surrogates += coreText.utf16.count - coreText.unicodeScalars.count
        }
        return result
    }

    @Test func textContentMatchesWebKitInReflowableFixtures() async throws {
        var results: [BookResult] = []
        results.append(try await compareTextContent(Self.sample))
        results.append(try await compareTextContent(Self.fixtures.appendingPathComponent("links-sample.epub")))
        results.append(try await compareTextContent(Self.kusamakura))
        results.append(try await compareTextContent(Self.fixtures.appendingPathComponent("childrens-literature.epub")))
        results.append(try await compareTextContent(Self.fixtures.appendingPathComponent("regime-anticancer-arabic.epub")))
        results.append(try await compareTextContent(Self.fixtures.appendingPathComponent("wasteland-otf-obf.epub")))
        results.append(try await compareTextContent(Self.mobyDick))
        results.append(try await compareTextContent(Self.haruko))
        results.append(try await compareTextContent(Self.fixtures.appendingPathComponent("page-blanche.epub")))
        results.append(try await compareTextContent(Self.fixtures.appendingPathComponent("cole-voyage-of-life.epub")))
        for r in results {
            print("[annotation-prereq] textContent \(r.book): \(r.documents) documents, \(r.elements) elements, \(r.surrogates) surrogate pairs; script / template elements in \(r.withScripts); skipped \(r.skipped)")
        }
        #expect(results.allSatisfy { $0.documents > 0 })
    }

    /// The repaired XHTML of the malformed fixtures (01-core §4.1) is what WebKit parses, so the trees agree too.
    @Test func textContentMatchesWebKitInRepairedDocuments() async throws {
        let names = ["unclosed-and-entities", "single-missing-close", "html5-elements-and-svg"]
        let malformed = Self.fixtures.appendingPathComponent("malformed")
        let documents = try names.map { ("\($0).xhtml", try Data(contentsOf: malformed.appendingPathComponent("\($0).xhtml"))) }
        let url = try Self.writeEPUB(documents)
        let r = try await compareTextContent(url)
        print("[annotation-prereq] textContent malformed: \(r.documents) documents, \(r.elements) elements; skipped \(r.skipped)")
        #expect(r.documents + r.skipped.count == names.count)
    }

    /// A stored (uncompressed) EPUB whose spine is `documents`, written to a temporary file.
    static func writeEPUB(_ documents: [(name: String, data: Data)]) throws -> URL {
        let manifest = documents.enumerated().map { #"<item id="d\#($0.offset)" href="\#($0.element.name)" media-type="application/xhtml+xml"/>"# }.joined()
        let spine = documents.indices.map { #"<itemref idref="d\#($0)"/>"# }.joined()
        var files: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
                <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
                """.utf8)),
            ("OEBPS/content.opf", Data("""
                <?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:00000000-0000-0000-0000-000000000006</dc:identifier><dc:title>Malformed</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-10T00:00:00Z</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
                """.utf8)),
        ]
        files += documents.map { ("OEBPS/\($0.name)", $0.data) }

        var archive = Data(), central = Data()
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        for (name, data) in files {
            let nameData = Data(name.utf8), crc = CRC32.checksum(data), offset = UInt32(archive.count)
            let size = UInt32(data.count)
            var local = u32(0x04034b50)
            local += u16(20); local += u16(0); local += u16(0); local += u16(0); local += u16(0)
            local += u32(crc); local += u32(size); local += u32(size); local += u16(nameData.count); local += u16(0)
            archive += local; archive += nameData; archive += data
            var entry = u32(0x02014b50)
            entry += u16(20); entry += u16(20); entry += u16(0); entry += u16(0); entry += u16(0); entry += u16(0)
            entry += u32(crc); entry += u32(size); entry += u32(size); entry += u16(nameData.count)
            entry += u16(0); entry += u16(0); entry += u16(0); entry += u16(0); entry += u32(0); entry += u32(offset)
            central += entry; central += nameData
        }
        let centralOffset = UInt32(archive.count)
        var end = u32(0x06054b50)
        end += u16(0); end += u16(0); end += u16(files.count); end += u16(files.count)
        end += u32(UInt32(central.count)); end += u32(centralOffset); end += u16(0)
        archive += central; archive += end
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-prereq-\(UUID().uuidString).epub")
        try archive.write(to: url)
        return url
    }

    // MARK: - Pixels

    struct Pixels {
        let width: Int, height: Int, scale: CGFloat
        let data: [UInt8]

        init(_ image: CGImage, pointWidth: CGFloat) {
            width = image.width
            height = image.height
            scale = CGFloat(image.width) / pointWidth
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = bytes
        }

        /// Bounding box (in points) and count of the pixels matching `predicate`.
        func find(_ predicate: (UInt8, UInt8, UInt8) -> Bool) -> (count: Int, box: CGRect?) {
            var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if predicate(data[i], data[i + 1], data[i + 2]) {
                        count += 1
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard count > 0 else { return (0, nil) }
            return (count, CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                                  width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale))
        }
    }

    static func isRed(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g < 90 && b < 90 }
    static func isMagenta(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && b > 200 && g < 90 }

    /// The whole web view (the three-slot frame), in its own coordinates, like `rectsFor` / `getClientRects`.
    func snapshot(_ host: SessionHost) async throws -> Pixels {
        let webView = host.renderer.webView
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        #if canImport(AppKit)
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #else
        let cgImage = try #require(image.cgImage)
        #endif
        return Pixels(cgImage, pointWidth: webView.bounds.width)
    }

    /// Lets WebKit paint the change. (`requestAnimationFrame` does not fire reliably in the off-screen test window.)
    func waitForFrames(_ host: SessionHost) async throws {
        _ = try await host.js("document.body.getBoundingClientRect(); return true;")
        try await Task.sleep(for: .milliseconds(150))
    }

    static func union(_ rects: [CGRect]) -> CGRect { rects.dropFirst().reduce(rects.first ?? .null) { $0.union($1) } }

    // MARK: - line-through

    /// Draws `::highlight(probe)` with a red line-through over the first `length` characters of the first visible
    /// text in the main document (or in frame `frame` of a spread wrapper). Returns the range's client rects in
    /// web view coordinates.
    func drawLineThrough(_ host: SessionHost, length: Int) async throws -> [CGRect] {
        let value = try await host.js("""
            const pick = \(Self.pickVisibleRangeScript);
            const r = pick(document, window, \(length));
            if (!r) { return null; }
            CSS.highlights.set("probe", new Highlight(r));
            let st = document.getElementById("__probe_style");
            if (!st) { st = document.createElement("style"); st.id = "__probe_style"; document.head.appendChild(st); }
            st.textContent = "::highlight(probe) { text-decoration: line-through; text-decoration-color: rgb(255, 0, 0); text-decoration-thickness: 3px; color: rgb(0, 0, 0); }";
            return Array.from(r.getClientRects()).map(function (c) { return { x: c.left, y: c.top, width: c.width, height: c.height }; });
            """)
        return SpineRendererRects.rects(from: value)
    }

    /// `function (doc, win, length)`: a range over `length` characters of the first text node that starts inside the
    /// document's viewport, skipping leading whitespace.
    static let pickVisibleRangeScript = """
        function (doc, win, length) {
          const w = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
          let n;
          while ((n = w.nextNode())) {
            const m = /\\S/.exec(n.data);
            if (!m || n.data.length - m.index < length) { continue; }
            const r = doc.createRange();
            r.setStart(n, m.index); r.setEnd(n, m.index + length);
            if (/\\s/.test(r.toString())) { continue; }
            const rects = r.getClientRects();
            if (rects.length !== 1) { continue; }
            const c = rects[0];
            if (c.width > 0 && c.height > 0 && c.left >= 0 && c.top >= 0 && c.right <= win.innerWidth && c.bottom <= win.innerHeight) { return r; }
          }
          return null;
        }
        """

    @Test(arguments: ["horizontal", "vertical"])
    func lineThroughHighlightDraws(_ writing: String) async throws {
        let host = try await SessionHost(url: writing == "vertical" ? Self.kusamakura : Self.sample)
        await host.session.loadIfNeeded()
        if writing == "vertical" { await host.session.go(toSpineIndex: 3) }
        let before = try await snapshot(host).find(Self.isRed)
        #expect(before.count == 0)

        let rects = try await drawLineThrough(host, length: 6)
        let box = try #require(rects.isEmpty ? nil : Self.union(rects))
        try await waitForFrames(host)
        let red = try await snapshot(host).find(Self.isRed)
        let redBox = try #require(red.box, "no line-through pixels")
        print("[annotation-prereq] line-through \(writing): range \(box), red \(red.count) px in \(redBox)")
        // The line lies within the text box, spans most of it along the line, and is thin across it.
        #expect(box.insetBy(dx: -2, dy: -2).contains(redBox))
        if writing == "vertical" {
            #expect(redBox.height >= box.height * 0.8)
            #expect(redBox.width <= 5)
            #expect(abs(redBox.midX - box.midX) <= box.width * 0.3)
        } else {
            #expect(redBox.width >= box.width * 0.8)
            #expect(redBox.height <= 5)
            #expect(abs(redBox.midY - box.midY) <= box.height * 0.3)
        }
    }

    // MARK: - Overlay layer

    /// `function (doc, win, ranges)`: (re)draws the overlay element after `<body>` with a 2 px magenta border box
    /// per client rect of each range, in document coordinates.
    static let drawOverlayScript = """
        function (doc, win, ranges) {
          let o = doc.getElementById("__probe_overlay");
          if (!o) {
            o = doc.createElement("div");
            o.id = "__probe_overlay";
            o.setAttribute("style", "position: absolute; left: 0; top: 0; width: 0; height: 0; margin: 0; padding: 0; border: 0; pointer-events: none;");
            doc.documentElement.appendChild(o);
          }
          while (o.firstChild) { o.removeChild(o.firstChild); }
          const sx = win.scrollX, sy = win.scrollY;
          for (const r of ranges) {
            for (const c of Array.from(r.getClientRects())) {
              const b = doc.createElement("div");
              b.setAttribute("style", "position: absolute; box-sizing: border-box; margin: 0; padding: 0; border: 2px solid rgb(255, 0, 255); left: "
                + (c.left + sx) + "px; top: " + (c.top + sy) + "px; width: " + c.width + "px; height: " + c.height + "px;");
              o.appendChild(b);
            }
          }
          return o.childNodes.length;
        }
        """

    /// Draws the overlay around `cfi` (a range string) in the main document and returns the range's client rects.
    func drawOverlay(_ host: SessionHost, cfi: String) async throws -> [CGRect] {
        let value = try await host.js("""
            const draw = \(Self.drawOverlayScript);
            const r = window.__epubReader.cfi.toRange(\(Self.jsString(cfi)));
            if (!r) { return null; }
            draw(document, window, [r]);
            return Array.from(r.getClientRects()).map(function (c) { return { x: c.left, y: c.top, width: c.width, height: c.height }; });
            """)
        return SpineRendererRects.rects(from: value)
    }

    func removeOverlay(_ host: SessionHost) async throws {
        _ = try await host.js("const o = document.getElementById('__probe_overlay'); if (o) { o.remove(); } return true;")
    }

    /// A CFI range over `length` characters of the first visible text of the current page.
    func visibleRangeCFI(_ host: SessionHost, length: Int) async throws -> String {
        let value = try await host.js("""
            const pick = \(Self.pickVisibleRangeScript);
            const r = pick(document, window, \(length));
            return r ? window.__epubReader.cfi.fromRange(r) : null;
            """)
        return try #require(value as? String)
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// Checks that the magenta pixels frame `rects` (border inside the boxes, so the bounding boxes agree).
    func expectOverlay(_ pixels: Pixels, around rects: [CGRect], _ label: String) {
        let magenta = pixels.find(Self.isMagenta)
        let expected = Self.union(rects)
        print("[annotation-prereq] overlay \(label): range \(expected), magenta \(magenta.count) px in \(magenta.box.map { "\($0)" } ?? "-")")
        guard let box = magenta.box else { Issue.record("no overlay pixels (\(label))"); return }
        #expect(abs(box.minX - expected.minX) <= 1.5 && abs(box.maxX - expected.maxX) <= 1.5, "\(label): x \(box) vs \(expected)")
        #expect(abs(box.minY - expected.minY) <= 1.5 && abs(box.maxY - expected.maxY) <= 1.5, "\(label): y \(box) vs \(expected)")
    }

    struct Measure: Equatable { var pageCount: Int; var scrollWidth: Double; var scrollHeight: Double; var firstCFI: String? }

    func measure(_ host: SessionHost, page: Int) async throws -> Measure {
        let result = try await host.renderer.goToPage(page)
        let size = try await host.js("const s = document.scrollingElement; return [s.scrollWidth, s.scrollHeight];") as? [Double] ?? [0, 0]
        let cfi = try await host.renderer.cfiForPage(page, margins: host.session.settings.pageMargins)
        return Measure(pageCount: result.pageCount, scrollWidth: size[0], scrollHeight: size[1], firstCFI: cfi?.description)
    }

    @Test(arguments: ["horizontal", "vertical"])
    func overlayLayerFollowsTextWithoutChangingPagination(_ writing: String) async throws {
        let vertical = writing == "vertical"
        let host = try await SessionHost(url: vertical ? Self.kusamakura : Self.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: vertical ? 3 : 6)
        let session = host.session
        let pageCount = session.chapterPageCount
        #expect(pageCount > 3)

        // Page 2 (scrolled): outline the first visible word.
        await session.go(toPageInChapter: 2)
        let middle = try await visibleRangeCFI(host, length: 4)
        let baseline = try await measure(host, page: 2)
        let rects = try await drawOverlay(host, cfi: middle)
        try await waitForFrames(host)
        expectOverlay(try await snapshot(host), around: rects, "\(writing) page 2")

        // The overlay does not change the page count, the scroll extent or the CFI of the page start, even with a
        // box drawn on the first text of the last page.
        await session.go(toPageInChapter: pageCount - 1)
        let last = try await visibleRangeCFI(host, length: 4)
        _ = try await host.js("""
            const draw = \(Self.drawOverlayScript);
            draw(document, window, [window.__epubReader.cfi.toRange(\(Self.jsString(middle))), window.__epubReader.cfi.toRange(\(Self.jsString(last)))]);
            return true;
            """)
        let withOverlay = try await measure(host, page: 2)
        #expect(withOverlay == baseline, "\(withOverlay) vs \(baseline)")
        let lastWithOverlay = try await measure(host, page: pageCount - 1)
        try await removeOverlay(host)
        let lastWithout = try await measure(host, page: pageCount - 1)
        #expect(lastWithOverlay == lastWithout, "\(lastWithOverlay) vs \(lastWithout)")

        // After a relayout (larger font) the boxes are stale until redrawn; redrawn, they frame the text again.
        _ = try await drawOverlay(host, cfi: middle)
        session.settings.fontScale = 1.3
        try await host.waitUntil { !session.isLoading }
        let exists = try await host.js("return !!document.getElementById('__probe_overlay');") as? Bool
        print("[annotation-prereq] overlay \(writing): survives relayout = \(exists ?? false), pages \(pageCount) → \(session.chapterPageCount)")
        let middleRange = try #require(CFIRange(middle))
        let foundPage = try await host.renderer.pageFor(middleRange.start)
        let page = try #require(foundPage)
        await session.go(toPageInChapter: page)
        let rects2 = try await drawOverlay(host, cfi: middle)
        try await waitForFrames(host)
        expectOverlay(try await snapshot(host), around: rects2, "\(writing) after relayout, page \(page)")
        let afterRelayout = try await measure(host, page: page)
        try await removeOverlay(host)
        #expect(try await measure(host, page: page) == afterRelayout)
    }

    /// Two columns per page (horizontal spread): the overlay on the second column.
    @Test func overlayLayerInTwoColumnSpread() async throws {
        let host = try await SessionHost(url: Self.mobyDick, size: CGSize(width: 800, height: 600))
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        #expect(host.session.isShowingSpread)
        await host.session.go(toPageInChapter: 1)
        let baseline = try await measure(host, page: 1)
        // The last word that starts in the visible area: on the right column.
        let cfi = try #require(try await host.js("""
            const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let n, found = null;
            while ((n = w.nextNode())) {
              const re = /\\S{4}/g; let m;
              while ((m = re.exec(n.data))) {
                const r = document.createRange(); r.setStart(n, m.index); r.setEnd(n, m.index + 4);
                const cs = r.getClientRects();
                if (cs.length === 1 && cs[0].left > window.innerWidth / 2 && cs[0].right < window.innerWidth && cs[0].left >= 0 && cs[0].bottom < window.innerHeight) { found = r; }
              }
            }
            return found ? window.__epubReader.cfi.fromRange(found) : null;
            """) as? String)
        let rects = try await drawOverlay(host, cfi: cfi)
        try await waitForFrames(host)
        expectOverlay(try await snapshot(host), around: rects, "two-column spread")
        #expect(try await measure(host, page: 1) == baseline)
    }

    /// Spread wrappers (vertical reflow: two frames on adjacent pages; FXL: a page scaled into its frame, here the
    /// 600×800 text page of links-sample): the overlay is drawn inside each frame's document.
    @Test(arguments: ["vertical", "fxl"])
    func overlayLayerInsideWrapperFrames(_ kind: String) async throws {
        let links = Self.fixtures.appendingPathComponent("links-sample.epub")
        let host = try await SessionHost(url: kind == "fxl" ? links : Self.kusamakura, size: CGSize(width: 800, height: 600))
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: kind == "fxl" ? 2 : 3)
        let isWrapper = try await host.js("return !!window.__epubReader.isSpreadWrapper;") as? Bool
        #expect(isWrapper == true)
        let value = try await host.js("""
            const pick = \(Self.pickVisibleRangeScript);
            const draw = \(Self.drawOverlayScript);
            const info = window.__epubReader.frameInfo();
            const iframes = Array.from(document.querySelectorAll("iframe"));
            const out = [];
            for (let i = 0; i < iframes.length && i < info.length; i++) {
              const f = info[i];
              if (f.hidden) { continue; }
              const doc = iframes[i].contentDocument, win = iframes[i].contentWindow;
              const r = pick(doc, win, 2);
              if (!r) { continue; }
              draw(doc, win, [r]);
              for (const c of Array.from(r.getClientRects())) {
                out.push({ x: f.x + c.left * f.scale, y: f.y + c.top * f.scale, width: c.width * f.scale, height: c.height * f.scale });
              }
            }
            return { rects: out, frames: info.length, scales: info.map(function (f) { return f.scale; }) };
            """) as? [String: Any]
        let rects = SpineRendererRects.rects(from: value?["rects"])
        print("[annotation-prereq] overlay wrapper \(kind): frames \(value?["frames"] ?? "-") scales \(value?["scales"] ?? "-"), outlined rects \(rects)")
        try #require(!rects.isEmpty, "no text found in the frames")
        try await waitForFrames(host)
        let pixels = try await snapshot(host)
        // One box per frame: check each against the magenta pixels inside its own neighbourhood.
        for rect in rects {
            let region = rect.insetBy(dx: -6, dy: -6)
            let local = Pixels.Sub(pixels: pixels, region: region).find(Self.isMagenta)
            print("[annotation-prereq] overlay wrapper \(kind): box \(rect), magenta \(local.count) px in \(local.box.map { "\($0)" } ?? "-")")
            let box = try #require(local.box, "no overlay pixels near \(rect)")
            #expect(abs(box.minX - rect.minX) <= 1.5 && abs(box.maxX - rect.maxX) <= 1.5, "\(kind): \(box) vs \(rect)")
            #expect(abs(box.minY - rect.minY) <= 1.5 && abs(box.maxY - rect.maxY) <= 1.5, "\(kind): \(box) vs \(rect)")
        }
    }
}

extension AnnotationPrerequisiteTests.Pixels {
    /// The pixels of `region` (points) only.
    struct Sub {
        let pixels: AnnotationPrerequisiteTests.Pixels
        let region: CGRect

        func find(_ predicate: (UInt8, UInt8, UInt8) -> Bool) -> (count: Int, box: CGRect?) {
            let s = pixels.scale
            let x0 = max(0, Int(region.minX * s)), x1 = min(pixels.width, Int(region.maxX * s))
            let y0 = max(0, Int(region.minY * s)), y1 = min(pixels.height, Int(region.maxY * s))
            var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in y0..<max(y0, y1) {
                for x in x0..<max(x0, x1) {
                    let i = (y * pixels.width + x) * 4
                    if predicate(pixels.data[i], pixels.data[i + 1], pixels.data[i + 2]) {
                        count += 1
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            guard count > 0 else { return (0, nil) }
            return (count, CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s))
        }
    }
}

/// `SpineRenderer.rects(from:)` without needing a renderer instance.
enum SpineRendererRects {
    static func rects(from value: Any?) -> [CGRect] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
                  let w = (d["width"] as? NSNumber)?.doubleValue, let h = (d["height"] as? NSNumber)?.doubleValue else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }
}
