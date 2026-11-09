import Foundation
import Testing
@testable import EPUBCore

@Suite struct NoteLookupTests {
    static let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>t</title></head>
        <body><p>Text<a epub:type="noteref" href="#n1">1</a>.</p>
        <aside id="n1" epub:type="footnote"><p>Note <b>one</b>.</p></aside>
        <p><a id="n2"/>2. Anchored note.</p></body></html>
        """

    @Test func elementCFIUsesTheSameStepsAsAnyOtherCFI() throws {
        let document = try XMLDocument(data: Data(Self.xhtml.utf8))
        let steps = [CFI.Step(index: 6), CFI.Step(index: 4, id: "c1")]
        let cfi = try #require(CFIGenerator.cfi(forElementWithID: "n1", in: document, spineSteps: steps))
        #expect(cfi.description == "epubcfi(/6/4[c1]!/4/4[n1])")
        #expect(CFIGenerator.cfi(forElementWithID: "missing", in: document, spineSteps: steps) == nil)
    }

    @Test func noteOfAnInlineAnchorIsTheEnclosingBlock() throws {
        let document = try XMLDocument(data: Data(Self.xhtml.utf8))
        let aside = try #require(document.notePath(forElementWithID: "n1"))
        #expect(document.element(at: aside)?.name == "aside")
        let anchored = try #require(document.notePath(forElementWithID: "n2"))
        let block = try #require(document.element(at: anchored))
        #expect(block.name == "p")
        #expect(block.textContent.contains("Anchored note"))
    }
}
