import Foundation
import Testing
@testable import EPUBCore

/// Shared CFI test vectors (`Tests/Fixtures/cfi-vectors.json`, docs/design/01-core.md §5.3). The same file drives
/// the JavaScript implementation in `Tests/EPUBRendererTests/CFIScriptTests.swift`.
struct CFIVectors: Decodable {
    struct Resolve: Decodable {
        var name: String
        var cfi: String
        var text: String?
        var offset: Int?
        var elementId: String?
        var usedTextAssertion: Bool?
        var generated: String?
    }
    struct Parse: Decodable {
        var cfi: String
        var canonical: String?
        var invalid: Bool?
    }
    struct RangeCase: Decodable {
        var cfi: String
        var start: String
        var end: String
        var canonical: String
    }
    struct SpineCase: Decodable {
        var cfi: String
        var spineIndex: Int
        var derived: Int?
    }
    var epub: String
    var documentPath: String
    var spineSteps: String
    var resolve: [Resolve]
    var parse: [Parse]
    var ranges: [RangeCase]
    var order: [[String]]
    var spineIndex: [SpineCase]

    static func load() throws -> CFIVectors {
        try JSONDecoder().decode(CFIVectors.self, from: Data(contentsOf: Fixtures.url("cfi-vectors.json")))
    }
}

@Suite struct CFITests {
    @Test func parsesAndRendersVectors() throws {
        let vectors = try CFIVectors.load()
        for vector in vectors.parse {
            let parsed = CFI(vector.cfi)
            if vector.invalid == true {
                #expect(parsed == nil, "\(vector.cfi) should not parse")
            } else {
                #expect(parsed?.description == vector.canonical, "\(vector.cfi)")
                // Round trip of the canonical form.
                if let canonical = vector.canonical {
                    #expect(CFI(canonical)?.description == canonical)
                }
            }
        }
    }

    @Test func parsesRangeVectors() throws {
        let vectors = try CFIVectors.load()
        for vector in vectors.ranges {
            let range = try #require(CFIRange(vector.cfi), Comment(rawValue: vector.cfi))
            #expect(range.start.description == vector.start, Comment(rawValue: vector.cfi))
            #expect(range.end.description == vector.end, Comment(rawValue: vector.cfi))
            #expect(range.description == vector.canonical, Comment(rawValue: vector.cfi))
            #expect(CFIRange(range.description) == range)
        }
    }

    @Test func ordersPositions() throws {
        let vectors = try CFIVectors.load()
        for pair in vectors.order {
            let a = try #require(CFI(pair[0]))
            let b = try #require(CFI(pair[1]))
            #expect(a < b, "\(pair[0]) < \(pair[1])")
            #expect(!(b < a))
            #expect(CFI.comparePosition(a, b) < 0)
        }
        let a = try #require(CFI("epubcfi(/6/2!/4/4/1:5)"))
        let withAssertion = try #require(CFI("epubcfi(/6/2!/4/4[p1]/1:5[x,y])"))
        #expect(CFI.comparePosition(a, withAssertion) == 0)
        #expect(a != withAssertion)
        #expect(a.withoutAssertions == withAssertion.withoutAssertions)
        #expect((a < withAssertion) != (withAssertion < a))
    }

    @Test func spineIndexVectors() async throws {
        let vectors = try CFIVectors.load()
        let container = try await EPUBContainer(url: Fixtures.url(vectors.epub))
        let publication = container.publication
        #expect(publication.spineElementIndex == 6)
        #expect(publication.cfiSpineSteps(forSpineIndex: 0) == [CFI.Step(index: 6), CFI.Step(index: 2, id: "c1")])
        #expect(publication.cfiSpineSteps(forSpineIndex: 1) == [CFI.Step(index: 6), CFI.Step(index: 4, id: "c2")])
        for vector in vectors.spineIndex {
            let cfi = try #require(CFI(vector.cfi))
            #expect(publication.spineIndex(of: cfi) == vector.spineIndex, Comment(rawValue: vector.cfi))
            #expect(cfi.spineIndex == (vector.derived ?? vector.spineIndex), Comment(rawValue: vector.cfi))
        }
        // Real books: the spine is the third child of <package>, itemref steps follow the spine position.
        let moby = try await EPUBContainer(url: Fixtures.mobyDick)
        #expect(moby.publication.spineElementIndex == 6)
        #expect(moby.publication.cfiSpineSteps(forSpineIndex: 6) == [CFI.Step(index: 6), CFI.Step(index: 14, id: "xchapter_001")])
        #expect(moby.publication.spineIndex(of: CFI("epubcfi(/6/14!/4/2/1:0)")!) == 6)
    }

    /// An itemref without a manifest item is skipped, so the step index of the following items is not
    /// `2 × (index + 1)`. A CFI into the skipped itemref must not be guessed onto another chapter.
    @Test func skippedItemrefDoesNotResolveToAnotherChapter() async throws {
        let data = MiniEPUB.build(
            withNav: true,
            extraManifest: #"<item id="c3" href="text/c3.xhtml" media-type="application/xhtml+xml"/>"#,
            extraSpine: #"<itemref idref="missing"/><itemref idref="c3"/>"#,
            extraFiles: [("OEBPS/text/c3.xhtml", Data(MiniEPUB.xhtml.utf8))]
        )
        let publication = try await EPUBContainer(data: data).publication
        #expect(publication.readingOrder.map(\.id) == ["c1", "c2", "c3"])
        #expect(publication.readingOrder[2].cfiStepIndex == 8)
        #expect(publication.spineIndex(of: try #require(CFI("epubcfi(/6/8!/4)"))) == 2)
        #expect(publication.spineIndex(of: try #require(CFI("epubcfi(/6/6!/4)"))) == nil)
        #expect(publication.spineIndex(of: try #require(CFI("epubcfi(/6/98!/4)"))) == nil)
    }

    @Test func textAssertionTakesTenUnitsOnEachSide() {
        let text = String(repeating: "a", count: 30) + "😀" + String(repeating: "b", count: 30)
        let assertion = CFIGenerator.textAssertion(in: text, offset: 30)
        #expect(assertion?.before == String(repeating: "a", count: 10))
        #expect(assertion?.after == "😀" + String(repeating: "b", count: 8))
        #expect(CFIGenerator.textAssertion(in: "abc", offset: 99)?.before == "abc")
        #expect(CFIGenerator.textAssertion(in: "abc", offset: -5)?.after == "abc")
        #expect(CFIGenerator.textAssertion(in: "", offset: 0) == nil)
    }

    @Test func resolvesAndGeneratesVectors() async throws {
        let vectors = try CFIVectors.load()
        let container = try await EPUBContainer(url: Fixtures.url(vectors.epub))
        let content = try await container.contentDocument(at: vectors.documentPath)
        #expect(content.state == .wellFormed)
        let document = try XMLDocument(data: content.data)
        let spineSteps = container.publication.cfiSpineSteps(forSpineIndex: 0)
        #expect(CFI.render(steps: spineSteps) == vectors.spineSteps)

        for vector in vectors.resolve {
            let cfi = try #require(CFI(vector.cfi), Comment(rawValue: vector.name))
            let resolution = CFIResolver.resolution(of: cfi, in: document)
            guard let generated = vector.generated else {
                #expect(resolution == nil, Comment(rawValue: vector.name))
                continue
            }
            let resolved = try #require(resolution, Comment(rawValue: vector.name))
            let node = document.node(at: resolved.location.path)
            if let text = vector.text {
                #expect(node?.text == text, Comment(rawValue: vector.name))
                #expect(resolved.location.offset == vector.offset, Comment(rawValue: vector.name))
            } else if let elementId = vector.elementId {
                #expect(node?.element?.id == elementId, Comment(rawValue: vector.name))
                #expect(resolved.location.offset == nil, Comment(rawValue: vector.name))
            }
            if let used = vector.usedTextAssertion {
                #expect(resolved.usedTextAssertion == used, Comment(rawValue: vector.name))
            }
            let regenerated = CFIGenerator.cfi(for: resolved.location, in: document, spineSteps: spineSteps)
            #expect(regenerated?.description == generated, Comment(rawValue: vector.name))
            // The generated CFI resolves to the same place.
            if let regenerated {
                #expect(CFIResolver.resolve(regenerated, in: document) == resolved.location, Comment(rawValue: vector.name))
            }
        }
    }

    @Test func codableIsASingleString() throws {
        struct Box: Codable, Equatable { var cfi: CFI; var range: CFIRange }
        let cfi = try #require(CFI("epubcfi(/6/2[c1]!/4/4[p1]/1:5[Call ,me Ishmael])"))
        let range = try #require(CFIRange("epubcfi(/6/2[c1]!/4/6[p2],/1:1,/5:3)"))
        let data = try JSONEncoder().encode(Box(cfi: cfi, range: range))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"cfi\":\"epubcfi(\\/6\\/2[c1]!\\/4\\/4[p1]\\/1:5[Call ,me Ishmael])\"") || json.contains("\"cfi\":\"epubcfi(/6/2[c1]!/4/4[p1]/1:5[Call ,me Ishmael])\""))
        #expect(try JSONDecoder().decode(Box.self, from: data) == Box(cfi: cfi, range: range))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Box.self, from: Data("{\"cfi\":\"nope\",\"range\":\"epubcfi(/6/2!/4)\"}".utf8)) }
    }

    @Test func rangeContainment() throws {
        let range = try #require(CFIRange("epubcfi(/6/2[c1]!/4,/4[p1]/1:5,/6[p2]/1:2)"))
        #expect(range.contains(CFI("epubcfi(/6/2!/4/4/1:5)")!))
        #expect(range.contains(CFI("epubcfi(/6/2!/4/4/1:40)")!))
        #expect(range.contains(CFI("epubcfi(/6/2!/4/6/1:1)")!))
        #expect(!range.contains(CFI("epubcfi(/6/2!/4/6/1:2)")!))
        #expect(!range.contains(CFI("epubcfi(/6/2!/4/4/1:4)")!))
        #expect(!range.contains(CFI("epubcfi(/6/4!/4/4/1:5)")!))
        #expect(!range.isCollapsed)
    }
}
