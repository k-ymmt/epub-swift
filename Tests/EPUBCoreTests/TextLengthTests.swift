import Foundation
import Testing
@testable import EPUBCore

@Suite struct TextLengthTests {
    @Test func collapsesWhitespaceAndSkipsRubyAnnotations() throws {
        let xml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>ignored title</title><style>p { color: red }</style></head>
        <body>
          <p>  Hello,\n   world  </p>
          <p><ruby>山路<rt>やまみち</rt><rp>(</rp></ruby>を登る</p>
          <script>var x = 1;</script>
        </body></html>
        """
        let document = try XMLDocument(data: Data(xml.utf8))
        // "Hello, world" (12) + 1 collapsed space between the paragraphs + "山路を登る" (5)
        #expect(TextLength.characterCount(of: document) == 18)
    }

    @Test func spineItemsCarryCharacterCountsAfterOpening() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let moby = try await EPUBContainer(url: Fixtures.mobyDick)
        let elapsed = clock.now - start
        let chapter1 = moby.publication.readingOrder[6]
        #expect((chapter1.characterCount ?? 0) > 10_000, "chapter 1 has \(String(describing: chapter1.characterCount)) characters")
        #expect(moby.publication.readingOrder.allSatisfy { $0.characterCount != nil })
        let total = moby.publication.linearReadingOrder.compactMap(\.characterCount).reduce(0, +)
        #expect(total > 1_000_000) // Moby-Dick is about 1.2 million characters
        #expect(elapsed < .seconds(2), "opening moby-dick took \(elapsed)")

        let kusamakura = try await EPUBContainer(url: Fixtures.kusamakura)
        let first = kusamakura.publication.readingOrder[2]
        #expect((first.characterCount ?? 0) > 5_000)
        #expect((first.characterCount ?? 0) < 20_000)
    }
}
