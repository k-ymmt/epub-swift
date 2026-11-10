import Foundation
import Testing
import WebKit
@testable import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer
#if canImport(AppKit)
import AppKit
#endif

/// Drawing annotations (docs/design/06-annotations.md §10): the four styles, the outline layer following relayouts,
/// the publication layer under the app's, and taps.
@Suite(.serialized) @MainActor struct AnnotationRenderingTests {
    static let sample = ReaderSessionTests.fixtures.appendingPathComponent("cfi-sample.epub")
    typealias Probe = AnnotationPrerequisiteTests

    /// Pure colors, so each style can be found in a snapshot.
    static let probeTheme = ReaderTheme(
        foreground: ReaderColor(hex: 0x000000),
        background: ReaderColor(hex: 0xFFFFFF),
        link: ReaderColor(hex: 0x000000),
        isDark: false,
        annotationPalette: [
            .green: ReaderColor(hex: 0x00FF00),
            .pink: ReaderColor(hex: 0xFF0000),
            .blue: ReaderColor(hex: 0x0000FF),
            .purple: ReaderColor(hex: 0xFF00FF),
        ]
    )

    static func isLightGreen(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { g > 230 && r > 110 && r < 190 && b > 110 && b < 190 }
    static func isBlue(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { b > 220 && r < 50 && g < 50 }

    // "Call me Ishmael. Some years ago—never mind how long precisely" in c1's p1.
    static func range(_ start: Int, _ end: Int) -> CFIRange {
        CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:\(start),/1:\(end))")!
    }

    func keys(_ host: SessionHost) async throws -> [String] {
        ((try await host.js("return Array.from(CSS.highlights.keys());") as? [String]) ?? []).sorted()
    }

    func overlayBoxes(_ host: SessionHost) async throws -> Int {
        try await host.js("const o = document.getElementById('__reader_overlay'); return o ? o.childNodes.length : -1;") as? Int ?? -1
    }

    @Test func themeKeepsItsPaletteThroughCodable() throws {
        // A theme saved before M6 gets the default palette for its brightness.
        let old = #"{"foreground":{"red":0,"green":0,"blue":0,"alpha":1},"background":{"red":1,"green":1,"blue":1,"alpha":1},"link":{"red":0,"green":0,"blue":1,"alpha":1},"isDark":true}"#
        let decoded = try JSONDecoder().decode(ReaderTheme.self, from: Data(old.utf8))
        #expect(decoded.annotationPalette == ReaderTheme.darkPalette)
        #expect(decoded.color(for: .other("teal")) == ReaderTheme.dark.annotationFallbackColor)

        let data = try JSONEncoder().encode(Self.probeTheme)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((object?["annotationPalette"] as? [String: Any])?.keys.sorted() == ["blue", "green", "pink", "purple"])
        #expect(try JSONDecoder().decode(ReaderTheme.self, from: data) == Self.probeTheme)
    }

    @Test func drawsTheFourStyles() async throws {
        var settings = ReaderSettings()
        settings.theme = Self.probeTheme
        let host = try await SessionHost(url: Self.sample, settings: settings)
        await host.session.loadIfNeeded()
        let publication = host.session.publication
        let solid = Annotation.highlight(Self.range(0, 4), in: publication, color: .green, style: .solid)
        let strike = Annotation.highlight(Self.range(8, 15), in: publication, color: .pink, style: .strikethrough)
        let underline = Annotation.highlight(Self.range(17, 21), in: publication, color: .blue, style: .underline)
        let outline = Annotation.highlight(Self.range(22, 27), in: publication, color: .purple, style: .outline)
        host.session.annotations = [solid, strike, underline, outline]
        try await host.waitUntil { (try? await self.keys(host))?.count == 3 }
        #expect(try await overlayBoxes(host) == 1)
        // The layer is the last child of <html>, after <body>.
        let last = try await host.js("return document.documentElement.lastElementChild.id;") as? String
        #expect(last == "__reader_overlay")

        let probe = Probe()
        try await probe.waitForFrames(host)
        let pixels = try await probe.snapshot(host)
        func rects(_ annotation: Annotation) async throws -> [CGRect] { try await host.renderer.rects(for: annotation.range!) }

        let green = pixels.find(Self.isLightGreen)
        let solidBox = Probe.union(try await rects(solid))
        #expect(green.count > 50)
        if let box = green.box { #expect(solidBox.insetBy(dx: -1.5, dy: -1.5).contains(box), "\(box) in \(solidBox)") }

        let red = pixels.find(Probe.isRed)
        let strikeBox = Probe.union(try await rects(strike))
        #expect(red.count > 20)
        if let box = red.box {
            #expect(box.height <= 4)
            #expect(abs(box.midY - strikeBox.midY) <= strikeBox.height * 0.3)
        }

        let blue = pixels.find(Self.isBlue)
        let underlineBox = Probe.union(try await rects(underline))
        #expect(blue.count > 10)
        if let box = blue.box {
            #expect(box.height <= 4)
            #expect(box.midY > underlineBox.midY)
        }

        probe.expectOverlay(pixels, around: try await rects(outline), "outline")

        // Taps on the outline still hit (by the range, not the layer).
        host.session.annotations = [outline]
        try await host.waitUntil { (try? await self.keys(host)) == [] }
        #expect(try await overlayBoxes(host) == 1)
        host.session.annotations = []
        try await host.waitUntil { (try? await self.overlayBoxes(host)) == -1 }
    }

    @Test func outlineFollowsRelayout() async throws {
        var settings = ReaderSettings()
        settings.theme = Self.probeTheme
        let host = try await SessionHost(url: Self.sample, settings: settings)
        await host.session.loadIfNeeded()
        let outline = Annotation.highlight(Self.range(22, 27), in: host.session.publication, color: .purple, style: .outline)
        host.session.annotations = [outline]
        try await host.waitUntil { (try? await self.overlayBoxes(host)) == 1 }
        let before = try await host.renderer.rects(for: Self.range(22, 27))

        host.session.settings.fontScale = 1.6
        try await host.waitUntil { !host.session.isLoading }
        let after = try await host.renderer.rects(for: Self.range(22, 27))
        #expect(Probe.union(after) != Probe.union(before))
        let probe = Probe()
        try await probe.waitForFrames(host)
        probe.expectOverlay(try await probe.snapshot(host), around: after, "after relayout")

        // A theme change redraws in the new palette.
        var theme = Self.probeTheme
        theme.annotationPalette[.purple] = ReaderColor(hex: 0x0000FF)
        host.session.settings.theme = theme
        try await host.waitUntil(timeout: .seconds(10)) {
            let color = try? await host.js("const b = document.querySelector('#__reader_overlay > div'); return b ? b.style.borderColor : '';") as? String
            return color == "rgb(0, 0, 255)"
        }
    }

    /// cfi-sample.epub with `META-INF/annotations.json` (one highlight on "Ishmael", found by its quote).
    static func sampleWithEmbeddedAnnotations() throws -> URL {
        let json = """
        {"@context": "https://www.w3.org/ns/epub-anno.jsonld", "type": "AnnotationSet", "id": "urn:x:embedded",
         "items": [{"id": "urn:x:embedded:1", "type": "Annotation", "motivation": "highlighting", "created": "2026-01-01",
                    "target": {"source": "OPS/c1.xhtml", "selector": {"type": "TextQuoteSelector", "exact": "Ishmael", "prefix": "Call me "}},
                    "body": {"type": "TextualBody", "value": "", "color": "green"}}]}
        """
        let archive = try ZIPArchive(url: sample)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("embedded-\(UUID().uuidString).epub")
        let writer = try ZIPWriter(url: url)
        for entry in archive.entryOrder where !entry.isDirectory {
            try writer.add(entry.rawName, data: try archive.data(for: entry), method: entry.rawName == "mimetype" ? .stored : .deflate)
        }
        try writer.add("META-INF/annotations.json", data: Data(json.utf8))
        try writer.finish()
        return url
    }

    @Test func publicationAnnotationsAreALayerUnderTheApps() async throws {
        let url = try Self.sampleWithEmbeddedAnnotations()
        defer { try? FileManager.default.removeItem(at: url) }
        let host = try await SessionHost(url: url)
        var tapped: [Annotation.ID] = []
        let stream = host.session.events
        let collector = Task { @MainActor in
            for await event in stream {
                if case .annotationTapped(let id, _) = event { tapped.append(id) }
            }
        }
        await host.session.loadIfNeeded()
        try await host.waitUntil { host.session.publicationAnnotations.count == 1 }
        #expect(host.session.publicationAnnotations[0].origin == .publication)
        let publicationKey = "reader-h-p_urn_x_embedded_1"
        try await host.waitUntil { (try? await self.keys(host)) == [publicationKey] }

        func tap() async throws {
            let rect = try #require(try await host.renderer.rects(for: Self.range(8, 15)).first)
            _ = try await host.js("""
                document.getElementById("p1").dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: \(rect.midX), clientY: \(rect.midY) }));
                return true;
                """)
        }
        try await tap()
        try await host.waitUntil { tapped == ["urn:x:embedded:1"] }

        // The app's annotation on the same text is drawn above and wins the tap.
        let mine = Annotation.highlight(Self.range(8, 15), in: host.session.publication, color: .pink)
        host.session.annotations = [mine]
        try await host.waitUntil { (try? await self.keys(host))?.count == 2 }
        let priorities = try await host.js("return Array.from(CSS.highlights.entries()).filter(e => e[0].startsWith('reader-h-')).map(e => e[0] + '=' + e[1].priority);") as? [String]
        #expect(Set(priorities ?? []) == [publicationKey + "=0", SelectionHighlightSearchTests.key(mine) + "=1"])
        try await tap()
        try await host.waitUntil { tapped.count == 2 }
        #expect(tapped.last == mine.id)

        // Hidden publication annotations are not drawn.
        host.session.showsPublicationAnnotations = false
        try await host.waitUntil { (try? await self.keys(host)) == [SelectionHighlightSearchTests.key(mine)] }
        host.session.showsPublicationAnnotations = true
        try await host.waitUntil { (try? await self.keys(host))?.count == 2 }
        collector.cancel()
    }

    /// The M6 completion check, through the calls ReaderDemo makes: highlights and a bookmark exported to a
    /// `.annotations` file (with and without the CFI selector), deleted, and imported back are drawn at the same
    /// place, in the same color and style.
    @Test(arguments: [true, false])
    func exportDeleteImportRestoresTheDrawing(includesCFI: Bool) async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        let session = host.session
        let publication = session.publication
        // Ranges found by search, so they are real text in the chapter on screen.
        var results: [SearchResult] = []
        for try await result in session.search("the") where result.spineIndex == session.currentSpineIndex {
            results.append(result)
            if results.count == 4 { break }
        }
        #expect(results.count == 4)
        let styles: [(HighlightColor, HighlightStyle)] = [(.pink, .solid), (.blue, .underline), (.green, .strikethrough), (.purple, .outline)]
        var made: [Annotation] = zip(results, styles).map { Annotation.highlight($0.range, in: publication, color: $1.0, style: $1.1) }
        made.append(Annotation.bookmark(at: results[0].range.start, in: publication))
        session.annotations = made
        try await host.waitUntil { (try? await self.keys(host))?.count == 3 }
        let rules = try await host.js("return document.getElementById('__reader_highlights').textContent;") as? String
        let boxes = try await overlayBoxes(host)

        // Export (ReaderDemo: generate the selectors, then write the ZIP).
        var set = AnnotationSet(id: "urn:uuid:5d3c69b0-0000-4000-8000-000000000000", about: AnnotationSet.About(publication: publication), items: session.annotations)
        set = await AnnotationResolver(container: session.container).generatingSelectors(for: set)
        let data = try await AnnotationArchive.data(set, options: ExportOptions(includesCFI: includesCFI)) { url in
            throw AnnotationArchive.Failure.missingResource(url)
        }
        let json = String(decoding: try ZIPArchive(data: data).data(at: "annotations.json"), as: UTF8.self)
        #expect(json.contains("CfiSelector") == includesCFI)

        // Delete everything, then import.
        session.annotations = []
        try await host.waitUntil { (try? await self.keys(host)) == [] }
        let archive = try await AnnotationArchive.read(data: data)
        let resolution = await session.resolve(archive.annotationSet)
        #expect(resolution.unresolvedIDs.isEmpty)
        #expect(resolution.match.identifier == .match)
        #expect(resolution.match.resolvedPositionRatio == 1)
        let plan = AnnotationMergePlan(existing: [], incoming: resolution.annotationSet)
        #expect(plan.added.count == made.count)
        session.annotations = plan.applying(to: [])

        for (before, after) in zip(made, session.annotations) {
            #expect(after.id == before.id)
            #expect(after.motivation == before.motivation)
            #expect(after.color == before.color)
            #expect(after.style == before.style)
            switch (before.target.position, after.target.position) {
            case (.range(let a), .range(let b)):
                #expect(a.start.withoutAssertions == b.start.withoutAssertions && a.end.withoutAssertions == b.end.withoutAssertions, "\(a) vs \(b)")
            case (.point(let a), .point(let b)):
                #expect(a.withoutAssertions == b.withoutAssertions, "\(a) vs \(b)")
            default:
                Issue.record("position \(before.target.position) → \(after.target.position)")
            }
        }
        try await host.waitUntil { (try? await self.keys(host))?.count == 3 }
        let rulesAfter = try await host.js("return document.getElementById('__reader_highlights').textContent;") as? String
        #expect(rulesAfter == rules)
        #expect(try await overlayBoxes(host) == boxes)
    }
}
