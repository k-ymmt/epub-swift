import Foundation
import Testing
@testable import EPUBCore

@Suite struct EPUBContainerTests {
    @Test func opensMobyDick() async throws {
        let container = try await EPUBContainer(url: Fixtures.mobyDick)
        let pub = container.publication
        #expect(pub.metadata.title == "Moby-Dick")
        #expect(pub.metadata.authors == ["Herman Melville"])
        #expect(pub.metadata.language == "en-US")
        #expect(pub.metadata.identifier == "code.google.com.epub-samples.moby-dick-basic")
        #expect(pub.metadata.publisher == "Harper & Brothers, Publishers")
        #expect(pub.metadata.modified != nil)
        #expect(pub.packageDocumentPath == "OPS/package.opf")
        #expect(pub.navigationDocumentPath == "OPS/toc.xhtml")
        #expect(pub.coverImagePath == "OPS/images/9780316000000.jpg")
        #expect(pub.layout == .reflowable)
        #expect(pub.pageProgression == .default)

        // cover, titlepage, brief-toc, preface, introduction, epigraph, 136 chapters, copyright, toc
        #expect(pub.readingOrder.count == 144)
        #expect(pub.readingOrder.first?.isLinear == false)
        #expect(pub.readingOrder.last?.isLinear == false)
        #expect(pub.readingOrder[6].path == "OPS/chapter_001.xhtml")
        #expect(pub.linearReadingOrder.count == 142)
        #expect(pub.spineIndex(ofPath: "OPS/chapter_001.xhtml") == 6)

        #expect(pub.toc.count > 100)
        #expect(pub.toc.first?.label == "Moby-Dick")
        #expect(pub.toc.first?.spineIndex == 1)
        let chapter1 = try #require(pub.toc.first { $0.label.hasPrefix("Chapter 1.") })
        #expect(chapter1.href == "OPS/chapter_001.xhtml")
        #expect(chapter1.spineIndex == 6)
        #expect(!pub.warnings.contains(.missingNavigation))
        #expect(!pub.warnings.contains(.missingMimetype))

        let cover = try await container.coverImageData()
        #expect((cover?.count ?? 0) > 100_000)
        let css = try await container.data(at: "OPS/css/stylesheet.css")
        #expect(String(decoding: css, as: UTF8.self).contains("@font-face"))
        #expect(container.mediaType(forPath: "OPS/fonts/STIXGeneral.otf") == "application/vnd.ms-opentype")
    }

    @Test func opensChildrensLiteratureWithNestedTOCAndPageList() async throws {
        let container = try await EPUBContainer(url: Fixtures.childrensLiterature)
        let pub = container.publication
        #expect(pub.metadata.title == "Children's Literature")
        #expect(pub.metadata.alternativeTitles == ["A Textbook of Sources for Teachers and Teacher-Training Classes"])
        #expect(pub.metadata.authors == ["Charles Madison Curry", "Erle Elsworth Clippinger"])
        #expect(pub.metadata.rawMetadata["dc:subject"]?.count == 2)
        #expect(pub.readingOrder.map(\.path) == ["EPUB/cover.xhtml", "EPUB/nav.xhtml", "EPUB/s04.xhtml"])
        #expect(pub.manifestItem(withID: "ncx")?.mediaType == "application/x-dtbncx+xml")

        #expect(pub.toc.count == 1)
        let section = try #require(pub.toc.first)
        #expect(section.label.hasPrefix("SECTION IV"))
        #expect(section.href == "EPUB/s04.xhtml")
        #expect(section.fragment == "pgepubid00492")
        #expect(section.spineIndex == 2)
        #expect(section.depth >= 4)
        let author = try #require(section.children.first { $0.label == "Abram S. Isaacs" })
        #expect(author.href == nil)
        #expect(author.children.first?.label.hasSuffix("A FOUR-LEAVED CLOVER") == true)

        #expect(!pub.pageList.isEmpty)
        #expect(pub.pageList.first?.fragment != nil)
        #expect(pub.landmarks.count == 2)
        #expect(pub.landmarks.last?.label == "Begin Reading")
    }

    @Test func fallsBackToASpineTOCWithoutNav() async throws {
        let container = try await EPUBContainer(data: MiniEPUB.build(withNav: false))
        let pub = container.publication
        #expect(pub.warnings.contains(.missingNavigation))
        #expect(pub.toc.map(\.label) == ["c1.xhtml"]) // linear items only
        #expect(pub.toc.first?.spineIndex == 0)
        #expect(pub.pageProgression == .rtl)
        #expect(pub.metadata.identifier == "urn:uuid:12345678-1234-1234-1234-123456789abc")
        #expect(pub.readingOrder[1].isLinear == false)
    }

    @Test func parsesNavAndResolvesFragments() async throws {
        let container = try await EPUBContainer(data: MiniEPUB.build(withNav: true, zip64: true))
        let pub = container.publication
        #expect(!pub.warnings.contains(.missingNavigation))
        #expect(pub.toc.count == 1)
        #expect(pub.toc[0].children.first?.href == "OEBPS/text/c2.xhtml")
        #expect(pub.toc[0].children.first?.fragment == "p1")
        #expect(pub.toc[0].children.first?.spineIndex == 1)
        let doc = try await container.contentDocument(at: "OEBPS/text/c1.xhtml")
        #expect(doc.state == .wellFormed)
        #expect(doc.mediaType == "application/xhtml+xml")
    }

    @Test func warnsAboutMissingResourcesAndBadItemrefs() async throws {
        let data = MiniEPUB.build(
            withNav: true,
            extraManifest: #"<item id="missing" href="images/none.png" media-type="image/png"/>"#,
            extraSpine: #"<itemref idref="ghost"/>"#
        )
        let container = try await EPUBContainer(data: data)
        let warnings = container.publication.warnings
        #expect(warnings.contains(.missingResource(path: "OEBPS/images/none.png", referencedFrom: "OEBPS/content.opf")))
        #expect(warnings.contains(.missingResource(path: "ghost", referencedFrom: "OEBPS/content.opf")))
        #expect(container.publication.readingOrder.count == 2)
    }

    @Test func throwsWhenContainerXMLIsMissing() async {
        var w = TestZIPWriter()
        w.add("mimetype", "application/epub+zip")
        w.add("a.txt", "x")
        let data = w.build()
        await #expect(throws: EPUBError.self) { try await EPUBContainer(data: data) }
    }

    @Test func throwsForMissingResources() async throws {
        let container = try await EPUBContainer(url: Fixtures.mobyDick)
        await #expect(throws: EPUBError.self) { try await container.data(at: "OPS/nope.xhtml") }
    }
}

@Suite struct ContainerPathTests {
    @Test func resolvesRelativeHrefs() {
        #expect(ContainerPath.resolve(href: "chapter_001.xhtml", relativeTo: "OPS/package.opf") == "OPS/chapter_001.xhtml")
        #expect(ContainerPath.resolve(href: "../images/a%20b.png#frag", relativeTo: "OPS/text/c.xhtml") == "OPS/images/a b.png")
        #expect(ContainerPath.resolve(href: "/abs.xhtml", relativeTo: "OPS/x.opf") == "abs.xhtml")
        #expect(ContainerPath.resolve(href: "http://example.com/a.png", relativeTo: "OPS/x.opf") == nil)
        #expect(ContainerPath.resolve(href: "#only", relativeTo: "OPS/x.xhtml") == "OPS/x.xhtml")
        #expect(ContainerPath.splitFragment("a.xhtml#x").fragment == "x")
        #expect(ContainerPath.splitFragment("a.xhtml").fragment == nil)
        #expect(ContainerPath.percentEncoded("OPS/a b/c#d.xhtml") == "OPS/a%20b/c%23d.xhtml")
    }
}
