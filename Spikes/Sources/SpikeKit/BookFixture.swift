import Foundation

/// An extracted EPUB on disk, served to the spike web view under `epub://spike/book/…` (spikes 8 and 9).
/// The spikes do not link the library, so the spine is read with two regular expressions: enough for the test
/// fixtures, not a parser.
public struct BookFixture: Sendable {
    public let root: URL
    /// Paths of the linear spine items, relative to `root` (e.g. `OPS/chapter_001.xhtml`).
    public let spine: [String]

    public static let prefix = "/book/"

    /// CSS added to every spine item: what the library's reader CSS would do in a scrolled layout (no columns,
    /// the root as tall as its content, the page margins as body padding).
    public static let scrolledCSS = """
        html { margin: 0 !important; padding: 0 !important; height: auto !important; overflow: hidden !important; }
        body { margin: 0 auto !important; padding: 20px 24px !important; max-width: 680px; height: auto !important;
               font-size: 17px; line-height: 1.6 !important; overflow-wrap: anywhere; }
        img, svg, video { max-width: 100% !important; height: auto; }
        """

    public init(directory: URL) throws {
        root = directory
        let container = try String(contentsOf: directory.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfPath = Self.firstMatch(#"full-path="([^"]+)""#, in: container) else {
            throw SpikeError.unexpected("no rootfile in container.xml")
        }
        let opf = try String(contentsOf: directory.appendingPathComponent(opfPath), encoding: .utf8)
        let base = (opfPath as NSString).deletingLastPathComponent
        var hrefs: [String: String] = [:]
        for tag in Self.matches(#"<item\b[^>]*>"#, in: opf) {
            if let id = Self.firstMatch(#"\bid="([^"]+)""#, in: tag), let href = Self.firstMatch(#"\bhref="([^"]+)""#, in: tag) {
                hrefs[id] = base.isEmpty ? href : base + "/" + href
            }
        }
        var items: [String] = []
        for tag in Self.matches(#"<itemref\b[^>]*>"#, in: opf) where !tag.contains(#"linear="no""#) {
            if let idref = Self.firstMatch(#"\bidref="([^"]+)""#, in: tag), let path = hrefs[idref] { items.append(path) }
        }
        guard !items.isEmpty else { throw SpikeError.unexpected("empty spine in \(opfPath)") }
        spine = items
    }

    /// The fixture named by `SPIKE_BOOK_DIR`, or `.build/book/moby-dick` (extracted from the root package's test
    /// fixture on first use; macOS only, the iOS script extracts it on the host).
    public static func fromEnvironment() throws -> BookFixture {
        if let dir = ProcessInfo.processInfo.environment["SPIKE_BOOK_DIR"], !dir.isEmpty {
            return try BookFixture(directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        let dir = URL(fileURLWithPath: ".build/book/moby-dick", isDirectory: true)
        #if os(macOS)
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("META-INF/container.xml").path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-q", "-o", "../Tests/Fixtures/moby-dick.epub", "-d", dir.path]
            try p.run()
            p.waitUntilExit()
        }
        #endif
        return try BookFixture(directory: dir)
    }

    public func url(_ index: Int) -> String { "epub://spike" + Self.prefix + spine[index] }
    public var urls: [String] { spine.indices.map(url) }

    /// Serves the book's files; spine items get `scrolledCSS`. `extra` adds synthetic documents by path relative to
    /// the book root (the giant chapter).
    @MainActor
    public func install(on host: WebHost, extra: [String: String] = [:]) {
        let root = self.root
        let spineSet = Set(spine)
        host.handler.provider = { path in
            guard path.hasPrefix(Self.prefix) else { return nil }
            let relative = String(path.dropFirst(Self.prefix.count)).removingPercentEncoding ?? ""
            if let text = extra[relative] { return ServedResource(mimeType: Fixtures.xhtmlMIME, Self.injecting(text)) }
            guard !relative.contains(".."), let data = try? Data(contentsOf: root.appendingPathComponent(relative)) else { return nil }
            let mime = Self.mimeType(forExtension: (relative as NSString).pathExtension.lowercased())
            if spineSet.contains(relative), let text = String(data: data, encoding: .utf8) {
                return ServedResource(mimeType: mime, Self.injecting(text))
            }
            return ServedResource(mimeType: mime, data: data)
        }
    }

    public func text(_ index: Int) throws -> String {
        try String(contentsOf: root.appendingPathComponent(spine[index]), encoding: .utf8)
    }

    /// A chapter made of `count` copies of another chapter's body: a stand-in for a very long chapter.
    public func repeated(_ index: Int, count: Int) throws -> String {
        let source = try text(index)
        guard let open = source.range(of: "<body"), let openEnd = source.range(of: ">", range: open.upperBound..<source.endIndex),
              let close = source.range(of: "</body>", options: .backwards) else { throw SpikeError.unexpected("no body in \(spine[index])") }
        // The ids repeat; nothing in the spike resolves them.
        let body = String(source[openEnd.upperBound..<close.lowerBound])
        return String(source[..<openEnd.upperBound]) + String(repeating: body, count: count) + String(source[close.lowerBound...])
    }

    static func injecting(_ xhtml: String) -> String {
        let style = "<style id=\"__spike_scrolled\">\(scrolledCSS)</style>"
        if let r = xhtml.range(of: "</head>") { return xhtml.replacingCharacters(in: r, with: style + "</head>") }
        return xhtml
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext {
        case "xhtml", "xml", "opf": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "otf": return "font/otf"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
