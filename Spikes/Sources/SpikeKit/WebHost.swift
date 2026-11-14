import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif

public struct ServedResource: Sendable {
    public var mimeType: String
    public var data: Data
    public init(mimeType: String, _ text: String) {
        self.mimeType = mimeType
        self.data = Data(text.utf8)
    }
    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

/// Minimal `epub://spike/<path>` scheme handler serving in-memory resources, like the planned EPUBSchemeHandler.
@MainActor
public final class SpikeSchemeHandler: NSObject, @preconcurrency WKURLSchemeHandler {
    public var resources: [String: ServedResource] = [:]
    /// Fallback for paths not in `resources` (spike 8: the files of an extracted EPUB, read from disk on demand).
    public var provider: (@MainActor (String) -> ServedResource?)?
    public private(set) var requestLog: [String] = []

    public func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        requestLog.append(url.absoluteString)
        guard let res = resources[url.path] ?? provider?(url.path) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.isText(res.mimeType) ? "\(res.mimeType); charset=utf-8" : res.mimeType, "Content-Length": "\(res.data.count)"]
        )!
        task.didReceive(response)
        task.didReceive(res.data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    static func isText(_ mime: String) -> Bool {
        mime.hasPrefix("text/") || mime.contains("xml") || mime.contains("json") || mime.contains("javascript")
    }
}

public struct UserScriptSpec: Sendable {
    public var source: String
    public var injectionTime: WKUserScriptInjectionTime
    public var mainFrameOnly: Bool
    public init(_ source: String, at injectionTime: WKUserScriptInjectionTime = .atDocumentEnd, mainFrameOnly: Bool = true) {
        self.source = source
        self.injectionTime = injectionTime
        self.mainFrameOnly = mainFrameOnly
    }
}

/// One WKWebView inside a clipping view inside a window, driven from async code.
@MainActor
public final class WebHost: NSObject, @preconcurrency WKNavigationDelegate, @preconcurrency WKScriptMessageHandlerWithReply {
    public let handler = SpikeSchemeHandler()
    public static let readerWorld = WKContentWorld.world(name: "reader")
    public let webView: WKWebView
    public let clipView: PlatformView
    public let visibleSize: CGSize
    #if canImport(AppKit)
    public let window: NSWindow
    #else
    public let window: UIWindow
    #endif
    public private(set) var receivedMessages: [[String: Any]] = []
    public var replyProvider: (@MainActor ([String: Any]) -> Any?)?
    private var navigationWaiters: [CheckedContinuation<Error?, Never>] = []

    public init(
        visibleSize: CGSize,
        webViewFrame: CGRect? = nil,
        allowsContentJavaScript: Bool = false,
        userScripts: [UserScriptSpec] = [],
        messageHandlerName: String = "reader",
        scrollable: Bool = false
    ) {
        self.visibleSize = visibleSize
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "epub")
        config.defaultWebpagePreferences.allowsContentJavaScript = allowsContentJavaScript
        config.suppressesIncrementalRendering = true
        let ucc = WKUserContentController()
        for s in userScripts {
            ucc.addUserScript(WKUserScript(source: s.source, injectionTime: s.injectionTime, forMainFrameOnly: s.mainFrameOnly, in: Self.readerWorld))
        }
        config.userContentController = ucc
        let frame = webViewFrame ?? CGRect(origin: .zero, size: visibleSize)
        webView = WKWebView(frame: frame, configuration: config)
        #if canImport(AppKit)
        clipView = NSView(frame: CGRect(origin: .zero, size: visibleSize))
        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: visibleSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "EPUB spike"
        window.contentView = clipView
        clipView.addSubview(webView)
        // A window covered by another one stops painting (the page becomes `hidden`, `requestAnimationFrame` stops),
        // and a spike that waits for frames then hangs: SPIKE_WINDOW_FLOATING=1 keeps it above the other windows.
        if ProcessInfo.processInfo.environment["SPIKE_WINDOW_FLOATING"] == "1" { window.level = .floating }
        window.orderFrontRegardless()
        #else
        clipView = UIView(frame: CGRect(origin: .zero, size: visibleSize))
        clipView.clipsToBounds = true
        window = UIWindow(frame: CGRect(origin: .zero, size: visibleSize))
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene {
            window.windowScene = scene
        }
        let vc = UIViewController()
        vc.view.addSubview(clipView)
        window.rootViewController = vc
        clipView.addSubview(webView)
        window.makeKeyAndVisible()
        // Spike 8 / 9 let the web view scroll its main frame (continuous scroll); the other spikes page by script.
        webView.scrollView.isScrollEnabled = scrollable
        webView.scrollView.bounces = scrollable
        webView.scrollView.showsVerticalScrollIndicator = !scrollable
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        super.init()
        webView.navigationDelegate = self
        ucc.addScriptMessageHandler(self, contentWorld: Self.readerWorld, name: messageHandlerName)
    }

    public func serve(_ path: String, _ mimeType: String, _ text: String) {
        handler.resources[path] = ServedResource(mimeType: mimeType, text)
    }

    public func url(_ path: String) -> URL { URL(string: "epub://spike\(path)")! }

    /// Loads `epub://spike/<path>` and waits for the main-frame navigation to finish.
    public func load(_ path: String, timeout: Duration = .seconds(10)) async throws {
        let err: Error? = await withCheckedContinuation { cont in
            navigationWaiters.append(cont)
            webView.load(URLRequest(url: url(path)))
        }
        if let err { throw err }
        #if canImport(UIKit)
        // Let the window-appearance animation finish; iOS takeSnapshot captures the view hierarchy as displayed.
        try await Task.sleep(for: .milliseconds(600))
        #endif
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let w = navigationWaiters; navigationWaiters = []
        w.forEach { $0.resume(returning: nil) }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let w = navigationWaiters; navigationWaiters = []
        w.forEach { $0.resume(returning: error) }
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let w = navigationWaiters; navigationWaiters = []
        w.forEach { $0.resume(returning: error) }
    }

    public func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        let body = (message.body as? [String: Any]) ?? ["raw": message.body]
        receivedMessages.append(body)
        replyHandler(replyProvider?(body) ?? "reply-from-swift", nil)
    }

    public func waitForMessage(type: String, timeout: Duration = .seconds(5)) async throws -> [String: Any] {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let m = receivedMessages.first(where: { ($0["type"] as? String) == type }) { return m }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SpikeError.timeout("message \(type)")
    }

    /// Runs a function body via callAsyncJavaScript in the reader world (or another world).
    @discardableResult
    public func js(_ body: String, args: [String: Any] = [:], world: WKContentWorld = WebHost.readerWorld) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: args, in: nil, contentWorld: world)
    }

    public func jsDict(_ body: String, args: [String: Any] = [:], world: WKContentWorld = WebHost.readerWorld) async throws -> [String: Any] {
        (try await js(body, args: args, world: world) as? [String: Any]) ?? [:]
    }

    public struct Snapshot {
        public var image: CGImage
        public var bitmap: Bitmap
        public var elapsed: Duration
        public var scale: Double
    }

    /// takeSnapshot(with:) for a rect in view coordinates (points, top-left origin).
    /// `snapshotWidth` is given in points; on Retina macOS the returned image is still backing-scale pixels.
    public func snapshot(rect: CGRect? = nil, scale: Double = 1, afterScreenUpdates: Bool = true) async throws -> Snapshot {
        let config = WKSnapshotConfiguration()
        if let rect {
            config.rect = rect
            config.snapshotWidth = NSNumber(value: Double(rect.width) * scale)
        } else {
            config.snapshotWidth = NSNumber(value: Double(webView.bounds.width) * scale)
        }
        config.afterScreenUpdates = afterScreenUpdates
        let clock = ContinuousClock()
        let start = clock.now
        let img = try await webView.takeSnapshot(configuration: config)
        let elapsed = clock.now - start
        #if canImport(AppKit)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw SpikeError.unexpected("no cgImage") }
        #else
        guard let cg = img.cgImage else { throw SpikeError.unexpected("no cgImage") }
        #endif
        let pointWidth = Double(rect?.width ?? webView.bounds.width)
        let pointScale = Double(cg.width) / pointWidth
        return Snapshot(image: cg, bitmap: Bitmap(cgImage: cg, pointScale: pointScale), elapsed: elapsed, scale: pointScale)
    }

    public func settle(_ ms: Int = 100) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    /// pid of the WebContent process. Uses the private `_webProcessIdentifier` when available (spike only),
    /// otherwise the WebContent process that appeared after this host was created.
    public var webContentPID: Int32? {
        let sel = Selector(("_webProcessIdentifier"))
        if webView.responds(to: sel), let n = webView.value(forKey: "_webProcessIdentifier") as? NSNumber, n.int32Value > 0 {
            return n.int32Value
        }
        let now = Set(webContentPIDs())
        let new = now.subtracting(pidsBeforeCreation)
        return new.count == 1 ? new.first : nil
    }
    private var pidsBeforeCreation: Set<Int32> = []

    /// pid of the GPU process (private `_gpuProcessIdentifier`, spike only). The process is shared by every web view.
    public var gpuPID: Int32? {
        let sel = Selector(("_gpuProcessIdentifier"))
        guard webView.responds(to: sel), let n = webView.value(forKey: "_gpuProcessIdentifier") as? NSNumber, n.int32Value > 0 else { return nil }
        return n.int32Value
    }

    /// Takes the window off screen so the next host starts from a clean slate.
    public func close() {
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        #if canImport(AppKit)
        window.orderOut(nil)
        #else
        window.isHidden = true
        #endif
    }
    public func rememberExistingWebContentProcesses() { pidsBeforeCreation = Set(webContentPIDs()) }
}

/// pids of all WebContent processes on this machine (macOS).
public func webContentPIDs() -> [Int32] {
    #if os(macOS)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "com.apple.WebKit.WebContent"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return s.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    #else
    return []
    #endif
}

/// Resident memory of a process in MB, via `ps` (works for the WebContent process we don't own).
public func residentMemoryMB(pid: Int32) -> Double? {
    #if os(macOS)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "rss=", "-p", "\(pid)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let kb = Double(s) else { return nil }
    return kb / 1024
    #else
    return nil
    #endif
}

@_silgen_name("proc_pid_rusage")
private func spike_proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutablePointer<rusage_info_v2>) -> Int32

/// Physical footprint of a process in MB (`proc_pid_rusage`, what Activity Monitor and jetsam count). Works for the
/// WebContent / GPU processes of the same user, on macOS and in the iOS Simulator (where they are host processes).
public func footprintMB(pid: Int32) -> Double? {
    var info = rusage_info_v2()
    guard spike_proc_pid_rusage(pid, 2 /* RUSAGE_INFO_V2 */, &info) == 0 else { return nil }
    return Double(info.ri_phys_footprint) / 1_048_576
}
