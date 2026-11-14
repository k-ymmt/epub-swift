import Foundation
import WebKit
import EPUBCore

/// Maps `PublicationID` → `EPUBContainer` for the scheme handler (docs/design/02-rendering.md §2.1).
///
/// Several sessions may show the same container, so registrations are counted: the container stays served until
/// every session that registered it has unregistered.
@MainActor
final class PublicationRegistry {
    static let shared = PublicationRegistry()

    private var containers: [PublicationID: (container: EPUBContainer, count: Int)] = [:]
    private var fonts: [PublicationID: [String: URL]] = [:]

    func register(_ container: EPUBContainer) {
        let count = containers[container.id]?.count ?? 0
        containers[container.id] = (container, count + 1)
    }

    func unregister(_ id: PublicationID) {
        guard let entry = containers[id] else { return }
        if entry.count > 1 {
            containers[id] = (entry.container, entry.count - 1)
        } else {
            containers[id] = nil
            fonts[id] = nil
        }
    }

    /// Number of live registrations (tests).
    func registrationCount(for id: PublicationID) -> Int {
        containers[id]?.count ?? 0
    }

    func container(for id: PublicationID) -> EPUBContainer? {
        containers[id]?.container
    }

    func registerFont(_ resource: FontResource, for id: PublicationID) {
        fonts[id, default: [:]][resource.familyName] = resource.fileURL
    }

    func fontURL(named name: String, for id: PublicationID) -> URL? {
        fonts[id]?[name]
    }
}

/// Serves `epub://<publicationID>/<path>` straight from the ZIP (docs/design/02-rendering.md §2).
///
/// - `_reader/spread?…`, `_reader/scroll?…` → the generated wrapper documents (`SpreadDocument`, `ScrollDocument`)
/// - `_reader/css/<name>.css` → the bundled stylesheets
/// - `_reader/fonts/<family>` → a custom font registered through `ReaderSettings.FontChoice.custom`
/// - spine XHTML → the (possibly repaired) document with the viewport meta and stylesheets injected
/// - anything else → the manifest media type and raw bytes
@MainActor
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "epub"

    /// CSS for the current settings; the session updates it before each load (`ContentInjector.rootStyle`).
    var rootStyle: String = ""
    /// Called on the main actor for warnings found while serving (missing resources, malformed XHTML).
    var onWarning: (@MainActor (PublicationWarning) -> Void)?

    private var activeTasks: Set<ObjectIdentifier> = []
    private let bundle: Bundle

    init(bundle: Bundle = .module) {
        self.bundle = bundle
        super.init()
    }

    static func url(publicationID: PublicationID, path: String) -> URL {
        URL(string: "\(scheme)://\(publicationID)/\(ContainerPath.percentEncoded(ContainerPath.normalize(path)))")!
    }

    /// The container path a request addresses. `URL.path` is already percent-decoded; decoding again would turn a
    /// literal `%20` in a file name into a space.
    static func containerPath(of url: URL) -> String {
        ContainerPath.normalize(url.path)
    }

    /// The bundled stylesheet `name` (`reader-after.css`).
    nonisolated static func readerResourceFileURL(name: String, in bundle: Bundle = .module) -> URL? {
        let base = (name as NSString).deletingPathExtension
        return bundle.url(forResource: base, withExtension: "css", subdirectory: "Reader") ?? bundle.url(forResource: base, withExtension: "css")
    }

    static func readerResourceURL(publicationID: PublicationID, name: String) -> String {
        "\(scheme)://\(publicationID)/_reader/css/\(name)"
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(taskID)
        guard let url = urlSchemeTask.request.url, let host = url.host, let publicationID = PublicationID(host) else {
            finish(urlSchemeTask, taskID: taskID, response: Self.errorResponse(url: urlSchemeTask.request.url, status: 400), data: nil)
            return
        }
        guard let container = PublicationRegistry.shared.container(for: publicationID) else {
            finish(urlSchemeTask, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            return
        }
        let path = Self.containerPath(of: url)

        if path == SpreadDocument.path {
            serveSpreadDocument(url: url, container: container, task: urlSchemeTask, taskID: taskID)
            return
        }
        if path == ScrollDocument.path {
            serveScrollDocument(url: url, container: container, task: urlSchemeTask, taskID: taskID)
            return
        }
        if path.hasPrefix("_reader/") {
            serveReaderResource(path: path, url: url, publicationID: publicationID, task: urlSchemeTask, taskID: taskID)
            return
        }

        let rootStyle = self.rootStyle
        let spineIndex = container.publication.spineIndex(ofPath: path)
        let isSpineItem = spineIndex != nil
        let mediaType = container.mediaType(forPath: path)
        // Per item (M4): a pre-paginated page gets only reader-fixed.css; the book-level layout decides for XHTML
        // that is not in the spine.
        let isFixedLayout = spineIndex.map { container.publication.readingOrder[$0].isFixedLayout } ?? (container.publication.layout == .prePaginated)
        let injection = ContentInjector.Injection(
            beforeStylesheetURL: Self.readerResourceURL(publicationID: publicationID, name: "reader-before.css"),
            afterStylesheetURL: Self.readerResourceURL(publicationID: publicationID, name: "reader-after.css"),
            rootStyle: rootStyle,
            injectViewport: !isFixedLayout,
            fixedStylesheetURL: isFixedLayout ? Self.readerResourceURL(publicationID: publicationID, name: "reader-fixed.css") : nil
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if isSpineItem || mediaType == XHTMLRepair.xhtmlMediaType {
                    let document = try await container.contentDocument(at: path)
                    for warning in document.warnings { self.onWarning?(warning) }
                    let injected = ContentInjector.inject(document.data, isXML: document.isXML, injection: injection)
                    let response = Self.response(url: url, mediaType: document.mediaType, length: injected.data.count)
                    self.finish(urlSchemeTask, taskID: taskID, response: response, data: injected.data)
                } else {
                    let data = try await container.data(at: path)
                    let response = Self.response(url: url, mediaType: mediaType, length: data.count)
                    self.finish(urlSchemeTask, taskID: taskID, response: response, data: data)
                }
            } catch {
                self.onWarning?(.missingResource(path: path, referencedFrom: "webview"))
                self.finish(urlSchemeTask, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: - Spread wrapper (M4)

    /// `_reader/spread?kind=fixed&pages=3r,4l`: the wrapper document with one iframe per page (`SpreadDocument`).
    private func serveSpreadDocument(url: URL, container: EPUBContainer, task: any WKURLSchemeTask, taskID: ObjectIdentifier) {
        guard let parsed = SpreadDocument.parse(query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems),
              let html = SpreadDocument.html(publication: container.publication, publicationID: container.id, kind: parsed.kind, pages: parsed.pages, rootStyle: rootStyle) else {
            finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            return
        }
        let data = Data(html.utf8)
        finish(task, taskID: taskID, response: Self.response(url: url, mediaType: "text/html", length: data.count), data: data)
    }

    // MARK: - Scroll wrapper (08-continuous-scroll §4.1)

    /// `_reader/scroll?start=12`: the wrapper document of the scrolled layout (`ScrollDocument`).
    private func serveScrollDocument(url: URL, container: EPUBContainer, task: any WKURLSchemeTask, taskID: ObjectIdentifier) {
        guard let parsed = ScrollDocument.parse(query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems),
              let html = ScrollDocument.html(publication: container.publication, publicationID: container.id, start: parsed.start, single: parsed.single, rootStyle: rootStyle) else {
            finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            return
        }
        let data = Data(html.utf8)
        finish(task, taskID: taskID, response: Self.response(url: url, mediaType: "text/html", length: data.count), data: data)
    }

    // MARK: - Reader resources

    private func serveReaderResource(path: String, url: URL, publicationID: PublicationID, task: any WKURLSchemeTask, taskID: ObjectIdentifier) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 3 else {
            finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            return
        }
        switch components[1] {
        case "css":
            if let fileURL = Self.readerResourceFileURL(name: components[2], in: bundle),
               let data = try? Data(contentsOf: fileURL) {
                finish(task, taskID: taskID, response: Self.response(url: url, mediaType: "text/css", length: data.count), data: data)
            } else {
                finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            }
        case "fonts":
            let family = components[2...].joined(separator: "/")
            if let fileURL = PublicationRegistry.shared.fontURL(named: family, for: publicationID),
               let data = try? Data(contentsOf: fileURL) {
                let type = MediaTypes.guess(forPath: fileURL.path)
                finish(task, taskID: taskID, response: Self.response(url: url, mediaType: type, length: data.count), data: data)
            } else {
                finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            }
        default:
            finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
        }
    }

    // MARK: - Responses

    /// Responds only if the task has not been stopped (responding after `stop` makes WebKit throw).
    private func finish(_ task: any WKURLSchemeTask, taskID: ObjectIdentifier, response: URLResponse, data: Data?) {
        guard activeTasks.contains(taskID) else { return }
        task.didReceive(response)
        if let data { task.didReceive(data) }
        task.didFinish()
        activeTasks.remove(taskID)
    }

    private static func response(url: URL, mediaType: String, length: Int) -> URLResponse {
        var headers = ["Content-Type": mediaType, "Content-Length": "\(length)", "Cache-Control": "no-store"]
        if mediaType.hasPrefix("text/") && !mediaType.contains("charset") {
            headers["Content-Type"] = "\(mediaType); charset=utf-8"
        }
        return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func errorResponse(url: URL?, status: Int) -> URLResponse {
        HTTPURLResponse(url: url ?? URL(string: "epub://invalid/")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
    }
}
