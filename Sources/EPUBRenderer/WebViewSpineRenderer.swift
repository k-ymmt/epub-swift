import Foundation
import WebKit
import EPUBCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// WKWebView-backed `SpineRenderer` (docs/design/02-rendering.md §1).
///
/// The web view is three pages wide and sits inside a clipping view one page wide. `goToPage` scrolls so that
/// the target page lands in one of the three slots; the web view is then offset so that slot is the visible one.
/// Snapshots of the neighbouring slots give the images for page-turn effects without scrolling.
@MainActor
final class WebViewSpineRenderer: NSObject, SpineRenderer {
    static let readerWorld = WKContentWorld.world(name: "reader")
    static let slotCount = 3

    let clipView: PlatformView
    let webView: WKWebView
    let schemeHandler: EPUBSchemeHandler
    var view: PlatformView { clipView }

    var onMessage: (@MainActor (BridgeMessage) -> Void)?
    var onNavigationFailed: (@MainActor (Error) -> Void)?
    var onProcessTerminated: (@MainActor () -> Void)?

    private(set) var pageSize: CGSize = .zero
    private(set) var writingMode: WritingMode = .horizontalTB
    private(set) var visibleSlot: Int = 0
    private let messageBridge = MessageBridge()

    init(schemeHandler: EPUBSchemeHandler) {
        self.schemeHandler = schemeHandler
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: EPUBSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = true
        #if canImport(UIKit)
        configuration.dataDetectorTypes = []
        #endif
        let controller = WKUserContentController()
        if let scriptURL = Bundle.module.url(forResource: "reader", withExtension: "js", subdirectory: "Reader") ?? Bundle.module.url(forResource: "reader", withExtension: "js"),
           let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.readerWorld))
        }
        configuration.userContentController = controller

        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 300 * 3, height: 400), configuration: configuration)
        #if canImport(AppKit)
        clipView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        #else
        clipView = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        clipView.clipsToBounds = true
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        clipView.addSubview(webView)
        webView.navigationDelegate = self
        messageBridge.owner = self
        controller.addScriptMessageHandler(messageBridge, contentWorld: Self.readerWorld, name: "reader")
    }

    // MARK: - Geometry

    func setPageSize(_ size: CGSize) {
        guard size != pageSize, size.width > 0, size.height > 0 else { return }
        pageSize = size
        clipView.frame = CGRect(origin: clipView.frame.origin, size: size)
        layoutWebViewFrame()
    }

    func setWritingMode(_ mode: WritingMode) {
        guard mode != writingMode else { return }
        writingMode = mode
        layoutWebViewFrame()
    }

    /// Three slots along the paging axis; the visible slot is pulled into the clip view (02-rendering §1.2).
    private func layoutWebViewFrame() {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        if writingMode.isVertical {
            webView.frame = CGRect(x: 0, y: -CGFloat(visibleSlot) * pageSize.height, width: pageSize.width, height: pageSize.height * CGFloat(Self.slotCount))
        } else {
            webView.frame = CGRect(x: -CGFloat(visibleSlot) * pageSize.width, y: 0, width: pageSize.width * CGFloat(Self.slotCount), height: pageSize.height)
        }
    }

    private func alignSlot(_ slot: Int) {
        visibleSlot = max(0, min(Self.slotCount - 1, slot))
        layoutWebViewFrame()
    }

    /// Frame rectangle (in the web view's coordinates) of the page in `slot`.
    func slotRect(_ slot: Int) -> CGRect {
        if writingMode.isVertical {
            return CGRect(x: 0, y: CGFloat(slot) * pageSize.height, width: pageSize.width, height: pageSize.height)
        }
        return CGRect(x: CGFloat(slot) * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
    }

    func setBackgroundColor(_ color: ReaderColor) {
        #if canImport(AppKit)
        clipView.layer?.backgroundColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        webView.underPageBackgroundColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #else
        clipView.backgroundColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        webView.underPageBackgroundColor = clipView.backgroundColor
        #endif
    }

    func setContentHidden(_ hidden: Bool) {
        webView.isHidden = hidden
    }

    // MARK: - Loading

    private var loadCounter = 0

    @discardableResult
    func load(_ url: URL) -> URL {
        loadCounter += 1
        // The query does not change the container path the scheme handler resolves (`url.path`) nor how relative
        // URLs in the document resolve; it only makes this document's location.href unique so a late `ready` from
        // an earlier load of the same chapter can be recognised and ignored. A fragment would not do: changing
        // only the fragment of the current URL is a same-document navigation and the reader script does not run again.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "__reader_load", value: String(loadCounter))]
        let tagged = components?.url ?? url
        webView.load(URLRequest(url: tagged))
        return tagged
    }

    // MARK: - Bridge calls

    private func call(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.readerWorld)
    }

    func layout(_ parameters: LayoutParameters) async throws -> LayoutResult {
        let result = try await call("return window.__epubReader.layout(params)", arguments: ["params": parameters.dictionary])
        return try Self.layoutResult(from: result)
    }

    func applySettings(_ parameters: LayoutParameters) async throws -> LayoutResult {
        let result = try await call("return window.__epubReader.applySettings(params)", arguments: ["params": parameters.dictionary])
        return try Self.layoutResult(from: result)
    }

    func goToPage(_ index: Int) async throws -> GoToPageResult {
        let result = try await call("return window.__epubReader.goToPage(index)", arguments: ["index": index])
        guard let dict = result as? [String: Any],
              let pageIndex = dict["pageIndex"] as? Int,
              let slot = dict["slot"] as? Int,
              let pageCount = dict["pageCount"] as? Int else {
            throw ReaderError.scriptFailed("goToPage returned \(String(describing: result))")
        }
        alignSlot(slot)
        let offset = CGPoint(x: (dict["scrollLeft"] as? Double) ?? 0, y: (dict["scrollTop"] as? Double) ?? 0)
        syncNativeScroll(to: offset)
        return GoToPageResult(pageIndex: pageIndex, slot: slot, pageCount: pageCount, scrollOffset: offset)
    }

    /// On iOS the document's scroll position is applied by the UI process asynchronously; during rapid page turns
    /// while the document is still growing (late images) the request can be clamped against a stale content size
    /// and the scroll view ends up behind the page the document reports. Setting the offset natively keeps them equal.
    private func syncNativeScroll(to offset: CGPoint) {
        #if canImport(UIKit)
        let scrollView = webView.scrollView
        let current = scrollView.contentOffset
        guard abs(current.x - offset.x) > 0.5 || abs(current.y - offset.y) > 0.5 else { return }
        scrollView.setContentOffset(offset, animated: false)
        #endif
    }

    func captureAnchor(slot: Int, margins: PageMargins) async throws -> Bool {
        let result = try await call(
            "return window.__epubReader.captureAnchor(slot, margins)",
            arguments: ["slot": slot, "margins": ["horizontal": margins.horizontal, "vertical": margins.vertical]]
        )
        return (result as? Bool) ?? false
    }

    func pageForAnchor() async throws -> Int? {
        let result = try await call("return window.__epubReader.pageForAnchor()")
        return result as? Int
    }

    func pageForFragment(_ fragment: String) async throws -> Int? {
        let result = try await call("return window.__epubReader.pageForFragment(fragment)", arguments: ["fragment": fragment])
        return result as? Int
    }

    // MARK: - Positions, highlights, selection (02-rendering §4.1)

    func cfiForPage(_ index: Int, margins: PageMargins) async throws -> CFI? {
        let result = try await call(
            "return window.__epubReader.cfiForPage(index, margins)",
            arguments: ["index": index, "margins": ["horizontal": margins.horizontal, "vertical": margins.vertical]]
        )
        return (result as? String).flatMap(CFI.init)
    }

    func pageFor(_ cfi: CFI) async throws -> Int? {
        let result = try await call("return window.__epubReader.pageFor(cfi)", arguments: ["cfi": cfi.description])
        return result as? Int
    }

    func rects(for range: CFIRange) async throws -> [CGRect] {
        let result = try await call("return window.__epubReader.rectsFor(cfiRange)", arguments: ["cfiRange": range.description])
        return BridgeMessage.rects(from: result)
    }

    func setHighlights(_ highlights: [Highlight]) async throws -> [String] {
        let list: [[String: Any]] = highlights.map { highlight in
            let style: String
            switch highlight.style {
            case .background: style = "background"
            case .underline: style = "underline"
            }
            return ["id": highlight.id.uuidString, "cfiRange": highlight.range.description, "color": highlight.style.color.cssString, "style": style]
        }
        let result = try await call("return window.__epubReader.setHighlights(list)", arguments: ["list": list])
        return (result as? [String]) ?? []
    }

    func setTransientHighlight(_ range: CFIRange?) async throws {
        _ = try await call("return window.__epubReader.setTransientHighlight(cfiRange)", arguments: ["cfiRange": range?.description as Any? ?? NSNull()])
    }

    func currentSelection() async throws -> BridgeSelection? {
        let result = try await call("return window.__epubReader.currentSelection()")
        return BridgeSelection(result)
    }

    func clearSelection() async throws {
        _ = try await call("return window.__epubReader.clearSelection()")
    }

    private static func layoutResult(from result: Any?) throws -> LayoutResult {
        guard let dict = result as? [String: Any], let pageCount = dict["pageCount"] as? Int else {
            throw ReaderError.scriptFailed("layout returned \(String(describing: result))")
        }
        return LayoutResult(pageCount: max(1, pageCount), writingMode: WritingMode(cssValue: dict["writingMode"] as? String ?? "horizontal-tb"))
    }

    // MARK: - Snapshots

    func snapshot(slot: Int) async throws -> (image: CGImage, scale: CGFloat)? {
        guard pageSize.width > 0, pageSize.height > 0, !webView.isHidden else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = slotRect(slot)
        configuration.snapshotWidth = NSNumber(value: Double(pageSize.width))
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        #if canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cgImage = image.cgImage else { return nil }
        #endif
        return (cgImage, CGFloat(cgImage.width) / pageSize.width)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewSpineRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Only loads the session starts are allowed; links are handled through the bridge (02-rendering §4.2).
        if navigationAction.navigationType == .other, navigationAction.targetFrame?.isMainFrame ?? true,
           navigationAction.request.url?.scheme == EPUBSchemeHandler.scheme {
            decisionHandler(.allow)
        } else if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        reportNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        reportNavigationFailure(error)
    }

    /// A load that was superseded by a newer `load(_:)` fails with "cancelled" / "frame load interrupted". That is
    /// not a failure of the newer load, whose `ready` is being awaited, so it is not reported.
    private func reportNavigationFailure(_ error: any Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return } // WebKitErrorFrameLoadInterruptedByPolicyChange
        onNavigationFailed?(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onProcessTerminated?()
    }
}

/// Separate object so the user content controller does not retain the renderer.
@MainActor
private final class MessageBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: WebViewSpineRenderer?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        if let parsed = BridgeMessage(body: message.body) {
            owner?.onMessage?(parsed)
        }
        replyHandler(true, nil)
    }
}
