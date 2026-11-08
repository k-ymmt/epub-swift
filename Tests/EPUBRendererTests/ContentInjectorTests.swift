import Foundation
import Testing
import EPUBCore
@testable import EPUBRenderer

@Suite struct ContentInjectorTests {
    let injection = ContentInjector.Injection(
        beforeStylesheetURL: "epub://id/_reader/css/reader-before.css",
        afterStylesheetURL: "epub://id/_reader/css/reader-after.css",
        rootStyle: ":root { --reader-page-width: 300px; }",
        injectViewport: true
    )

    @Test func injectsIntoExistingHead() throws {
        let source = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title><link rel="stylesheet" href="pub.css"/></head><body><p>x</p></body></html>
        """
        let (data, hadViewport) = ContentInjector.inject(Data(source.utf8), isXML: true, injection: injection)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!hadViewport)
        let before = try #require(text.range(of: "reader-before.css"))
        let viewport = try #require(text.range(of: "name=\"viewport\""))
        let publisher = try #require(text.range(of: "pub.css"))
        let after = try #require(text.range(of: "reader-after.css"))
        let style = try #require(text.range(of: "__reader_settings"))
        let headClose = try #require(text.range(of: "</head>"))
        #expect(before.lowerBound < viewport.lowerBound)
        #expect(viewport.lowerBound < publisher.lowerBound)
        #expect(publisher.lowerBound < after.lowerBound)
        #expect(after.lowerBound < style.lowerBound)
        #expect(style.lowerBound < headClose.lowerBound)
        #expect(XMLDocument.isWellFormed(data))
    }

    @Test func createsHeadWhenMissingAndSkipsHeaderElement() throws {
        let source = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><header>h</header></body></html>"
        let (data, _) = ContentInjector.inject(Data(source.utf8), isXML: true, injection: injection)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><link"))
        #expect(XMLDocument.isWellFormed(data))
    }

    @Test func keepsExistingViewportMeta() {
        let source = "<html><head><meta name=\"viewport\" content=\"width=600, height=800\"/></head><body/></html>"
        let (data, hadViewport) = ContentInjector.inject(Data(source.utf8), isXML: true, injection: injection)
        #expect(hadViewport)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.components(separatedBy: "name=\"viewport\"").count == 2)
    }

    @Test func headTagWithAttributesIsRecognized() throws {
        let source = "<HTML><HEAD lang=\"en\"><TITLE>x</TITLE></HEAD><BODY/></HTML>"
        let (data, _) = ContentInjector.inject(Data(source.utf8), isXML: false, injection: injection)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("<HEAD lang=\"en\"><link rel=\"stylesheet\""))
    }

    @Test func rootStyleReflectsSettings() {
        var settings = ReaderSettings()
        settings.fontScale = 1.25
        settings.theme = .dark
        settings.font = .system(name: "Avenir")
        let css = ContentInjector.rootStyle(settings: settings, pageSize: CGSize(width: 390, height: 700), publicationID: PublicationID())
        #expect(css.contains("--reader-page-width: 390px"))
        #expect(css.contains("--reader-font-size: 1.25"))
        #expect(css.contains("--reader-font-family: \"Avenir\""))
        #expect(css.contains("color-scheme: dark"))
        #expect(css.contains(settings.theme.background.cssString))
    }
}
