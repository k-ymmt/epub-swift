import Foundation
import Testing
@testable import EPUBCore

@Suite struct TextMapTests {
    @Test func mapsOffsetsBackToNodesAndInsertsBlockBreaks() throws {
        let xml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>T</title></head><body>
        <p id="a">Hello <b>bold</b> world</p><p id="b"><ruby>漢<rt>かん</rt></ruby>字</p>
        </body></html>
        """
        let document = try XMLDocument(data: Data(xml.utf8))
        let map = TextMap(document: document)
        #expect(map.text == "\nHello bold world\n漢字\n\n")
        #expect(map.collapsedCharacterCount == TextLength.characterCount(of: document))
        // "bold" starts at offset 7 and lives in the <b> text node.
        let bold = try #require(map.location(ofUTF16Offset: 7))
        #expect(document.node(at: bold.path)?.text == "bold")
        #expect(bold.offset == 0)
        #expect(map.utf16Offset(of: bold) == 7)
        // An offset inside an inserted newline maps to the end of the preceding node.
        let afterWorld = try #require(map.location(ofUTF16Offset: 17))
        #expect(document.node(at: afterWorld.path)?.text == " world")
        #expect(afterWorld.offset == 6)
        // The ruby annotation is not part of the text.
        let kanji = try #require(map.location(ofUTF16Offset: 18))
        #expect(document.node(at: kanji.path)?.text == "漢")
    }
}

@Suite struct SearchServiceTests {
    @Test func findsMatchesWithCFIRangesAndSnippets() async throws {
        let container = try await EPUBContainer(url: Fixtures.url("cfi-sample.epub"))
        let service = SearchService(container: container)
        var results: [SearchResult] = []
        for try await result in service.search("call me") {
            results.append(result)
        }
        // c1: "Call me Ishmael"; c2: full-width "Ｃａｌｌ ｍｅ" and "CALL ME".
        #expect(results.count == 3)
        #expect(results.map(\.spineIndex) == [0, 1, 1])
        let first = try #require(results.first)
        #expect(first.range.start.description == "epubcfi(/6/2[c1]!/4[body]/4[p1]/1:0[,Call me Is])")
        #expect(first.range.end.description == "epubcfi(/6/2[c1]!/4[body]/4[p1]/1:7[Call me, Ishmael. ])")
        #expect(first.matchedText == "Call me")
        #expect(first.snippet.hasPrefix("Call me Ishmael."))
        #expect(!first.snippet.contains("\n"))
        #expect(String(first.snippet[first.matchRangeInSnippet]) == "Call me")
        #expect(results[1].matchedText == "Ｃａｌｌ ｍｅ")
        #expect(results[2].matchedText == "CALL ME")
        #expect(results[2].snippet.hasPrefix("Résumé café"))

        // Options: exact width and case.
        let strict = SearchOptions(caseInsensitive: false, diacriticInsensitive: false, widthInsensitive: false)
        var strictResults: [SearchResult] = []
        for try await result in service.search("Call me", options: strict) { strictResults.append(result) }
        #expect(strictResults.count == 1)
        var diacritics: [SearchResult] = []
        for try await result in service.search("resume cafe") { diacritics.append(result) }
        #expect(diacritics.count == 1)
        #expect(diacritics.first?.matchedText == "Résumé café")

        // A match that spans two text nodes gets a range across them.
        var spanning: [SearchResult] = []
        for try await result in service.search("first emphasised and") { spanning.append(result) }
        #expect(spanning.count == 1)
        #expect(spanning.first?.range.start.description.hasPrefix("epubcfi(/6/2[c1]!/4[body]/6[p2]/1:0") == true)
        #expect(spanning.first?.range.end.description.hasPrefix("epubcfi(/6/2[c1]!/4[body]/6[p2]/3:4") == true)
    }

    @Test func searchesVerticalJapaneseTextWidthInsensitively() async throws {
        let container = try await EPUBContainer(url: Fixtures.kusamakura)
        let service = SearchService(container: container)
        var results: [SearchResult] = []
        for try await result in service.search("山路を登りながら") {
            results.append(result)
            if results.count >= 1 { break }
        }
        #expect(results.count >= 1)
        let first = try #require(results.first)
        #expect(first.spineIndex == 2)
        #expect(first.snippet.contains("山路を登りながら"))
        #expect(CFIResolver.resolve(first.range.start, in: try #require(await service.document(forSpineIndex: 2))) != nil)
    }

    @Test func prepareBuildsMapsAhead() async throws {
        let container = try await EPUBContainer(url: Fixtures.url("cfi-sample.epub"))
        let service = SearchService(container: container)
        await service.prepare()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await service.textMap(forSpineIndex: 1)?.text.contains("Second chapter") == true)
        #expect(await service.textMap(forSpineIndex: 99) == nil)
    }
}
