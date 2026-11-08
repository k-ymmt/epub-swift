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
        webView.frame = CGRect(x: -CGFloat(visibleSlot) * size.width, y: 0, width: size.width * CGFloat(Self.slotCount), height: size.height)
    }

    private func alignSlot(_ slot: Int) {
        visibleSlot = max(0, min(Self.slotCount - 1, slot))
        webView.frame.origin.x = -CGFloat(visibleSlot) * pageSize.width
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

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
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
        return GoToPageResult(pageIndex: pageIndex, slot: slot, pageCount: pageCount)
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

    private static func layoutResult(from result: Any?) throws -> LayoutResult {
        guard let dict = result as? [String: Any], let pageCount = dict["pageCount"] as? Int else {
            throw ReaderError.scriptFailed("layout returned \(String(describing: result))")
        }
        return LayoutResult(pageCount: max(1, pageCount), writingMode: dict["writingMode"] as? String ?? "horizontal-tb")
    }

    // MARK: - Snapshots

    func snapshot(slot: Int) async throws -> (image: CGImage, scale: CGFloat)? {
        guard pageSize.width > 0, pageSize.height > 0, !webView.isHidden else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: CGFloat(slot) * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
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
        onNavigationFailed?(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
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
