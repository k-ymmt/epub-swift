import Foundation
import Testing
@testable import EPUBCore

@Suite struct VerticalFixtureTests {
    @Test func opensKusamakura() async throws {
        let container = try await EPUBContainer(url: Fixtures.kusamakura)
        let pub = container.publication
        #expect(pub.metadata.title == "草枕")
        #expect(pub.metadata.authors == ["夏目 漱石"])
        #expect(pub.metadata.identifier == "http://www.aozora.gr.jp/cards/000148/card776.html")
        #expect(pub.pageProgression == .rtl)
        #expect(pub.readingOrder.count == 16)
        #expect(pub.readingOrder[1].isLinear == false) // 目次
        #expect(pub.linearReadingOrder.count == 15)
        #expect(pub.readingOrder[2].path == "OPS/xhtml/一.xhtml")
        #expect(pub.toc.count == 14)
        #expect(pub.toc.first?.label == "一")
        #expect(pub.toc.first?.spineIndex == 2)
        let unexpected = pub.warnings.filter {
            if case .missingResource(let path, _) = $0, path.hasPrefix("OPS/audio/") { return false }
            return true
        }
        #expect(unexpected.isEmpty, "\(unexpected)")
        let doc = try await container.contentDocument(at: "OPS/xhtml/一.xhtml")
        #expect(doc.state == .wellFormed)
    }
}
