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
    let webView: ReaderWebView
    /// Covers the web view (background colour) while a document loads, instead of hiding the web view: a hidden view
    /// leaves the accessibility tree and VoiceOver focus would jump elsewhere at every chapter change (02-rendering
    /// §7.3, M5). The curtain itself is not an accessibility element.
    let curtain: PlatformView
    /// `true` while the curtain is up (set by `setContentHidden`).
    private(set) var isContentHidden = false
    let schemeHandler: EPUBSchemeHandler
    var view: PlatformView { clipView }

    var onMessage: (@MainActor (BridgeMessage) -> Void)?
    var onNavigationFailed: (@MainActor (Error) -> Void)?
    var onProcessTerminated: (@MainActor () -> Void)?
    var onZoomChanged: (@MainActor (Bool) -> Void)?
    private(set) var isZoomEnabled = false
    private(set) var isZoomed = false
    #if canImport(UIKit)
    private var zoomObservation: NSKeyValueObservation?
    #endif
    var selectionMenuSource: SelectionMenuSource? {
        get { webView.selectionMenuSource }
        set { webView.selectionMenuSource = newValue }
    }

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
        // scroll-core.js first: reader.js's scroll controller uses it. Both also run in the iframes of a wrapper (M4,
        // 08-continuous-scroll); a framed document does not talk to Swift directly.
        for name in ["scroll-core", "reader"] {
            if let scriptURL = Self.readerScriptURL(named: name), let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
                controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.readerWorld))
            }
        }
        configuration.userContentController = controller

        webView = ReaderWebView(frame: CGRect(x: 0, y: 0, width: 300 * 3, height: 400), configuration: configuration)
        #if canImport(AppKit)
        curtain = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        curtain.wantsLayer = true
        curtain.autoresizingMask = [.width, .height]
        curtain.setAccessibilityElement(false)
        curtain.isHidden = true
        #else
        curtain = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        curtain.isAccessibilityElement = false
        curtain.accessibilityElementsHidden = true
        curtain.isHidden = true
        #endif
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
        clipView.addSubview(curtain)
        webView.navigationDelegate = self
        messageBridge.owner = self
        controller.addScriptMessageHandler(messageBridge, contentWorld: Self.readerWorld, name: "reader")
        #if canImport(UIKit)
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        // WKWebView's scroll view does not post KVO for `zoomScale` while pinching (its zoom runs through WebKit's
        // own viewport code), so the pinch recognizer itself is the signal; the KVO covers programmatic changes.
        // The recognizer is nil until WebKit makes the view zoomable, so it is picked up in `syncPinchRecognizer`.
        zoomObservation = webView.scrollView.observe(\.zoomScale, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.zoomScaleDidChange(scrollView.zoomScale) }
        }
        #else
        webView.onMagnificationChanged = { [weak self] magnification in self?.zoomScaleDidChange(magnification) }
        #endif
    }

    /// The bundled script `name`.js (`reader`, `scroll-core`).
    nonisolated static func readerScriptURL(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Reader") ?? Bundle.module.url(forResource: name, withExtension: "js")
    }

    // MARK: - Zoom (fixed layout, 02-rendering §6.3)

    func setZoomEnabled(_ enabled: Bool) {
        guard enabled != isZoomEnabled else { return }
        isZoomEnabled = enabled
        if !enabled { resetZoom() }
        #if canImport(UIKit)
        syncPinchRecognizer()
        #else
        webView.allowsMagnification = enabled
        #endif
    }

    #if canImport(UIKit)
    private var pinchTargetInstalled = false

    /// WebKit owns the scroll view's zoom range (it resets `minimumZoomScale` / `maximumZoomScale` from the viewport meta
    /// on every layout) and creates the pinch recognizer lazily, so the recognizer is (re)configured after each
    /// document load and whenever the zoom permission changes.
    private func syncPinchRecognizer() {
        guard let pinch = webView.scrollView.pinchGestureRecognizer else { return }
        if !pinchTargetInstalled {
            pinch.addTarget(self, action: #selector(pinchDidChange(_:)))
            pinchTargetInstalled = true
        }
        pinch.isEnabled = isZoomEnabled
    }
    #endif

    func resetZoom() {
        #if canImport(UIKit)
        if webView.scrollView.zoomScale != 1 { webView.scrollView.setZoomScale(1, animated: false) }
        if !isScrollMode { webView.scrollView.isScrollEnabled = false }
        #else
        if webView.magnification != 1 { webView.magnification = 1 }
        #endif
        zoomScaleDidChange(1)
    }

    #if canImport(UIKit)
    @objc private func pinchDidChange(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .changed:
            zoomScaleDidChange(webView.scrollView.zoomScale)
        case .ended, .cancelled, .failed:
            // The scroll view may still be bouncing back to a scale within [min, max]; read the settled value too.
            zoomScaleDidChange(webView.scrollView.zoomScale)
            let scrollView = webView.scrollView
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated { self?.zoomScaleDidChange(scrollView.zoomScale) }
            }
        default:
            break
        }
    }
    #endif

    /// While zoomed in, the page can be panned (iOS: the scroll view scrolls); at scale 1 the view is pinned to the
    /// visible slot again and page turns take over.
    private func zoomScaleDidChange(_ scale: CGFloat) {
        // WebKit moves the scale around while it lays a document out; only a user zoom on a zoomable face counts.
        let zoomed = isZoomEnabled && scale > 1.01
        #if canImport(UIKit)
        if !isScrollMode, webView.scrollView.isScrollEnabled != zoomed {
            webView.scrollView.isScrollEnabled = zoomed
            if !zoomed { syncNativeScroll(to: CGPoint(x: slotRect(visibleSlot).minX, y: slotRect(visibleSlot).minY)) }
        }
        #endif
        guard zoomed != isZoomed else { return }
        isZoomed = zoomed
        onZoomChanged?(zoomed)
    }

    // MARK: - Geometry

    func setPageSize(_ size: CGSize) {
        guard size != pageSize, size.width > 0, size.height > 0 else { return }
        pageSize = size
        clipView.frame = CGRect(origin: clipView.frame.origin, size: size)
        curtain.frame = CGRect(origin: .zero, size: size)
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
        if isScrollMode {
            // The frame is the visible area: the document scrolls inside it (08-continuous-scroll §4.1).
            webView.frame = CGRect(origin: .zero, size: pageSize)
        } else if writingMode.isVertical {
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
        if isScrollMode { return CGRect(origin: .zero, size: pageSize) }
        if writingMode.isVertical {
            return CGRect(x: 0, y: CGFloat(slot) * pageSize.height, width: pageSize.width, height: pageSize.height)
        }
        return CGRect(x: CGFloat(slot) * pageSize.width, y: 0, width: pageSize.width, height: pageSize.height)
    }

    func setBackgroundColor(_ color: ReaderColor) {
        #if canImport(AppKit)
        clipView.layer?.backgroundColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        curtain.layer?.backgroundColor = clipView.layer?.backgroundColor
        webView.underPageBackgroundColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        #else
        clipView.backgroundColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
        curtain.backgroundColor = clipView.backgroundColor
        webView.underPageBackgroundColor = clipView.backgroundColor
        #endif
    }

    func setContentHidden(_ hidden: Bool) {
        isContentHidden = hidden
        curtain.isHidden = !hidden
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
        // Appended: a spread wrapper URL already carries its own query (M4).
        let existing = components?.queryItems ?? []
        components?.queryItems = existing + [URLQueryItem(name: "__reader_load", value: String(loadCounter))]
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

    func setHighlights(_ highlights: [HighlightDrawing]) async throws -> [String] {
        let list: [[String: Any]] = highlights.map { highlight in
            ["id": highlight.id, "cfiRange": highlight.range.description, "color": highlight.color.cssString, "style": highlight.style.rawValue]
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
        return LayoutResult(
            pageCount: max(1, pageCount),
            writingMode: WritingMode(cssValue: dict["writingMode"] as? String ?? "horizontal-tb"),
            columnsPerPage: dict["columnsPerPage"] as? Int ?? 1
        )
    }

    // MARK: - Scrolled layout (08-continuous-scroll §4, §5.6)

    private(set) var isScrollMode = false
    var onScrollInteractionChanged: (@MainActor (Bool) -> Void)?
    /// The reader's hands are scrolling, as last told to the document.
    private(set) var isScrollInteractionActive = false
    #if canImport(UIKit)
    private var interactionPoll: Timer?
    private var panTargetInstalled = false
    #else
    private(set) var wheel = WheelInteraction()
    private var wheelDeadline: Timer?
    #endif

    func setScrollMode(_ enabled: Bool) {
        guard enabled != isScrollMode else { return }
        isScrollMode = enabled
        visibleSlot = 0
        #if canImport(UIKit)
        let scrollView = webView.scrollView
        scrollView.isScrollEnabled = enabled
        scrollView.bounces = enabled
        scrollView.alwaysBounceHorizontal = false
        scrollView.isDirectionalLockEnabled = enabled
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delegate = enabled ? self : nil
        if enabled, !panTargetInstalled {
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(panDidChange(_:)))
            panTargetInstalled = true
        }
        if !enabled { scrollView.setContentOffset(.zero, animated: false) }
        setInteractionPolling(enabled)
        #else
        if enabled {
            webView.onScrollWheel = { [weak self] (event: NSEvent) -> Bool in
                guard let self else { return true }
                return self.handleWheel(event)
            }
        } else {
            webView.onScrollWheel = nil
        }
        wheel = WheelInteraction()
        wheelDeadline?.invalidate()
        wheelDeadline = nil
        #endif
        if !enabled { setInteractionActive(false, tellDocument: false) }
        layoutWebViewFrame()
    }

    private func setInteractionActive(_ active: Bool, tellDocument: Bool = true) {
        guard active != isScrollInteractionActive else { return }
        isScrollInteractionActive = active
        if tellDocument {
            // Calls reach the document in the order they are made, so a call that follows sees this state.
            webView.callAsyncJavaScript(
                "if (window.__epubReader && window.__epubReader.setInteraction) { window.__epubReader.setInteraction({active: active}); }",
                arguments: ["active": active], in: nil, in: Self.readerWorld, completionHandler: nil
            )
        }
        onScrollInteractionChanged?(active)
    }

    #if canImport(UIKit)
    /// Reads the scroll view's flags. A timer reads them every 0.05 s for as long as the scrolled layout is shown
    /// (08-continuous-scroll §5.6): no delegate call or gesture action marks every way an interaction begins and
    /// ends (a finger that rests on the screen without moving is tracked before any drag begins; a touch that stops
    /// the momentum lifts without dragging). The pan recognizer's action only makes the common case immediate.
    private func evaluateInteraction() {
        let scrollView = webView.scrollView
        let active = isScrollMode && ScrollViewInteraction.isActive(isTracking: scrollView.isTracking, isDragging: scrollView.isDragging, isDecelerating: scrollView.isDecelerating)
        setInteractionActive(active)
    }

    private func setInteractionPolling(_ enabled: Bool) {
        interactionPoll?.invalidate()
        interactionPoll = nil
        guard enabled else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            // The renderer went away while the scrolled layout was shown: the timer goes with it.
            guard self != nil else { timer.invalidate(); return }
            MainActor.assumeIsolated { self?.evaluateInteraction() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        interactionPoll = timer
    }

    @objc private func panDidChange(_ recognizer: UIPanGestureRecognizer) {
        evaluateInteraction()
    }
    #else
    /// One scroll-wheel event of the scrolled layout. Returns whether the web view gets it.
    private func handleWheel(_ event: NSEvent) -> Bool {
        handleWheel(WheelInteraction.Event(phase: Self.phase(event.phase), momentumPhase: Self.phase(event.momentumPhase), time: event.timestamp))
    }

    /// The same for an event described by its phases (tests drive the state without real events).
    @discardableResult
    func handleWheel(_ event: WheelInteraction.Event) -> Bool {
        let deliver = wheel.handle(event)
        syncWheelInteraction(at: event.time)
        return deliver
    }

    private func syncWheelInteraction(at time: TimeInterval) {
        wheel.expireWithholding(at: time)
        setInteractionActive(wheel.isActive(at: time))
        wheelDeadline?.invalidate()
        wheelDeadline = nil
        guard let deadline = wheel.deadline(after: time) else { return }
        let timer = Timer(timeInterval: max(0.01, deadline - time + 0.005), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWheelInteraction(at: ProcessInfo.processInfo.systemUptime) }
        }
        RunLoop.main.add(timer, forMode: .common)
        wheelDeadline = timer
    }

    private static func phase(_ phase: NSEvent.Phase) -> WheelInteraction.Phase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        if phase.contains(.mayBegin) { return .mayBegin }
        return .none
    }
    #endif

    func stopScrolling() async {
        guard isScrollMode else { return }
        #if canImport(UIKit)
        let scrollView = webView.scrollView
        if ScrollViewInteraction.isActive(isTracking: scrollView.isTracking, isDragging: scrollView.isDragging, isDecelerating: scrollView.isDecelerating) {
            scrollView.stopScrollingAndZooming()
            if scrollView.isTracking || scrollView.isDragging {
                // A finger is down: ending the recognizer ends the tracking.
                scrollView.panGestureRecognizer.isEnabled = false
                scrollView.panGestureRecognizer.isEnabled = true
            }
            for _ in 0..<25 {
                if !ScrollViewInteraction.isActive(isTracking: scrollView.isTracking, isDragging: scrollView.isDragging, isDecelerating: scrollView.isDecelerating) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        evaluateInteraction()
        #else
        let now = ProcessInfo.processInfo.systemUptime
        wheel.stop(at: now)
        syncWheelInteraction(at: now)
        #endif
        // The document hears "not active" before whatever the caller does next.
        _ = try? await call("return window.__epubReader && window.__epubReader.setInteraction ? window.__epubReader.setInteraction({active: active}) : false", arguments: ["active": isScrollInteractionActive])
    }

    func showLocation(_ target: ScrollTarget) async throws -> ScrollShowResult {
        let result = try await call("return window.__epubReader.showLocation(target)", arguments: ["target": target.dictionary])
        guard let dict = result as? [String: Any] else { throw ReaderError.scriptFailed("showLocation returned \(String(describing: result))") }
        if dict["missing"] as? Bool == true { return .missing }
        if dict["vertical"] as? Bool == true { return .vertical(spineIndex: dict["spineIndex"] as? Int ?? target.spineIndex) }
        guard let location = ScrollLocation(dict) else { throw ReaderError.scriptFailed("showLocation returned \(dict)") }
        return .shown(location)
    }

    func scrollBy(pages: Int, lines: Int, animated: Bool) async throws -> ScrollLocation? {
        let result = try await call("return window.__epubReader.scrollBy(step)", arguments: ["step": ["pages": pages, "lines": lines, "animated": animated]])
        return ScrollLocation(result)
    }

    func locationAtReadingLine() async throws -> ScrollLocation? {
        ScrollLocation(try await call("return window.__epubReader.locationAtReadingLine ? window.__epubReader.locationAtReadingLine() : null"))
    }

    func setEstimates(_ heights: [Double]) async throws {
        _ = try await call("return window.__epubReader.setEstimates ? window.__epubReader.setEstimates(heights) : false", arguments: ["heights": heights])
    }

    func scrollWindowContains(spineIndex: Int) async throws -> Bool {
        let result = try await call("return window.__epubReader.windowContains ? window.__epubReader.windowContains(index) : false", arguments: ["index": spineIndex])
        return result as? Bool ?? false
    }

    func trimScrollWindow() async throws {
        _ = try await call("return window.__epubReader.trimWindow ? window.__epubReader.trimWindow() : 0")
    }

    // MARK: - Snapshots

    func snapshot(slot: Int) async throws -> (image: CGImage, scale: CGFloat)? {
        guard pageSize.width > 0, pageSize.height > 0, !isContentHidden else { return nil }
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

#if canImport(UIKit)
// MARK: - UIScrollViewDelegate (scrolled layout, 08-continuous-scroll §5.6)

extension WebViewSpineRenderer: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { evaluateInteraction() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { evaluateInteraction() }
    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) { evaluateInteraction() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { evaluateInteraction() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { evaluateInteraction() }
}
#endif

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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if canImport(UIKit)
        syncPinchRecognizer()
        #endif
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
