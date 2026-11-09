import Foundation
import Testing
@testable import EPUBCore

@Suite struct XHTMLRepairTests {
    static let malformedNames = ["unclosed-and-entities", "single-missing-close", "html5-elements-and-svg"]

    @Test func wellFormedDocumentsAreServedUntouched() {
        let data = Data(MiniEPUB.xhtml.utf8)
        let doc = XHTMLRepair.prepare(data, path: "a.xhtml")
        #expect(doc.state == .wellFormed)
        #expect(doc.data == data)
        #expect(doc.mediaType == "application/xhtml+xml")
        #expect(doc.warnings.isEmpty)
    }

    @Test func wellFormedUTF16IsTranscodedToUTF8() throws {
        let source = MiniEPUB.xhtml.replacingOccurrences(of: "encoding=\"UTF-8\"", with: "encoding=\"UTF-16\"")
            .replacingOccurrences(of: "Hello", with: "こんにちは")
        for encoding in [String.Encoding.utf16BigEndian, .utf16LittleEndian] {
            let bom: [UInt8] = encoding == .utf16BigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
            let encoded = try #require(source.data(using: encoding))
            let data = Data(bom) + encoded
            let doc = XHTMLRepair.prepare(data, path: "u16.xhtml")
            #expect(doc.state == .wellFormed)
            let text = try #require(String(data: doc.data, encoding: .utf8))
            #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
            #expect(!text.contains("UTF-16"))
            let tree = try XMLDocument(data: doc.data)
            #expect(tree.root.textContent.contains("こんにちは"))
        }
    }

    @Test func utf16TranscodingKeepsAStylesheetInstruction() throws {
        let source = #"<?xml-stylesheet type="text/css" href="book.css"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body><p>x</p></body></html>"#
        let encoded = try #require(source.data(using: .utf16BigEndian))
        let doc = XHTMLRepair.prepare(Data([0xFE, 0xFF]) + encoded, path: "s.xhtml")
        #expect(doc.state == .wellFormed)
        let text = try #require(String(data: doc.data, encoding: .utf8))
        #expect(text.contains("<?xml-stylesheet type=\"text/css\" href=\"book.css\"?>"))
        #expect(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
    }

    @Test(arguments: malformedNames)
    func repairedDocumentsAreWellFormedXML(name: String) throws {
        let data = try Fixtures.malformed(name)
        #expect(!XMLDocument.isWellFormed(data))
        let doc = XHTMLRepair.prepare(data, path: "\(name).xhtml")
        #expect(doc.state == .repaired, "\(name)")
        #expect(doc.mediaType == "application/xhtml+xml")
        #expect(doc.warnings == [.malformedXHTML(path: "\(name).xhtml")])
        let tree = try XMLDocument(data: doc.data)
        #expect(tree.root.name == "html")
        #expect(tree.root.namespaceURI == XMLNamespace.xhtml)
        #expect(tree.root.firstChild(named: "body") != nil)
    }

    @Test func repairKeepsContentAndIDs() throws {
        let doc = XHTMLRepair.prepare(try Fixtures.malformed("single-missing-close"), path: "s.xhtml")
        let tree = try XMLDocument(data: doc.data)
        let body = try #require(tree.root.firstChild(named: "body"))
        let div = try #require(body.firstChild(named: "div"))
        #expect(div.id == "c1")
        #expect(div.childElements.map(\.name) == ["h2", "p", "p", "p"])
        #expect(div.childElements[1].textContent == "Alpha beta gamma.")
        #expect(tree.root.textContent.contains("Theta link."))
    }

    @Test func entitiesAndTablesSurviveRepair() throws {
        let doc = XHTMLRepair.prepare(try Fixtures.malformed("unclosed-and-entities"), path: "u.xhtml")
        let tree = try XMLDocument(data: doc.data)
        let text = tree.root.textContent
        #expect(text.contains("Title\u{00A0}with nbsp"))
        #expect(text.contains("©"))
        // libxml2's HTML parser does not insert tbody (05-spike-results §2.5); the table is still there.
        let table = try #require(tree.root.firstDescendant { $0.name == "table" })
        #expect(table.firstDescendant { $0.name == "td" }?.textContent == "cell")
        #expect(tree.root.firstDescendant { $0.name == "ruby" } != nil)
    }

    @Test func declaresNamespacesForPrefixedAttributesAndFixesSVGCase() throws {
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>svg</title></head>
        <body>
        <section epub:type="chapter" id="s">
        <p>Broken <b>bold <i>both</b> italic</i>
        <svg width="100" height="50" viewBox="0 0 100 50" preserveAspectRatio="xMidYMid">
          <defs><linearGradient id="g"><stop offset="0"/></linearGradient><clipPath id="c"/></defs>
          <foreignObject width="10" height="10"><div xmlns="http://www.w3.org/1999/xhtml">x</div></foreignObject>
          <use xlink:href="#g"/>
        </svg>
        <unknownns:thing data-x="1">kept</unknownns:thing>
        </section>
        </body></html>
        """
        let doc = XHTMLRepair.prepare(Data(source.utf8), path: "svg.xhtml")
        #expect(doc.state == .repaired)
        let tree = try XMLDocument(data: doc.data)
        let section = try #require(tree.root.firstDescendant { $0.name == "section" })
        #expect(section.attribute("type", namespace: XMLNamespace.epub) == "chapter")
        let svg = try #require(tree.root.firstDescendant { $0.name == "svg" })
        #expect(svg.namespaceURI == XMLNamespace.svg)
        #expect(svg.attribute("viewBox") == "0 0 100 50")
        #expect(svg.attribute("preserveAspectRatio") == "xMidYMid")
        #expect(svg.firstDescendant { $0.name == "linearGradient" } != nil)
        #expect(svg.firstDescendant { $0.name == "clipPath" } != nil)
        #expect(svg.firstDescendant { $0.name == "foreignObject" } != nil)
        let use = try #require(svg.firstDescendant { $0.name == "use" })
        #expect(use.attribute("href", namespace: XMLNamespace.xlink) == "#g")
        // Unknown prefix stripped so the document stays namespace-well-formed.
        #expect(tree.root.firstDescendant { $0.name == "thing" }?.textContent == "kept")
    }

    @Test func addsMissingXHTMLNamespaceAndSVGNamespace() throws {
        let source = "<html><head><title>t</title></head><body><p>a<svg><rect/></svg></body></html>"
        let doc = XHTMLRepair.prepare(Data(source.utf8), path: "n.xhtml")
        #expect(doc.state == .repaired)
        let tree = try XMLDocument(data: doc.data)
        #expect(tree.root.namespaceURI == XMLNamespace.xhtml)
        #expect(tree.root.firstDescendant { $0.name == "svg" }?.namespaceURI == XMLNamespace.svg)
    }

    @Test func givesUpOnDocumentsThatAreNotHTML() {
        // Not even recoverable text/html: no root element at all.
        let doc = XHTMLRepair.prepare(Data(), path: "empty.xhtml")
        #expect(doc.state == .unrepairable)
        #expect(doc.mediaType == "text/html")
    }
}

@Suite struct XMLDocumentTests {
    @Test func mergesAdjacentTextAndFoldsComments() throws {
        let source = "<r xmlns:e=\"urn:e\" e:a=\"1\">a<!-- c -->b<![CDATA[<c>]]><x/>  </r>"
        let doc = try XMLDocument(data: Data(source.utf8))
        #expect(doc.root.children.count == 3)
        #expect(doc.root.children[0].text == "ab<c>")
        #expect(doc.root.children[1].element?.name == "x")
        #expect(doc.root.children[2].text == "  ")
        #expect(doc.root.attribute("a", namespace: "urn:e") == "1")
    }

    @Test func reportsErrors() {
        #expect(throws: XMLParseError.self) { try XMLDocument(data: Data("<a><b></a>".utf8)) }
    }
}
