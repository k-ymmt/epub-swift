import Foundation
import Testing
import WebKit
import EPUBCore
@_spi(EPUBUI) @testable import EPUBRenderer

/// WebContent process termination and memory warnings (M5, docs/design/02-rendering.md §8.4 / §9).
@Suite(.serialized) @MainActor struct RecoveryTests {
    /// Crashes the web view's WebContent process for real: SIGKILL to the process WebKit reports through the private
    /// `_webProcessIdentifier` (a crash, unlike the client-requested `_killWebContentProcess`, after which WebKit
    /// calls the navigation delegate and relaunches the process with the next load). Falls back to delivering the
    /// delegate callback when the identifier is not available. Returns whether a process was killed.
    @discardableResult
    static func crashWebContent(of renderer: WebViewSpineRenderer) -> Bool {
        if let pid = renderer.webView.value(forKey: "_webProcessIdentifier") as? Int32, pid > 0, kill(pid, SIGKILL) == 0 {
            return true
        }
        renderer.webViewWebContentProcessDidTerminate(renderer.webView)
        return false
    }

    @Test func displayCrashReloadsTheChapterAtTheSamePosition() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 6)
        await host.session.go(toPageInChapter: 3)
        let before = try #require(host.session.position)
        let page = host.session.currentPageIndex

        let crashed = Self.crashWebContent(of: host.renderer)
        try await host.waitUntil {
            recorder.events.contains { if case .error(.webContentTerminated) = $0 { true } else { false } }
        }
        // The chapter comes back at the page that holds the same text (a position is published after the reload).
        // No script call before that: a killed process only comes back with the next load.
        try await host.waitUntil(timeout: .seconds(15)) {
            guard let crash = recorder.events.lastIndex(where: { if case .error(.webContentTerminated) = $0 { true } else { false } }) else { return false }
            return recorder.events[crash...].contains { if case .positionChanged = $0 { true } else { false } } && !host.session.isLoading
        }
        #expect((try await host.js("return document.readyState")) as? String == "complete")
        #expect(host.session.position?.cfi == before.cfi)
        #expect(host.session.currentSpineIndex == 6)
        #expect(host.session.currentPageIndex == page)
        #expect(!host.renderer.isContentHidden)
        let errors = recorder.events.filter { if case .error = $0 { true } else { false } }
        #expect(errors.count == 1, "one webContentTerminated, nothing else (real crash: \(crashed))")
        // Navigation keeps working afterwards.
        await host.session.goForward()
        #expect(host.session.currentPageIndex == page + 1)
    }

    @Test func crashWhileAChapterLoadsRetriesThatLoad() async throws {
        let host = try await SessionHost(url: ReaderSessionTests.mobyDick)
        let recorder = EventRecorder(host.session)
        await host.session.loadIfNeeded()
        // Start loading chapter 8 and crash before its `ready`.
        let navigation = Task { await host.session.go(toSpineIndex: 8) }
        try await host.waitUntil { host.session.isLoading }
        Self.crashWebContent(of: host.renderer)
        await navigation.value
        try await host.waitUntil(timeout: .seconds(15)) { host.session.currentSpineIndex == 8 && !host.session.isLoading }
        #expect(recorder.events.contains { if case .error(.webContentTerminated) = $0 { true } else { false } })
        #expect(!recorder.events.contains { if case .error(.loadFailed) = $0 { true } else { false } })
        #expect(!recorder.events.contains { if case .error(.loadTimeout) = $0 { true } else { false } })
    }

    @Test func prePaginationSurvivesACrashOfItsHiddenWebView() async throws {
        let host = try await SessionHost(url: VerticalWritingTests.kusamakura)
        await host.session.loadIfNeeded()
        let service = host.session.paginationService
        try await host.waitUntil { service.isWorking }
        Self.crashWebContent(of: service.renderer)
        try await host.waitUntil(timeout: .seconds(60)) { !host.session.pagination.isEstimated }
        #expect(service.failedSpineIndices.isEmpty)
        #expect(host.session.pagination.chapters.count == 15)
    }

    @Test func memoryWarningPausesAndALayoutChangeResumes() async throws {
        let host = try await SessionHost(url: VerticalWritingTests.kusamakura)
        await host.session.loadIfNeeded()
        await host.session.go(toSpineIndex: 2)
        let service = host.session.paginationService
        try await host.waitUntil(timeout: .seconds(30)) { service.snapshot(firstPageOf: 3) != nil }

        host.session.didReceiveMemoryWarning()
        #expect(service.isPaused)
        #expect(!service.isWorking)
        #expect(service.snapshots.isEmpty)

        // A settings change configures the service for a new layout: that ends the pause (TODO.md M2).
        host.session.settings.fontScale = 1.3
        try await host.waitUntil { !host.session.isLoading }
        #expect(!service.isPaused)
        try await host.waitUntil(timeout: .seconds(60)) { !host.session.pagination.isEstimated }
        try await host.waitUntil(timeout: .seconds(30)) { service.snapshot(firstPageOf: 3) != nil }
    }
}
