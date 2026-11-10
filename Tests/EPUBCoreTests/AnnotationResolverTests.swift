import Foundation
import Testing
@testable import EPUBCore

/// AnnotationSelector generation (CFI → selectors) and resolution (selectors → CFI) on the Core DOM
/// (docs/design/06-annotations.md §5, §6, §14), checked against `Tests/Fixtures/annotation-vectors.json`.
struct AnnotationResolverTests {
    struct Vector: Decodable {
        var name: String
        var motivation: String
        var cfi: String
        var source: String
        var css: String
        var start: Int
        var end: Int
        var exact: String?
        var prefix: String?
        var suffix: String?

        var isPoint: Bool { motivation == "bookmarking" }

        var selectors: [AnnotationSelector] {
            var out: [AnnotationSelector] = [.css(value: css, refinedBy: [.textPosition(start: start, end: end, refinedBy: [])])]
            if let exact { out.append(.textQuote(exact: exact, prefix: prefix, suffix: suffix)) }
            return out
        }

        /// The vector as an annotation read from a file, with the given selectors.
        func json(selectors: [JSONValue]) -> JSONValue {
            .object([
                "id": .string("urn:x:" + name),
                "type": .string("Annotation"),
                "motivation": .string(motivation),
                "created": .string("2026-11-10T00:00:00Z"),
                "target": .object(["source": .string(source), "selector": .array(selectors)]),
            ])
        }
    }

    struct Vectors: Decodable {
        var vectors: [Vector]
    }

    static let vectors: [Vector] = {
        let data = try! Data(contentsOf: Fixtures.url("annotation-vectors.json"))
        return try! JSONDecoder().decode(Vectors.self, from: data).vectors
    }()

    static func container(_ name: String = "cfi-sample.epub") async throws -> EPUBContainer {
        try await EPUBContainer(url: Fixtures.url(name))
    }

    static func annotation(_ vector: Vector, in publication: Publication) throws -> Annotation {
        if vector.isPoint {
            return Annotation.bookmark(at: try #require(CFI(vector.cfi)), in: publication)
        }
        return Annotation.highlight(try #require(CFIRange(vector.cfi)), in: publication)
    }

    /// Decodes JSON items as an imported set.
    static func importedSet(_ items: [JSONValue]) throws -> AnnotationSet {
        let json = JSONValue.object(["type": .string("AnnotationSet"), "id": .string("urn:x:set"), "items": .array(items)])
        let data = JSONWriter.data(.value(json))
        let (set, warnings) = try AnnotationCodec.decode(data)
        #expect(warnings.isEmpty)
        return set
    }

    static func selectorJSON(_ selectors: [AnnotationSelector]) -> [JSONValue] {
        selectors.map { selector in
            let data = JSONWriter.data(AnnotationCodec.selectorNode(selector))
            return try! JSONParser.parse(data, limits: JSONParseLimits(maxDepth: 32, maxStringBytes: 1 << 20, overlongMarker: "?"))
        }
    }

    /// Positions are equal ignoring assertions.
    static func samePosition(_ a: Target.Position, _ b: Target.Position) -> Bool {
        switch (a, b) {
        case (.range(let x), .range(let y)):
            return x.start.withoutAssertions == y.start.withoutAssertions && x.end.withoutAssertions == y.end.withoutAssertions
        case (.point(let x), .point(let y)):
            return x.withoutAssertions == y.withoutAssertions
        default:
            return a == b
        }
    }

    static func position(_ vector: Vector) -> Target.Position {
        vector.isPoint ? .point(CFI(vector.cfi)!) : .range(CFIRange(vector.cfi)!)
    }

    // MARK: Generation

    @Test(arguments: vectors.map(\.name))
    func generation(_ name: String) async throws {
        let vector = try #require(Self.vectors.first { $0.name == name })
        let container = try await Self.container()
        let annotation = try Self.annotation(vector, in: container.publication)
        #expect(annotation.target.source == vector.source)
        let generated = await AnnotationResolver(container: container).generatingSelectors(for: [annotation])
        #expect(generated.first?.target.generatedSelectors == vector.selectors)
    }

    @Test func generationSkipsAnnotationsWithOriginals() async throws {
        let container = try await Self.container()
        let vector = Self.vectors[0]
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON([.css(value: "p", refinedBy: [])]))])
        let out = await AnnotationResolver(container: container).generatingSelectors(for: set)
        #expect(out.items[0].target.generatedSelectors == nil)
    }

    @Test func exportWritesGeneratedSelectorsAndTheCFILast() async throws {
        let container = try await Self.container()
        let vector = Self.vectors[0]
        let set = AnnotationSet(items: [try Self.annotation(vector, in: container.publication)])
        let generated = await AnnotationResolver(container: container).generatingSelectors(for: set)
        let data = try AnnotationCodec.encode(generated, mode: .export(ExportOptions()))
        let json = try JSONParser.parse(data, limits: JSONParseLimits(maxDepth: 32, maxStringBytes: 1 << 20, overlongMarker: "?"))
        let selectors = try #require(json.objectValue?["items"]?.arrayValue?.first?.objectValue?["target"]?.objectValue?["selector"]?.arrayValue)
        #expect(selectors.compactMap { $0.objectValue?["type"]?.stringValue } == ["CssSelector", "TextQuoteSelector", "epubswift:CfiSelector"])
        // A single refinement is written as an object.
        #expect(selectors[0].objectValue?["refinedBy"]?.objectValue?["type"] == .string("TextPositionSelector"))
    }

    // MARK: Resolution

    /// Every vector resolves back from its standard selectors alone (no CFI).
    @Test(arguments: vectors.map(\.name))
    func resolution(_ name: String) async throws {
        let vector = try #require(Self.vectors.first { $0.name == name })
        let container = try await Self.container()
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON(vector.selectors))])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        let resolved = try #require(resolution.annotationSet.items.first)
        #expect(Self.samePosition(resolved.target.position, Self.position(vector)), "\(resolved.target.position)")
        #expect(resolution.methods[resolved.id] == .cssSelector)
        // The originals are kept for the round trip.
        #expect(resolved.target.originalSelectors == vector.selectors)
    }

    /// The quote alone also finds the position (for ranges).
    @Test(arguments: vectors.filter { $0.exact != nil }.map(\.name))
    func resolutionFromTheQuoteAlone(_ name: String) async throws {
        let vector = try #require(Self.vectors.first { $0.name == name })
        let container = try await Self.container()
        let quote = try #require(vector.selectors.last)
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON([quote]))])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        let resolved = try #require(resolution.annotationSet.items.first)
        #expect(Self.samePosition(resolved.target.position, Self.position(vector)), "\(resolved.target.position)")
        #expect(resolution.methods[resolved.id] == .textQuote)
    }

    @Test func cfiThatAgreesWithTheStandardSelectorsIsKept() async throws {
        let container = try await Self.container()
        let vector = Self.vectors[0]
        let cfi = "epubcfi(/6/2[c1]!/4[body]/4[p1],/1:8[Call me ,Ishmael. S],/1:15[me Ishmael,. Some yea])"
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON(vector.selectors + [.cfi(cfi)]))])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        let resolved = try #require(resolution.annotationSet.items.first)
        #expect(resolved.target.position == .range(CFIRange(cfi)!))
        #expect(resolution.methods[resolved.id] == .cfi)
    }

    /// Another system fixed the standard selectors and left a stale CFI: the standard selectors win.
    @Test func standardSelectorsWinOverAStaleCFI() async throws {
        let container = try await Self.container()
        let vector = Self.vectors[0]
        let stale = "epubcfi(/6/2[c1]!/4[body]/6[p2],/1:0,/1:5)" // "First"
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON(vector.selectors + [.cfi(stale)]))])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        let resolved = try #require(resolution.annotationSet.items.first)
        #expect(Self.samePosition(resolved.target.position, Self.position(vector)))
        #expect(resolution.methods[resolved.id] == .cssSelector)
    }

    @Test func cfiAloneIsTakenWhenThereAreNoStandardSelectors() async throws {
        let container = try await Self.container()
        let vector = Self.vectors[0]
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON([.cfi(vector.cfi), .unknown(["type": .string("x:Other")])]))])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        #expect(resolution.annotationSet.items[0].target.position == Self.position(vector))
        #expect(resolution.methods[resolution.annotationSet.items[0].id] == .cfi)
    }

    /// An edited copy of the book: the paragraph gained words before the highlight. The CSS position now covers
    /// other text, so the quote corrects it, and a CFI without assertions loses to it.
    @Test func quoteCorrectsThePositionInAnEditedBook() async throws {
        let edited = try Self.editedSample { $0.replacingOccurrences(of: "<p id=\"p1\">Call me Ishmael.", with: "<p id=\"p1\">Indeed, they call me Ishmael.") }
        let container = try await EPUBContainer(data: edited)
        let vector = Self.vectors[0]
        let set = try Self.importedSet([vector.json(selectors: Self.selectorJSON(vector.selectors + [.cfi("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:8,/1:15)")]))])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        let resolved = try #require(resolution.annotationSet.items.first)
        #expect(resolution.methods[resolved.id] == .textQuote)
        // "Indeed, they call me " is 21 UTF-16 code units.
        #expect(Self.samePosition(resolved.target.position, .range(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:21,/1:28)")!)))
    }

    /// Builds cfi-sample.epub with `c1.xhtml` changed and `adding` files added.
    static func editedSample(_ edit: (String) -> String, adding: [String: Data] = [:]) throws -> Data {
        let archive = try ZIPArchive(url: Fixtures.url("cfi-sample.epub"))
        var writer = TestZIPWriter()
        for entry in archive.entryOrder where !entry.isDirectory {
            var data = try archive.data(for: entry)
            if entry.path == "OPS/c1.xhtml" {
                data = Data(edit(String(decoding: data, as: UTF8.self)).utf8)
            }
            writer.add(entry.rawName, data: data)
        }
        for (name, data) in adding.sorted(by: { $0.key < $1.key }) {
            writer.add(name, data: data)
        }
        return writer.build()
    }

    /// A real book: highlights on search results across Moby-Dick, exported without the CFI selector and resolved
    /// back from the standard selectors only, land on the same text.
    @Test func mobyDickRoundTripWithoutCFI() async throws {
        let container = try await EPUBContainer(url: Fixtures.mobyDick)
        var annotations: [Annotation] = []
        for try await result in SearchService(container: container).search("whale") {
            annotations.append(Annotation.highlight(result.range, in: container.publication))
            if annotations.count >= 400 { break }
        }
        #expect(annotations.count == 400)
        let resolver = AnnotationResolver(container: container)
        let clock = ContinuousClock()
        let started = clock.now
        let generated = await resolver.generatingSelectors(for: AnnotationSet(items: annotations))
        #expect(generated.items.allSatisfy { $0.target.generatedSelectors?.count == 2 })
        let data = try AnnotationCodec.encode(generated, mode: .export(ExportOptions(includesCFI: false)))
        let (imported, warnings) = try AnnotationCodec.decode(data)
        #expect(warnings.isEmpty)
        let resolution = await resolver.resolve(imported)
        let elapsed = clock.now - started
        #expect(elapsed < .seconds(20), "\(elapsed)")
        #expect(resolution.unresolvedIDs.isEmpty)
        for (original, resolved) in zip(annotations, resolution.annotationSet.items) {
            #expect(Self.samePosition(original.target.position, resolved.target.position), "\(original.target.position) → \(resolved.target.position)")
        }
        #expect(resolution.match.resolvedPositionRatio == 1)
    }

    @Test func sourcePaths() async throws {
        let container = try await Self.container()
        let publication = container.publication
        #expect(AnnotationResolver.spineIndex(forSource: "OPS/c1.xhtml", in: publication) == 0)
        #expect(AnnotationResolver.spineIndex(forSource: "OPS/c1.xhtml#p1", in: publication) == 0)
        #expect(AnnotationResolver.spineIndex(forSource: "./OPS/../OPS/c2.xhtml", in: publication) == 1)
        // Relative to the package document's directory.
        #expect(AnnotationResolver.spineIndex(forSource: "c2.xhtml", in: publication) == 1)
        // Refused: leaving the container, absolute paths and URLs, non-spine resources.
        // "../" is fine relative to the package directory (OPS/../OPS/c1.xhtml), not beyond the root.
        #expect(AnnotationResolver.spineIndex(forSource: "../OPS/c1.xhtml", in: publication) == 0)
        #expect(AnnotationResolver.spineIndex(forSource: "../../OPS/c1.xhtml", in: publication) == nil)
        #expect(AnnotationResolver.spineIndex(forSource: "OPS/../../../OPS/c1.xhtml", in: publication) == nil)
        #expect(AnnotationPath.resolveContained("../a.xhtml") == nil)
        #expect(AnnotationResolver.spineIndex(forSource: "/OPS/c1.xhtml", in: publication) == nil)
        #expect(AnnotationResolver.spineIndex(forSource: "https://example.com/OPS/c1.xhtml", in: publication) == nil)
        #expect(AnnotationResolver.spineIndex(forSource: "OPS/dot.png", in: publication) == nil)

        let set = try Self.importedSet([Self.vectors[0].json(selectors: Self.selectorJSON(Self.vectors[0].selectors))].map { item in
            guard case .object(var object) = item, case .object(var target)? = object["target"] else { return item }
            target["source"] = .string("../../etc/passwd")
            object["target"] = .object(target)
            return .object(object)
        })
        let resolution = await AnnotationResolver(container: container).resolve(set)
        #expect(resolution.annotationSet.items[0].target.position == .unresolved)
        #expect(resolution.unresolvedIDs == [resolution.annotationSet.items[0].id])
        #expect(resolution.match.resolvedSourceRatio == 0)
    }

    @Test func fragmentSelectors() async throws {
        let container = try await Self.container()
        func item(_ id: String, motivation: String = "highlighting", _ selector: JSONValue) -> JSONValue {
            .object([
                "id": .string(id), "motivation": .string(motivation), "created": .string("2026-11-10T00:00:00Z"),
                "target": .object(["source": .string("OPS/c1.xhtml"), "selector": .array([selector])]),
            ])
        }
        func fragment(_ value: String, _ conformsTo: String?) -> JSONValue {
            var object: JSONObject = ["type": .string("FragmentSelector"), "value": .string(value)]
            if let conformsTo { object["conformsTo"] = .string(conformsTo) }
            return .object(object)
        }
        let set = try Self.importedSet([
            item("element", fragment("p2", "http://tools.ietf.org/rfc/rfc3236")),
            item("element-bookmark", motivation: "bookmarking", fragment("p2", "http://tools.ietf.org/rfc/rfc3236")),
            item("text", fragment(":~:text=Some%20years,ago", "https://wicg.github.io/scroll-to-text-fragment/")),
            item("text-context", fragment(":~:text=Call%20me-,Ishmael,-.%20Some", "https://wicg.github.io/scroll-to-text-fragment/")),
            item("media", fragment("xywh=50,50,640,480", "http://www.w3.org/TR/media-frags/")),
            item("svg", fragment("svgView(viewBox(0,0,1,1))", "http://www.w3.org/TR/SVG/")),
            item("missing", fragment("nope", "http://tools.ietf.org/rfc/rfc3236")),
        ])
        let resolution = await AnnotationResolver(container: container).resolve(set)
        let positions = Dictionary(uniqueKeysWithValues: resolution.annotationSet.items.map { ($0.id, $0.target.position) })
        // p2's text: "First " + "emphasised" + " and " + "strong" + " words." → ends in its last text node at 7.
        #expect(Self.samePosition(positions["element"]!, .range(CFIRange("epubcfi(/6/2[c1]!/4[body]/6[p2],/1:0,/5:7)")!)))
        #expect(Self.samePosition(positions["element-bookmark"]!, .point(CFI("epubcfi(/6/2[c1]!/4[body]/6[p2]/1:0)")!)))
        #expect(Self.samePosition(positions["text"]!, .range(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:17,/1:31)")!)))
        #expect(Self.samePosition(positions["text-context"]!, .range(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:8,/1:15)")!)))
        #expect(positions["media"] == .unresolved)
        #expect(positions["svg"] == .unresolved)
        #expect(positions["missing"] == .unresolved)
        #expect(resolution.methods["text"] == .textFragment)
        #expect(resolution.methods["element"] == .elementFragment)
    }

    @Test func ownAnnotationsAreTrusted() async throws {
        let container = try await Self.container()
        // A position that no longer matches anything is still kept: it was made here.
        var annotation = Annotation.highlight(try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:8,/1:15)")), in: container.publication)
        annotation.target.source = "OPS/c1.xhtml"
        let resolution = await AnnotationResolver(container: container).resolve(AnnotationSet(items: [annotation]))
        #expect(resolution.annotationSet.items == [annotation])
        #expect(resolution.methods[annotation.id] == .trusted)
        #expect(resolution.match.resolvedPositionRatio == 1)
    }

    @Test func setMatch() async throws {
        let container = try await Self.container()
        var about = AnnotationSet.About(publication: container.publication)
        var resolution = await AnnotationResolver(container: container).resolve(AnnotationSet(about: about))
        #expect(resolution.match.identifier == .match)
        #expect(resolution.match.title == .match)
        #expect(resolution.match.creators == .absent) // the sample has no creator
        about.title = "  cfi   SAMPLE "
        about.identifier = "urn:other"
        resolution = await AnnotationResolver(container: container).resolve(AnnotationSet(about: about))
        #expect(resolution.match.title == .match)
        #expect(resolution.match.identifier == .mismatch)
        about.title = "Another book"
        resolution = await AnnotationResolver(container: container).resolve(AnnotationSet(about: about))
        #expect(resolution.match.title == .mismatch)
    }

    // MARK: CSS subset

    @Test func cssParsing() {
        #expect(CSSSubset.parse("#intro > p:nth-child(2)") == [
            CSSSubset.Compound(type: nil, id: "intro"),
            CSSSubset.Compound(type: "p", nthChild: 2),
        ])
        #expect(CSSSubset.parse("body>:nth-of-type(3)") == [
            CSSSubset.Compound(type: "body"),
            CSSSubset.Compound(nthOfType: 3),
        ])
        #expect(CSSSubset.parse(#"#\31 23"#) == [CSSSubset.Compound(id: "123")])
        for unsupported in [".class", "div p", "p:nth-child(2n+1)", "[id=x]", "p ~ q", "svg|rect", "p:first-child", "", "#"] {
            #expect(CSSSubset.parse(unsupported) == nil, "\(unsupported)")
        }
    }

    @Test func cssEscaping() {
        #expect(CSSSubset.escapeIdentifier("p1") == "p1")
        #expect(CSSSubset.escapeIdentifier("123") == #"\31 23"#)
        #expect(CSSSubset.escapeIdentifier("-1") == #"-\31 "#)
        #expect(CSSSubset.escapeIdentifier("-") == #"\-"#)
        #expect(CSSSubset.escapeIdentifier("a b.c") == #"a\ b\.c"#)
        #expect(CSSSubset.escapeIdentifier("見出し") == "見出し")
        for id in ["123", "-1", "a b.c", "x:y", "見出し"] {
            #expect(CSSSubset.parse("#" + CSSSubset.escapeIdentifier(id))?.first?.id == id)
        }
    }

    @Test func cssEvaluation() throws {
        let xml = #"""
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>
        <div id="a"><p>1</p><span>2</span><p>3</p></div><div><p>4</p></div></body></html>
        """#
        let document = try XMLDocument(data: Data(xml.utf8), tree: .source)
        func text(_ selector: String) -> String? {
            CSSSubset.evaluate(selector, in: document, idCounts: [:]).flatMap { document.element(at: $0)?.textContent }
        }
        #expect(text("#a > :nth-child(2)") == "2")
        #expect(text("#a > p:nth-of-type(2)") == "3")
        #expect(text("#a > span:nth-child(1)") == nil)
        #expect(text("body > :nth-child(2) > p") == "4")
        #expect(text("div > p") == "1")
        #expect(text("BODY > DIV:nth-child(1) > P:nth-child(3)") == "3")
    }
}
