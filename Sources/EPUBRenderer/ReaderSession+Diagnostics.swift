import Foundation
import WebKit

/// What ReaderDemo's recording mode needs from a session (docs/design/08-continuous-scroll.md §13): the web view, to
/// read its scroll view and take pictures of it while somebody scrolls, and the scroll controller's own account of
/// what it did. Not API: an app has no use for these, and they change with the implementation.
@_spi(Diagnostics) extension ReaderSession {
    /// The web view that shows the book.
    public var diagnosticsWebView: WKWebView? {
        (renderer as? WebViewSpineRenderer)?.webView
    }

    /// Turns the scroll controller's log on or off: chapters added, loaded and removed, heights, the corrections
    /// taken out of the runway (`shift`) and the scroll positions written at rest (`correct`). False outside the
    /// scrolled layout.
    @discardableResult
    public func setScrollLogging(_ isOn: Bool) async -> Bool {
        (try? await evaluateScrollDiagnostics("return d.setLogging(\(isOn))")) as? Bool ?? false
    }

    /// The controller's clock (`now`, the `t` of the log's events), its state and the log since the last call, as
    /// JSON: `{"now": ms, "state": {…}, "events": [{"ev": "shift", "t": ms, "scrollY": px, …}]}`. Nil outside the
    /// scrolled layout.
    public func scrollDiagnostics() async -> Data? {
        let json = (try? await evaluateScrollDiagnostics("return JSON.stringify({ now: d.now(), state: d.state(), events: d.drainLog() })")) as? String
        return json.map { Data($0.utf8) }
    }

    /// The document's scroll position as the page sees it, and whether the reader's hands are on it. For the
    /// platform without a scroll view to ask (macOS).
    public func scrollSample() async -> (scrollY: Double, isInteracting: Bool)? {
        guard let value = (try? await evaluateScrollDiagnostics("return [window.scrollY, d.state().interacting ? 1 : 0]")) as? [Double], value.count == 2 else { return nil }
        return (value[0], value[1] != 0)
    }

    private func evaluateScrollDiagnostics(_ body: String) async throws -> Any? {
        guard layout == .scrolled, let webView = diagnosticsWebView else { return nil }
        let script = "const d = window.__epubReader && window.__epubReader.debug; if (!d) { return null; }\n" + body
        return try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: WebViewSpineRenderer.readerWorld)
    }
}
