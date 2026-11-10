import Foundation
import Testing
@testable import EPUBCore

/// JSON encoding and decoding of EPUB Annotations (docs/design/06-annotations.md §4, §14).
struct AnnotationCodecTests {
    static let created = Date(timeIntervalSince1970: 1_793_000_000.123) // 2026-10-26T07:33:20.123Z

    static func sampleSet() throws -> AnnotationSet {
        let range = try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0[,Call me],/1:15[Ishmael,. Some])"))
        let highlight = Annotation(
            id: "urn:uuid:9b1c0000-0000-4000-8000-000000000001",
            motivation: .highlighting,
            created: created,
            modified: created.addingTimeInterval(3600),
            creator: Creator(id: "urn:uuid:person", kind: .person, name: LocalizableText("Reader", language: "en")),
            target: Target(source: "OPS/text/c1 a.xhtml", position: .range(range)),
            body: Body(content: .text(LocalizableText("ノート", language: "ja")), color: .blue, style: .underline, tags: ["t1", "t2"])
        )
        let bookmark = Annotation(
            id: "urn:uuid:9b1c0000-0000-4000-8000-000000000002",
            motivation: .bookmarking,
            created: created,
            target: Target(source: "OPS/text/c1 a.xhtml", position: .point(range.start))
        )
        return AnnotationSet(
            id: "urn:uuid:3f0d6a2e-0000-4000-8000-000000000000",
            generated: created,
            about: AnnotationSet.About(title: "Moby-Dick", creators: ["Herman Melville"], publisher: "P", date: "1851", identifier: "urn:isbn:1"),
            items: [highlight, bookmark],
            defaultLanguage: "en"
        )
    }

    @Test func storageRoundTripKeepsEverything() throws {
        let set = try Self.sampleSet()
        let data = try AnnotationCodec.encode(set, mode: .storage)
        let (decoded, warnings) = try AnnotationCodec.decode(data)
        #expect(warnings.isEmpty)
        #expect(decoded == set)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"epubswift:origin\""))
        #expect(text.contains("\"OPS/text/c1%20a.xhtml\""))
        #expect(text.contains("2026-10-26T07:33:20.123Z"))
    }

    @Test func exportDefaultsShareLittle() throws {
        let set = try Self.sampleSet()
        let data = try AnnotationCodec.encode(set, mode: .export(ExportOptions()))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"creator\""))
        #expect(!text.contains("epubswift:origin"))
        #expect(text.contains("\"created\": \"2026-10-26T00:00:00Z\""))
        #expect(text.contains("\"generated\": \"2026-10-26T00:00:00Z\""))
        #expect(text.contains("epubswift:CfiSelector"))
        #expect(text.contains("\"dc:identifier\": \"urn:isbn:1\""))
        #expect(text.contains("\"@language\": \"en\""))
        // The bookmark has no note: no body.
        let (decoded, _) = try AnnotationCodec.decode(data)
        #expect(decoded.items[1].body == nil)
        #expect(decoded.items[0].body?.color == .blue)
        #expect(decoded.items[0].creator == nil)
        #expect(decoded.items[0].target.position == set.items[0].target.position)
        if case .imported(let setID, _) = decoded.items[0].origin {
            #expect(setID == set.id)
        } else {
            Issue.record("expected an imported origin")
        }
    }

    @Test func exportOptions() throws {
        let set = try Self.sampleSet()
        let options = ExportOptions(includesCreator: true, timestampPrecision: .second, includesCFI: false)
        let text = String(decoding: try AnnotationCodec.encode(set, mode: .export(options)), as: UTF8.self)
        #expect(text.contains("\"creator\""))
        #expect(text.contains("\"created\": \"2026-10-26T07:33:20Z\""))
        #expect(!text.contains("CfiSelector"))
        // Without any selector the CFI-only target has no selector array; decoding gives a whole-document target.
        let (decoded, _) = try AnnotationCodec.decode(Data(text.utf8))
        #expect(decoded.items[0].target.position == .resource)
    }

    @Test func filterLeavesOutPublicationAnnotationsByDefault() throws {
        var set = try Self.sampleSet()
        set.items[1].origin = .publication
        let (decoded, _) = try AnnotationCodec.decode(try AnnotationCodec.encode(set, mode: .export(ExportOptions())))
        #expect(decoded.items.map(\.id) == [set.items[0].id])
        var options = ExportOptions()
        options.filter = AnnotationFilter(motivations: [.bookmarking], origins: [.local, .imported, .publication])
        let (only, _) = try AnnotationCodec.decode(try AnnotationCodec.encode(set, mode: .export(options)))
        #expect(only.items.map(\.id) == [set.items[1].id])
        options.filter = AnnotationFilter(tags: ["t2"])
        #expect(try AnnotationCodec.decode(try AnnotationCodec.encode(set, mode: .export(options))).0.items.count == 1)
    }

    /// The shapes of the specification's examples (Examples 3–6 and 8–9) read.
    @Test func specificationExamples() throws {
        let json = #"""
        {
          "@context": ["https://www.w3.org/ns/epub-anno.jsonld", {"@language": "en", "@direction": "ltr"}],
          "id": "urn:uuid:123-123-123-123",
          "type": "AnnotationSet",
          "generated": "2023-09-01T10:00:00Z",
          "about": {
            "dc:title": "Alice in Wonderland",
            "dc:publisher": {"text": "Example Publisher", "language": "en"},
            "dc:creator": ["Anne O'Tater"],
            "dc:date": "1865",
            "dc:subject": "Fiction"
          },
          "items": [
            {
              "id": "urn:uuid:234-234-234-234",
              "type": "Annotation",
              "motivation": "highlighting",
              "created": "2023-09-01T10:00:00Z",
              "target": {
                "source": "OEBPS/text/chapter1.html",
                "selector": [{
                  "type": "CssSelector",
                  "value": "#intro > p:nth-child(2)",
                  "refinedBy": {"type": "TextPositionSelector", "start": 4, "end": 19}
                }]
              },
              "body": {"type": "TextualBody", "value": "j'adore !", "tags": ["teacher"], "color": "blue", "highlight": "underline"}
            },
            {
              "id": "urn:uuid:234-234-234-235",
              "type": "Annotation",
              "created": "2023-09-01T10:00:00+02:00",
              "target": {"source": "OEBPS/text/chapter2.html"},
              "body": {"type": "Audio", "id": "./voice1.mp3", "tags": ["correction"], "color": "pink"}
            },
            {
              "id": "urn:uuid:234-234-234-236",
              "type": "Annotation",
              "motivation": "highlighting",
              "created": "2023-09-01",
              "target": {"source": "OEBPS/text/chapter1.html", "selector": {"type": "FragmentSelector", "conformsTo": "http://www.w3.org/TR/media-frags/", "value": "xywh=50,50,640,480"}},
              "body": {"type": "TextualBody", "value": {"language": "he", "direction": "rtl", "text": "HTML היא שפת סימון."}}
            }
          ]
        }
        """#
        let (set, warnings) = try AnnotationCodec.decode(Data(json.utf8))
        #expect(warnings.isEmpty)
        #expect(set.defaultLanguage == "en")
        #expect(set.defaultDirection == .ltr)
        #expect(set.about.title == "Alice in Wonderland")
        #expect(set.about.publisher == LocalizableText("Example Publisher", language: "en"))
        #expect(set.about.extensions["dc:subject"] == .string("Fiction"))
        #expect(set.items.count == 3)
        let first = set.items[0]
        #expect(first.motivation == .highlighting)
        #expect(first.target.position == .unresolved)
        #expect(first.target.originalSelectors == [.css(value: "#intro > p:nth-child(2)", refinedBy: [.textPosition(start: 4, end: 19, refinedBy: [])])])
        #expect(first.body?.style == .underline)
        #expect(first.body?.tags == ["teacher"])
        let second = set.items[1]
        #expect(second.motivation == .bookmarking) // no motivation
        #expect(second.target.position == .resource)
        #expect(second.body?.content == .audio("./voice1.mp3"))
        #expect(second.body?.color == .pink)
        #expect(second.body?.style == .solid)
        #expect(second.created == Date(timeIntervalSince1970: 1_693_555_200)) // 08:00Z
        let third = set.items[2]
        #expect(third.note == LocalizableText("HTML היא שפת סימון.", language: "he", direction: .rtl))
        #expect(third.target.originalSelectors?.count == 1)

        // Written back, the original selectors keep their exact JSON (the single-object `refinedBy`).
        let exported = String(decoding: try AnnotationCodec.encode(set, mode: .export(ExportOptions(timestampPrecision: .second))), as: UTF8.self)
        #expect(exported.contains("\"refinedBy\": {"))
        #expect(exported.contains("\"dc:subject\": \"Fiction\""))
        let (again, _) = try AnnotationCodec.decode(Data(exported.utf8))
        #expect(again.items.map(\.target.originalSelectors) == set.items.map(\.target.originalSelectors))
    }

    @Test func unknownPropertiesRoundTrip() throws {
        let json = #"""
        {"type": "AnnotationSet", "id": "urn:x", "x:set": 1, "about": {}, "items": [
          {"id": "a", "type": "Annotation", "motivation": "highlighting", "created": "2026-01-01T00:00:00Z", "x:annotation": {"deep": [1, 2.5, true, null]},
           "creator": {"id": "c", "type": "Software", "x:creator": "v"},
           "target": {"source": "a.xhtml", "x:target": "t", "selector": [
              {"type": "CssSelector", "value": "p", "x:selector": 1, "refinedBy": [{"type": "TextPositionSelector", "start": 0, "end": 1}, {"type": "TextPositionSelector", "start": 2, "end": 3}]},
              {"type": "x:OwnSelector", "value": 42}
           ]},
           "body": [{"type": "TextualBody", "value": "n", "x:body": false}, {"type": "TextualBody", "value": "second"}]}
        ]}
        """#
        let (set, _) = try AnnotationCodec.decode(Data(json.utf8))
        let a = try #require(set.items.first)
        #expect(a.extensions["x:annotation"] != nil)
        #expect(a.creator?.extensions["x:creator"] == .string("v"))
        #expect(a.target.extensions["x:target"] == .string("t"))
        #expect(a.body?.extensions["x:body"] == .bool(false))
        #expect(a.target.originalSelectors?.last == .unknown(["type": .string("x:OwnSelector"), "value": .number(42)]))
        let out = try AnnotationCodec.encode(set, mode: .export(ExportOptions(includesCreator: true, timestampPrecision: .second, includesCFI: false)))
        let reparsed = try JSONParser.parse(out, limits: JSONParseLimits(maxDepth: 64, maxStringBytes: 1 << 20, overlongMarker: "?"))
        let original = try JSONParser.parse(Data(json.utf8), limits: JSONParseLimits(maxDepth: 64, maxStringBytes: 1 << 20, overlongMarker: "?"))
        // Everything read comes back: compare the item and the set's own member.
        #expect(reparsed.objectValue?["x:set"] == original.objectValue?["x:set"])
        let item = try #require(reparsed.objectValue?["items"]?.arrayValue?.first?.objectValue)
        let originalItem = try #require(original.objectValue?["items"]?.arrayValue?.first?.objectValue)
        #expect(item["target"] == originalItem["target"])
        #expect(item["x:annotation"] == originalItem["x:annotation"])
        #expect(item["creator"] == originalItem["creator"])
        let bodies = try #require(item["body"]?.arrayValue)
        #expect(bodies.count == 2)
        #expect(bodies[1] == originalItem["body"]?.arrayValue?[1])
    }

    @Test func changingThePositionDropsTheOriginals() throws {
        let json = #"""
        {"type": "AnnotationSet", "items": [{"id": "a", "motivation": "highlighting", "created": "2026-01-01T00:00:00Z",
          "target": {"source": "a.xhtml", "selector": [{"type": "CssSelector", "value": "#x"}, {"type": "epubswift:CfiSelector", "value": "epubcfi(/6/2!/4/2,/1:0,/1:3)"}]}}]}
        """#
        var annotation = try #require(try AnnotationCodec.decode(Data(json.utf8)).0.items.first)
        #expect(annotation.range == CFIRange("epubcfi(/6/2!/4/2,/1:0,/1:3)"))
        #expect(annotation.target.originalSelectors?.count == 2)
        annotation.target.position = .range(try #require(CFIRange("epubcfi(/6/2!/4/2,/1:1,/1:3)")))
        #expect(annotation.target.originalSelectors == nil)
        let out = String(decoding: try AnnotationCodec.encode(AnnotationSet(items: [annotation]), mode: .export(ExportOptions())), as: UTF8.self)
        #expect(!out.contains("CssSelector"))
        #expect(out.contains("/1:1"))
    }

    @Test func tolerantReading() throws {
        let json = #"""
        {"type": ["AnnotationSet"], "items": [
          {"id": "ok", "created": "2026-01-01T00:00:00Z", "target": [{"source": "a.xhtml"}, {"source": "b.xhtml"}]},
          {"id": "no-target", "created": "2026-01-01T00:00:00Z"},
          {"created": "2026-01-01T00:00:00Z", "target": {"source": "a.xhtml"}},
          {"id": "bad-date", "created": "yesterday", "target": {"source": "a.xhtml"}},
          {"id": "ok", "created": "2026-01-01T00:00:00Z", "target": {"source": "a.xhtml"}},
          "not an object",
          {"id": "single-refined", "motivation": ["highlighting"], "created": "2026-01-01T00:00:00Z", "target": {"source": "a.xhtml", "selector": {"type": "CssSelector", "value": "p", "refinedBy": {"type": "TextPositionSelector", "start": 1, "end": 2}}}}
        ]}
        """#
        let (set, warnings) = try AnnotationCodec.decode(Data(json.utf8))
        #expect(set.items.map(\.id) == ["ok", "single-refined"])
        #expect(set.items[0].target.source == "a.xhtml")
        #expect(set.items[1].target.originalSelectors == [.css(value: "p", refinedBy: [.textPosition(start: 1, end: 2, refinedBy: [])])])
        #expect(warnings.count == 5)
        #expect(warnings.contains(.duplicateID("ok")))
        #expect(warnings.contains { if case .invalidAnnotation(index: 3, id: "bad-date", _) = $0 { return true } else { return false } })
    }

    @Test func notASetFails() {
        #expect(throws: AnnotationCodecError.notAnAnnotationSet) {
            try AnnotationCodec.decode(Data(#"{"type": "Annotation", "items": []}"#.utf8))
        }
        #expect(throws: AnnotationCodecError.notAnAnnotationSet) {
            try AnnotationCodec.decode(Data(#"{"type": "AnnotationSet"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try AnnotationCodec.decode(Data("{".utf8))
        }
    }

    @Test func limits() throws {
        func item(_ i: Int, value: String = "x") -> String {
            #"{"id": "a\#(i)", "created": "2026-01-01T00:00:00Z", "target": {"source": "a.xhtml"}, "body": {"type": "TextualBody", "value": "\#(value)"}}"#
        }
        let items = (0..<5).map { item($0) }.joined(separator: ",")
        let json = Data(#"{"type": "AnnotationSet", "items": [\#(items)]}"#.utf8)
        var limits = AnnotationImportLimits()
        limits.maxAnnotations = 3
        let (set, warnings) = try AnnotationCodec.decode(json, limits: limits)
        #expect(set.items.count == 3)
        #expect(warnings == [.tooManyAnnotations(limit: 3, dropped: 2)])

        limits = AnnotationImportLimits(maxStringBytes: 24)
        let long = Data(#"{"type": "AnnotationSet", "items": [\#(item(0, value: String(repeating: "あ", count: 10))), \#(item(1))]}"#.utf8)
        let (shortSet, shortWarnings) = try AnnotationCodec.decode(long, limits: limits)
        #expect(shortSet.items.map(\.id) == ["a1"])
        #expect(shortWarnings == [.stringTooLong(index: 0)])

        limits = AnnotationImportLimits(maxJSONBytes: 10)
        #expect(throws: AnnotationCodecError.tooLarge(bytes: json.count, limit: 10)) { try AnnotationCodec.decode(json, limits: limits) }

        limits = AnnotationImportLimits(maxNestingDepth: 4)
        let deep = Data(#"{"type": "AnnotationSet", "items": [{"x": {"y": {"z": 1}}}]}"#.utf8)
        #expect(throws: AnnotationCodecError.nestingTooDeep(limit: 4)) { try AnnotationCodec.decode(deep, limits: limits) }

        limits = AnnotationImportLimits(maxRefinementDepth: 2)
        let refined = Data(#"""
        {"type": "AnnotationSet", "items": [{"id": "r", "created": "2026-01-01T00:00:00Z", "target": {"source": "a.xhtml", "selector":
          {"type": "CssSelector", "value": "p", "refinedBy": {"type": "CssSelector", "value": "p", "refinedBy": {"type": "CssSelector", "value": "p", "refinedBy": {"type": "TextPositionSelector", "start": 0, "end": 1}}}}}}]}
        """#.utf8)
        #expect(throws: AnnotationCodecError.refinementTooDeep(limit: 2)) { try AnnotationCodec.decode(refined, limits: limits) }
    }

    @Test func singleAnnotationDocument() throws {
        let annotation = try Self.sampleSet().items[0]
        let data = try AnnotationCodec.encode(annotation, mode: .storage)
        #expect(String(decoding: data, as: UTF8.self).contains("\"@context\""))
        #expect(try AnnotationCodec.decodeAnnotation(data) == annotation)
    }

    @Test func dates() {
        #expect(AnnotationDate.parse("2026-11-10T01:02:03Z") == Date(timeIntervalSince1970: 1_794_272_523))
        #expect(AnnotationDate.parse("2026-11-10T10:02:03+09:00") == Date(timeIntervalSince1970: 1_794_272_523))
        #expect(AnnotationDate.parse("2026-11-10T01:02:03.5Z") == Date(timeIntervalSince1970: 1_794_272_523.5))
        #expect(AnnotationDate.parse("2026") != nil)
        #expect(AnnotationDate.parse("2026-13-01") == nil)
        #expect(AnnotationDate.parse("2026-11-10T01:02:03Zjunk") == nil)
        let date = Date(timeIntervalSince1970: 1_794_272_523.25)
        #expect(AnnotationDate.format(date, precision: .day) == "2026-11-10T00:00:00Z")
        #expect(AnnotationDate.format(date, precision: .second) == "2026-11-10T01:02:03Z")
        #expect(AnnotationDate.format(date, precision: .millisecond) == "2026-11-10T01:02:03.250Z")
    }

    @Test func jsonParserIsStrict() throws {
        let limits = JSONParseLimits(maxDepth: 8, maxStringBytes: 100, overlongMarker: "!")
        #expect(throws: (any Error).self) { try JSONParser.parse(Data("[1,]".utf8), limits: limits) }
        #expect(throws: (any Error).self) { try JSONParser.parse(Data("01".utf8), limits: limits) }
        #expect(throws: (any Error).self) { try JSONParser.parse(Data(#""\ud800""#.utf8), limits: limits) }
        let parsed = try JSONParser.parse(Data(#"["😀", -1.5e2, "é"]"#.utf8), limits: limits)
        #expect(parsed == .array([.string("😀"), .number(-150), .string("é")]))
        #expect(JSONWriter.quoted("a\"\n\u{01}") == #""a\"\n\u0001""#)
    }

    @Test func factories() throws {
        let publication = try EPUBContainer.Loader.load(data: Data(contentsOf: Fixtures.url("cfi-sample.epub")), url: nil).publication
        let range = try #require(CFIRange("epubcfi(/6/2[c1]!/4[body]/4[p1],/1:0,/1:4)"))
        let highlight = Annotation.highlight(range, in: publication, color: .green, style: .outline)
        #expect(highlight.target.source == publication.readingOrder[0].path)
        #expect(highlight.id.hasPrefix("urn:uuid:"))
        #expect(highlight.color == .green)
        #expect(highlight.style == .outline)
        #expect(highlight.spineIndex == 0)
        let bookmark = Annotation.bookmark(at: range.start, in: publication)
        #expect(bookmark.body == nil)
        #expect(bookmark.motivation == .bookmarking)
        let about = AnnotationSet.About(publication: publication)
        #expect(about.identifier == publication.metadata.identifier)
    }
}
