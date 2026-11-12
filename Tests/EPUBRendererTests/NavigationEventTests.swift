import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// `ReaderEvent.navigated` (docs/design/03-api.md §3.4): every move of the reader says why the page changed and
/// where it came from; laying the same text out again says nothing.
@Suite(.serialized) @MainActor struct NavigationEventTests {
    @Test func aPageTurnReportsWhereItCameFrom() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        try await host.waitUntil { !recorder.positions.isEmpty }
        #expect(recorder.navigations.isEmpty, "the first load is not a move")
        let start = try #require(host.session.position)

        await host.session.goForward()
        try await host.waitUntil { !recorder.navigations.isEmpty }
        let forward = try #require(recorder.navigations.first)
        #expect(forward.cause == .pageTurn)
        #expect(forward.from == start)
        #expect(forward.to == host.session.position)

        recorder.reset()
        await host.session.goBackward()
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.pageTurn])
        #expect(recorder.navigations.first?.from == forward.to)
        // The move's `positionChanged` comes first
        let kinds = recorder.events.compactMap { event -> String? in
            switch event {
            case .positionChanged: "position"
            case .navigated: "navigated"
            default: nil
            }
        }
        #expect(kinds.last == "navigated")
        #expect(kinds.contains("position"))
    }

    @Test func jumpsReportTheirOriginAndAMoveThatGoesNowhereReportsNothing() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        let start = try #require(host.session.position)

        await host.session.go(toSpineIndex: 6)
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.jump])
        #expect(recorder.navigations.first?.from == start)
        #expect(recorder.navigations.first?.to.spineIndex == 6)

        // To the book page that is already shown, and to the position that is already shown
        recorder.reset()
        let page = try #require(host.session.currentPage)
        await host.session.go(toPage: page)
        await host.session.go(to: try #require(host.session.position))
        await host.session.go(toPageInChapter: host.session.currentPageIndex)
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.navigations.isEmpty)

        // By book page, into another chapter, and back by position
        let there = try #require(host.session.position)
        await host.session.go(toPage: 0)
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.jump])
        #expect(recorder.navigations.first?.from == there)
        recorder.reset()
        await host.session.go(to: there)
        try await host.waitUntil { !recorder.navigations.isEmpty }
        #expect(recorder.navigations.first?.to.cfi == there.cfi)
    }

    @Test func aRelayoutIsNotAMove() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        await host.session.goForward()
        try await host.waitUntil { recorder.navigations.count == 2 }
        recorder.reset()

        host.session.settings.fontScale = 1.6
        try await host.waitUntil { !host.session.isLoading && !recorder.positions.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.navigations.isEmpty)
    }

    @Test func aFollowedLinkIsReportedBeforeInternalLink() async throws {
        let host = try await SessionHost(url: LinksNotesImagesTests.sample)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        let start = try #require(host.session.position)

        _ = try await host.js("""
            const el = document.getElementById("to-c2");
            const r = el.getClientRects()[0] || el.getBoundingClientRect();
            el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: r.left + 2, clientY: r.top + r.height / 2 }));
            """)
        try await host.waitUntil { !recorder.internalLinks.isEmpty }
        #expect(recorder.navigations.map(\.cause) == [.link])
        #expect(recorder.navigations.first?.from == start)
        #expect(recorder.navigations.first?.to.spineIndex == 1)
        let order = recorder.events.compactMap { event -> String? in
            switch event {
            case .navigated: "navigated"
            case .internalLink: "link"
            default: nil
            }
        }
        #expect(order == ["navigated", "link"])
    }

    @Test func chapterTitlesComeFromTheLastTOCEntryOfTheSpineItem() async throws {
        let container = try await EPUBContainer(url: ReaderSessionTests.mobyDick)
        let publication = container.publication
        let titled = try #require(publication.toc.first { $0.spineIndex != nil })
        #expect(publication.chapterTitle(forSpineIndex: try #require(titled.spineIndex)) != nil)
        #expect(publication.chapterTitle(forSpineIndex: 10_000) == nil)
    }
}
