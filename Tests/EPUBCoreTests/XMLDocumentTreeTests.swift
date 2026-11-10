import Foundation
import Testing
@testable import EPUBCore

/// `XMLDocument.Tree`: the rendered tree matches WebKit's DOM with content JavaScript disabled (no XHTML / SVG
/// `script` elements, no `template` children); the source tree keeps everything (docs/design/06-annotations.md §12.1).
@Suite struct XMLDocumentTreeTests {
    static let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:x="urn:x"><head><title>t</title><script>var h;</script></head>
        <body><p id="a">One <script>var a;</script>two <span>three</span></p><svg xmlns="http://www.w3.org/2000/svg"><script>var s;</script><rect id="r"/></svg><x:script>foreign</x:script><SCRIPT>upper</SCRIPT><template id="t"><p>inside</p></template><p id="b">x<script src="q.js"/>y</p></body></html>
        """

    static func names(_ element: EPUBCore.XMLElement) -> [String] { element.childElements.map(\.name) }

    @Test func renderedTreeDropsScriptsAndTemplateContent() throws {
        let document = try EPUBCore.XMLDocument(data: Data(Self.xhtml.utf8))
        let head = try #require(document.root.firstChild(named: "head"))
        let body = try #require(document.root.firstChild(named: "body"))
        #expect(Self.names(head) == ["title"])
        // XML is case-sensitive and other namespaces are other elements: `SCRIPT` and `x:script` stay, as in WebKit.
        #expect(Self.names(body) == ["p", "svg", "script", "SCRIPT", "template", "p"])
        #expect(body.childElements[2].namespaceURI == "urn:x")
        let a = body.childElements[0]
        // The text around the removed script is one text node, the logical text node `reader.js` sees.
        #expect(a.children.first == .text("One two "))
        #expect(Self.names(body.childElements[1]) == ["rect"])
        #expect(body.childElements[4].children.isEmpty)
        #expect(body.childElements[5].children == [.text("xy")])
        #expect(document.path(ofElementWithID: "r") != nil)
    }

    @Test func sourceTreeKeepsEverything() throws {
        let document = try EPUBCore.XMLDocument(data: Data(Self.xhtml.utf8), tree: .source)
        let head = try #require(document.root.firstChild(named: "head"))
        let body = try #require(document.root.firstChild(named: "body"))
        #expect(Self.names(head) == ["title", "script"])
        #expect(Self.names(body) == ["p", "svg", "script", "SCRIPT", "template", "p"])
        #expect(Self.names(body.childElements[0]) == ["script", "span"])
        #expect(Self.names(body.childElements[1]) == ["script", "rect"])
        #expect(Self.names(body.childElements[4]) == ["p"])
        #expect(body.childElements[0].textContent == "One var a;two three")
    }
}
