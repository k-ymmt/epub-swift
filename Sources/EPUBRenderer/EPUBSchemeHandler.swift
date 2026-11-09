import Foundation
import WebKit
import EPUBCore

/// Maps `PublicationID` → `EPUBContainer` for the scheme handler (docs/design/02-rendering.md §2.1).
@MainActor
final class PublicationRegistry {
    static let shared = PublicationRegistry()

    private var containers: [PublicationID: EPUBContainer] = [:]
    private var fonts: [PublicationID: [String: URL]] = [:]

    func register(_ container: EPUBContainer) {
        containers[container.id] = container
    }

    func unregister(_ id: PublicationID) {
        containers[id] = nil
        fonts[id] = nil
    }

    func container(for id: PublicationID) -> EPUBContainer? {
        containers[id]
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
        let path = ContainerPath.normalize(url.path.removingPercentEncoding ?? url.path)

        if path.hasPrefix("_reader/") {
            serveReaderResource(path: path, url: url, publicationID: publicationID, task: urlSchemeTask, taskID: taskID)
            return
        }

        let rootStyle = self.rootStyle
        let isSpineItem = container.publication.spineIndex(ofPath: path) != nil
        let mediaType = container.mediaType(forPath: path)
        let isReflowable = container.publication.layout == .reflowable
        let injection = ContentInjector.Injection(
            beforeStylesheetURL: Self.readerResourceURL(publicationID: publicationID, name: "reader-before.css"),
            afterStylesheetURL: Self.readerResourceURL(publicationID: publicationID, name: "reader-after.css"),
            rootStyle: rootStyle,
            injectViewport: isReflowable
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

    // MARK: - Reader resources

    private func serveReaderResource(path: String, url: URL, publicationID: PublicationID, task: any WKURLSchemeTask, taskID: ObjectIdentifier) {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 3 else {
            finish(task, taskID: taskID, response: Self.errorResponse(url: url, status: 404), data: nil)
            return
        }
        switch components[1] {
        case "css":
            let name = (components[2] as NSString).deletingPathExtension
            if let fileURL = bundle.url(forResource: name, withExtension: "css", subdirectory: "Reader") ?? bundle.url(forResource: name, withExtension: "css"),
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
