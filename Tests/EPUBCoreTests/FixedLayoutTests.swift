import Foundation
import Testing
@testable import EPUBCore

/// Rendition properties and the fixed-layout viewport (M4).
@Suite struct FixedLayoutTests {
    @Test func parsesViewportMetaContent() {
        #expect(FixedLayoutViewport(metaContent: "width=1024,height=697") == FixedLayoutViewport(width: 1024, height: 697))
        #expect(FixedLayoutViewport(metaContent: "width=600, height=837") == FixedLayoutViewport(width: 600, height: 837))
        #expect(FixedLayoutViewport(metaContent: "height=100px; width=200px") == FixedLayoutViewport(width: 200, height: 100))
        #expect(FixedLayoutViewport(metaContent: "width=device-width, initial-scale=1") == nil)
        #expect(FixedLayoutViewport(metaContent: "width=0,height=10") == nil)
        #expect(FixedLayoutViewport(metaContent: "width=10") == nil)
    }

    @Test func readsViewportFromDocumentHead() throws {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title>
        <meta name="Viewport" content="width=1200, height=1577"/></head>
        <body><meta name="viewport" content="width=1,height=1"/></body></html>
        """
        let prepared = XHTMLRepair.prepareAndParse(Data(xhtml.utf8), path: "a.xhtml")
        let tree = try #require(prepared.tree)
        #expect(FixedLayoutViewport(document: tree) == FixedLayoutViewport(width: 1200, height: 1577))
        let none = XHTMLRepair.prepareAndParse(Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head/><body/></html>".utf8), path: "b.xhtml")
        #expect(FixedLayoutViewport(document: try #require(none.tree)) == nil)
    }

    @Test func harukoIsFixedLayoutRightToLeftWithAlternatingSides() async throws {
        let container = try await EPUBContainer(url: Fixtures.haruko)
        let pub = container.publication
        #expect(pub.layout == .prePaginated)
        #expect(pub.spread == .landscape)
        #expect(pub.orientation == .portrait)
        #expect(pub.pageProgression == .rtl)
        #expect(pub.readingOrder.count == 13)
        let pages = pub.readingOrder.prefix(12)
        #expect(pages.allSatisfy { $0.isFixedLayout })
        #expect(pages.allSatisfy { $0.viewport == FixedLayoutViewport(width: 600, height: 837) })
        #expect(pages.map(\.spreadPosition) == Array(repeating: [SpreadPosition.left, .right], count: 6).flatMap { $0 })
        let about = try #require(pub.readingOrder.last)
        #expect(about.layout == .reflowable)
        #expect(about.spreadPosition == .left)
        #expect(!pub.warnings.contains { if case .missingViewport = $0 { return true } else { return false } })
    }

    @Test func coleMixesReflowableTextAndSpreadNonePaintings() async throws {
        let container = try await EPUBContainer(url: Fixtures.coleVoyageOfLife)
        let pub = container.publication
        #expect(pub.layout == .reflowable)
        #expect(pub.spread == .auto)
        #expect(pub.pageProgression == .default)
        let paintings = pub.readingOrder.filter(\.isFixedLayout)
        #expect(paintings.count == 4)
        #expect(paintings.allSatisfy { $0.spread == RenditionSpread.none })
        #expect(paintings.allSatisfy { $0.orientation == .landscape })
        #expect(paintings.allSatisfy { $0.spreadPosition == nil })
        #expect(paintings.first?.viewport == FixedLayoutViewport(width: 1024, height: 697))
        let text = pub.readingOrder.filter { !$0.isFixedLayout }
        #expect(text.allSatisfy { $0.spread == nil && $0.orientation == nil })
        #expect(!pub.warnings.contains { if case .missingViewport = $0 { return true } else { return false } })
    }

    @Test func pageBlancheDeclaresSidesForEveryPage() async throws {
        let container = try await EPUBContainer(url: Fixtures.pageBlanche)
        let pub = container.publication
        #expect(pub.layout == .prePaginated)
        #expect(pub.spread == .auto)
        // The spine has no page-progression-direction attribute.
        #expect(pub.pageProgression == .default)
        #expect(pub.readingOrder.count == 10)
        #expect(pub.readingOrder.first?.spreadPosition == .right)
        #expect(pub.readingOrder[1].spreadPosition == .left)
        #expect(pub.readingOrder.allSatisfy { $0.viewport == FixedLayoutViewport(width: 1200, height: 1577) })
        #expect(pub.readingOrder.allSatisfy { $0.spreadPosition != nil })
    }

    @Test func warnsWhenAFixedLayoutDocumentHasNoViewport() async throws {
        let data = MiniEPUB.build(
            withNav: true,
            extraMetadata: #"<meta property="rendition:layout">pre-paginated</meta><meta property="rendition:spread">both</meta><meta property="rendition:orientation">landscape</meta>"#,
            spineItemProperties: ["rendition:spread-none rendition:orientation-portrait page-spread-right", "rendition:page-spread-center"]
        )
        let container = try await EPUBContainer(data: data)
        let pub = container.publication
        #expect(pub.layout == .prePaginated)
        #expect(pub.spread == .both)
        #expect(pub.orientation == .landscape)
        #expect(pub.readingOrder[0].spread == RenditionSpread.none)
        #expect(pub.readingOrder[0].orientation == .portrait)
        #expect(pub.readingOrder[0].spreadPosition == .right)
        #expect(pub.readingOrder[1].spread == nil)
        #expect(pub.readingOrder[1].spreadPosition == .center)
        #expect(pub.readingOrder.allSatisfy { $0.viewport == nil })
        #expect(pub.warnings.contains(.missingViewport(path: pub.readingOrder[0].path)))
        #expect(pub.warnings.contains(.missingViewport(path: pub.readingOrder[1].path)))
    }
}
