import Foundation
import Testing
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// Fixed-layout pages through the spread wrapper (M4, docs/design/02-rendering.md §6).
@Suite(.serialized) @MainActor struct FixedLayoutSpreadTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let haruko = fixtures.appendingPathComponent("haruko-html-jpeg.epub")
    static let pageBlanche = fixtures.appendingPathComponent("page-blanche.epub")
    static let cole = fixtures.appendingPathComponent("cole-voyage-of-life.epub")

    struct FrameInfo {
        var spineIndex: Int
        var placement: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var scale: Double
        var hidden: Bool
        var hasBridge: Bool
    }

    static func frames(_ host: SessionHost) async throws -> [FrameInfo] {
        let raw = try await host.js("return window.__epubReader.frameInfo ? window.__epubReader.frameInfo() : []") as? [[String: Any]] ?? []
        return raw.map {
            FrameInfo(
                spineIndex: $0["spineIndex"] as? Int ?? -1, placement: $0["placement"] as? String ?? "",
                x: $0["x"] as? Double ?? 0, y: $0["y"] as? Double ?? 0, width: $0["width"] as? Double ?? 0, height: $0["height"] as? Double ?? 0,
                scale: $0["scale"] as? Double ?? 0, hidden: $0["hidden"] as? Bool ?? false, hasBridge: $0["hasBridge"] as? Bool ?? false
            )
        }
    }

    @Test func harukoShowsSpreadsInLandscapeAndSinglePagesInPortrait() async throws {
        let host = try await SessionHost(url: Self.haruko, size: CGSize(width: 800, height: 600))
        await host.session.loadIfNeeded()
        let session = host.session
        #expect(session.hasLoaded)
        #expect(session.isRightToLeft)
        // p01 is page-spread-left and stands alone on the left half of a two-page face.
        #expect(session.currentSpineIndex == 0)
        #expect(session.visibleSpineIndices == [0])
        #expect(session.isShowingSpread)
        #expect(session.chapterPageCount == 1)
        var frames = try await Self.frames(host)
        #expect(frames.count == 1)
        #expect(frames[0].placement == "l")
        #expect(frames[0].hasBridge)
        // 600×837 page in a 400×600 half: scale = min(400/600, 600/837) = 0.667 (the width is the limit).
        #expect(abs(frames[0].scale - 400.0 / 600.0) < 0.001)
        #expect(abs(frames[0].x + 600 * frames[0].scale - 400) < 0.5)   // against the center line
        #expect(frames[0].width == 600 && frames[0].height == 837)
        let position = try #require(session.position)
        #expect(position.spineIndex == 0)

        await session.goForward()
        #expect(session.visibleSpineIndices == [1, 2])
        #expect(session.currentSpineIndex == 1)
        #expect(session.isShowingSpread)
        frames = try await Self.frames(host)
        #expect(frames.count == 2)
        // rtl: the first page of the pair (p02, page-spread-right) sits on the right.
        let right = try #require(frames.first { $0.spineIndex == 1 })
        let left = try #require(frames.first { $0.spineIndex == 2 })
        #expect(right.placement == "r" && left.placement == "l")
        #expect(abs(right.scale - 800.0 / 1200.0) < 0.001 && right.scale == left.scale)
        #expect(abs(left.x + 600 * left.scale - right.x) < 0.5)
        #expect(abs((left.x + right.x + 600 * right.scale) / 2 - 400) < 0.5) // centered
        #expect(session.position?.spineIndex == 1)
        // Both pages count one book page each.
        #expect(session.pagination.chapter(spineIndex: 1)?.pageCount == 1)
        #expect(session.pagination.chapter(spineIndex: 2)?.pageCount == 1)
        #expect(session.pagination.isEstimated(spineIndex: 2) == false)

        await session.goBackward()
        #expect(session.visibleSpineIndices == [0])
        // The last fixed page (p12, right) has no fixed partner: alone on the right; then the reflowable About page.
        await session.go(toSpineIndex: 11)
        #expect(session.visibleSpineIndices == [11])
        frames = try await Self.frames(host)
        #expect(frames.count == 1 && frames[0].placement == "r")
        #expect(abs(frames[0].x - 400) < 0.5)
        await session.goForward()
        #expect(session.visibleSpineIndices == [12])
        #expect(!session.isShowingSpread || session.chapterPageCount >= 1)
        await session.go(toPageInChapter: session.chapterPageCount - 1)
        #expect(session.isAtEnd)
        await session.go(toPageInChapter: 0)
        await session.goBackward()
        #expect(session.visibleSpineIndices == [11])

        // Portrait: rendition:spread landscape → single pages filling the face.
        host.session.viewportSize = CGSize(width: 400, height: 600)
        #if os(macOS)
        host.window.setContentSize(CGSize(width: 400, height: 600))
        #endif
        try await host.waitUntil { !host.session.isLoading && host.session.viewportSize.width == 400 }
        #expect(!session.isShowingSpread)
        #expect(session.visibleSpineIndices == [11])
        frames = try await Self.frames(host)
        #expect(frames.count == 1 && frames[0].placement == "f")
        #expect(abs(frames[0].scale - 400.0 / 600.0) < 0.001)
        await session.goBackward()
        #expect(session.visibleSpineIndices == [10])
    }

    @Test func pageBlancheKeepsTheCoverOnTheRightAndRestoresPositionAcrossResize() async throws {
        let host = try await SessionHost(url: Self.pageBlanche, size: CGSize(width: 900, height: 600))
        await host.session.loadIfNeeded()
        let session = host.session
        #expect(session.visibleSpineIndices == [0])
        var frames = try await Self.frames(host)
        #expect(frames.count == 1 && frames[0].placement == "r" && abs(frames[0].x - 450) < 0.5)
        await session.goForward()
        #expect(session.visibleSpineIndices == [1, 2])
        frames = try await Self.frames(host)
        #expect(frames.first { $0.spineIndex == 1 }?.placement == "l")
        #expect(frames.first { $0.spineIndex == 2 }?.placement == "r")
        // A CFI into the right-hand page of the spread stays on this face.
        let page2 = CFI(spineSteps: session.publication.cfiSpineSteps(forSpineIndex: 2), steps: [CFI.Step(index: 4)])
        await session.go(to: page2)
        #expect(session.visibleSpineIndices == [1, 2])
        // Going to the right-hand page by spine index does not reload the face.
        await session.go(toSpineIndex: 2)
        #expect(session.visibleSpineIndices == [1, 2])
        let position = try #require(session.position)

        // Portrait: single pages; the position (page 2) is kept.
        await session.go(toSpineIndex: 2)
        host.session.viewportSize = CGSize(width: 400, height: 600)
        #if os(macOS)
        host.window.setContentSize(CGSize(width: 400, height: 600))
        #endif
        try await host.waitUntil { !host.session.isLoading && host.session.viewportSize.width == 400 }
        #expect(!session.isShowingSpread)
        #expect(session.visibleSpineIndices == [position.spineIndex])
        // Back to landscape: the spread that holds the page comes back.
        host.session.viewportSize = CGSize(width: 900, height: 600)
        #if os(macOS)
        host.window.setContentSize(CGSize(width: 900, height: 600))
        #endif
        try await host.waitUntil { !host.session.isLoading && host.session.viewportSize.width == 900 }
        #expect(session.visibleSpineIndices == [1, 2])
        // Snapshot of the whole face.
        let snapshot = await session.pageSnapshot(.current)
        #expect(snapshot != nil)
        #expect(snapshot?.size == CGSize(width: 900, height: 600))
    }

    @Test func coleShowsPaintingsAsSingleFullPagesBetweenReflowableText() async throws {
        let host = try await SessionHost(url: Self.cole, size: CGSize(width: 900, height: 600))
        await host.session.loadIfNeeded()
        let session = host.session
        #expect(session.visibleSpineIndices == [0])
        #expect(session.isShowingSpread) // reflowable text as two pages (policy auto, landscape)
        await session.go(toSpineIndex: 2) // s1b: the painting, rendition:spread none
        #expect(session.visibleSpineIndices == [2])
        #expect(!session.isShowingSpread)
        #expect(session.chapterPageCount == 1)
        let frames = try await Self.frames(host)
        #expect(frames.count == 1 && frames[0].placement == "f")
        // 1024×697 in 900×600: the height limits (600/697 ≈ 0.861 vs 900/1024 ≈ 0.879).
        #expect(abs(frames[0].scale - 600.0 / 697.0) < 0.001)
        #expect(abs(frames[0].y) < 0.5)
        #expect(session.position?.spineIndex == 2)
        await session.goForward()
        #expect(session.visibleSpineIndices == [3])
        #expect(session.chapterPageCount >= 1)
        await session.goBackward()
        #expect(session.visibleSpineIndices == [2])
    }

    @Test func fixedLayoutDocumentsGetOnlyTheFixedStylesheet() async throws {
        let host = try await SessionHost(url: Self.haruko, size: CGSize(width: 800, height: 600))
        await host.session.loadIfNeeded()
        let links = try await host.js("""
            const f = document.querySelector('iframe'); const d = f.contentDocument;
            return Array.from(d.querySelectorAll('link[rel=stylesheet]')).map(l => l.getAttribute('href').split('/').pop());
        """) as? [String] ?? []
        #expect(links.contains("reader-fixed.css"))
        #expect(!links.contains("reader-before.css"))
        #expect(!links.contains("reader-after.css"))
        let viewport = try await host.js("return document.querySelector('iframe').contentDocument.querySelector('meta[name=viewport]').getAttribute('content')") as? String
        #expect(viewport == "width=600, height=837")
        let columns = try await host.js("return getComputedStyle(document.querySelector('iframe').contentDocument.documentElement).columnWidth") as? String
        #expect(columns == "auto")
    }
}

/// Pinch zoom on fixed-layout faces (M4, 02-rendering §6.3). macOS: `allowsMagnification` / `magnification`.
@Suite(.serialized) @MainActor struct FixedLayoutZoomTests {
    @Test func zoomIsEnabledForFixedLayoutFacesOnlyAndResetsOnNavigation() async throws {
        let host = try await SessionHost(url: FixedLayoutSpreadTests.cole, size: CGSize(width: 900, height: 600))
        await host.session.loadIfNeeded()
        let session = host.session
        #expect(!session.isZoomed)
        #if os(macOS)
        #expect(host.renderer.webView.allowsMagnification == false) // reflowable text
        #endif
        await session.go(toSpineIndex: 2) // painting
        var events: [Bool] = []
        let stream = session.events
        let collector = Task { @MainActor in
            for await event in stream { if case .zoomChanged(let zoomed) = event { events.append(zoomed) } }
        }
        #if os(macOS)
        #expect(host.renderer.webView.allowsMagnification == true)
        host.renderer.webView.magnification = 2
        #expect(session.isZoomed)
        host.renderer.webView.magnification = 1
        #expect(!session.isZoomed)
        host.renderer.webView.magnification = 1.5
        #expect(session.isZoomed)
        session.resetZoom()
        #expect(!session.isZoomed)
        #expect(host.renderer.webView.magnification == 1)
        host.renderer.webView.magnification = 2
        #expect(session.isZoomed)
        // Loading another face resets the zoom; a reflowable face cannot zoom.
        await session.goForward()
        #expect(!session.isZoomed)
        #expect(host.renderer.webView.magnification == 1)
        #expect(host.renderer.webView.allowsMagnification == false)
        try await host.waitUntil { events == [true, false, true, false, true, false] }
        #endif
        collector.cancel()
    }
}
