import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Every page of a chapter, the last ones included, scrolls to a whole multiple of the page size (M5: WebKit ended the
/// scroll area one margin before the last page boundary, so the last pages showed shifted by one margin).
@Suite(.serialized) @MainActor struct PageAlignmentTests {
    private func checkEveryPage(_ host: SessionHost, vertical: Bool, pageSize: Double) async throws {
        let count = host.session.chapterPageCount
        #expect(count > 3, "the chapter needs more pages than the three slots")
        for page in 0..<count {
            await host.session.go(toPageInChapter: page)
            #expect(host.session.currentPageIndex == page)
            let offset = try #require(try await host.js(vertical ? "return document.scrollingElement.scrollTop" : "return document.scrollingElement.scrollLeft") as? Double)
            #expect(offset.truncatingRemainder(dividingBy: pageSize) == 0, "page \(page) of \(count): offset \(offset)")
        }
    }

    @Test func horizontalPagesStayAlignedToTheChapterEnd() async throws {
        let host = try await SessionHost(url: LinksNotesImagesTests.sample, size: CGSize(width: 402, height: 700))
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 1)
        try await checkEveryPage(host, vertical: false, pageSize: 402)
        // Arriving backwards from the next chapter lands on the last page, aligned.
        await host.session.go(toSpineIndex: 2)
        await host.session.goBackward()
        #expect(host.session.currentSpineIndex == 1)
        let offset = try #require(try await host.js("return document.scrollingElement.scrollLeft") as? Double)
        #expect(offset.truncatingRemainder(dividingBy: 402) == 0)
    }

    @Test func verticalPagesStayAlignedToTheChapterEnd() async throws {
        let host = try await SessionHost(url: VerticalWritingTests.kusamakura, size: CGSize(width: 400, height: 600))
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 3)
        try await checkEveryPage(host, vertical: true, pageSize: 600)
    }
}
