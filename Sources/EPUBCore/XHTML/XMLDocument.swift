import Foundation

/// Lightweight XML tree built with Foundation's `XMLParser` (docs/design/01-core.md §4.2).
///
/// Only element and text nodes are kept. Comments, processing instructions and CDATA sections are folded into
/// the surrounding text (CDATA contributes its characters; comments and PIs contribute nothing but do not
/// split a text node). Adjacent text is merged and whitespace-only text is preserved, which matches the DOM
/// WebKit builds from the same bytes with its XML parser.
public struct XMLDocument: Sendable, Hashable {
    /// Which tree `init(data:tree:)` builds.
    public enum Tree: Sendable, Hashable {
        /// The DOM the reader's WebView builds (the default; CFIs, search and notes use it). With content JavaScript
        /// disabled WebKit removes XHTML and SVG `script` elements from the tree, and the children of an XHTML
        /// `template` go into its content fragment, not the tree. Both are left out here; the text around a removed
        /// `script` merges like text around a comment (`reader.js` treats the two DOM text nodes as one logical
        /// text node). docs/design/06-annotations.md §12.1.
        case rendered
        /// Every element as written (EPUB Annotations selectors count this tree, 06-annotations §5).
        case source
    }

    public var root: XMLElement

    public init(root: XMLElement) {
        self.root = root
    }

    /// Parses `data` as well-formed XML into the `.rendered` tree. Throws `XMLParseError` on any well-formedness error.
    /// (A separate initializer, not a default argument: `init(data:)` must stay an exact match so that it is not
    /// ambiguous with Foundation's `XMLDocument(data:options:)`.)
    public init(data: Data) throws {
        try self.init(data: data, tree: .rendered)
    }

    /// Parses `data` as well-formed XML into `tree`. Throws `XMLParseError` on any well-formedness error.
    public init(data: Data, tree: Tree) throws {
        let builder = XMLTreeBuilder(tree: tree)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let ok = parser.parse()
        if !ok || builder.failure != nil {
            let error = builder.failure ?? parser.parserError
            throw XMLParseError(
                line: parser.lineNumber,
                column: parser.columnNumber,
                message: error?.localizedDescription ?? "unknown XML error"
            )
        }
        guard let root = builder.root else {
            throw XMLParseError(line: 0, column: 0, message: "no root element")
        }
        self.root = root
    }

    /// `true` when `data` parses as well-formed XML.
    public static func isWellFormed(_ data: Data) -> Bool {
        (try? XMLDocument(data: data)) != nil
    }
}

public struct XMLParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public let line: Int
    public let column: Int
    public let message: String

    public var description: String { "XML error at \(line):\(column): \(message)" }
}

public enum XMLNode: Sendable, Hashable {
    case element(XMLElement)
    case text(String)

    public var element: XMLElement? {
        if case .element(let e) = self { return e }
        return nil
    }

    public var text: String? {
        if case .text(let t) = self { return t }
        return nil
    }
}

public struct XMLAttribute: Sendable, Hashable {
    /// Local name.
    public var name: String
    public var prefix: String?
    public var namespaceURI: String?
    public var value: String

    public var qualifiedName: String {
        prefix.map { "\($0):\(name)" } ?? name
    }
}

public struct XMLElement: Sendable, Hashable {
    /// Local name.
    public var name: String
    public var prefix: String?
    public var namespaceURI: String?
    public var attributes: [XMLAttribute]
    public var children: [XMLNode]

    public init(name: String, prefix: String? = nil, namespaceURI: String? = nil, attributes: [XMLAttribute] = [], children: [XMLNode] = []) {
        self.name = name
        self.prefix = prefix
        self.namespaceURI = namespaceURI
        self.attributes = attributes
        self.children = children
    }

    public var qualifiedName: String {
        prefix.map { "\($0):\(name)" } ?? name
    }

    /// Value of the attribute with this local name (any namespace, or the given one).
    public func attribute(_ name: String, namespace: String? = nil) -> String? {
        attributes.first { $0.name == name && (namespace == nil || $0.namespaceURI == namespace) }?.value
    }

    public var id: String? { attribute("id") }

    public var childElements: [XMLElement] {
        children.compactMap(\.element)
    }

    public func childElements(named name: String, namespace: String? = nil) -> [XMLElement] {
        childElements.filter { $0.name == name && (namespace == nil || $0.namespaceURI == namespace) }
    }

    public func firstChild(named name: String, namespace: String? = nil) -> XMLElement? {
        childElements.first { $0.name == name && (namespace == nil || $0.namespaceURI == namespace) }
    }

    /// Concatenated text of all descendant text nodes.
    public var textContent: String {
        var out = ""
        appendText(to: &out)
        return out
    }

    private func appendText(to out: inout String) {
        for child in children {
            switch child {
            case .text(let t): out += t
            case .element(let e): e.appendText(to: &out)
            }
        }
    }

    /// Depth-first search for descendant elements (self excluded) matching `predicate`.
    public func descendants(where predicate: (XMLElement) -> Bool) -> [XMLElement] {
        var out: [XMLElement] = []
        collectDescendants(where: predicate, into: &out)
        return out
    }

    private func collectDescendants(where predicate: (XMLElement) -> Bool, into out: inout [XMLElement]) {
        for e in childElements {
            if predicate(e) { out.append(e) }
            e.collectDescendants(where: predicate, into: &out)
        }
    }

    public func firstDescendant(where predicate: (XMLElement) -> Bool) -> XMLElement? {
        for e in childElements {
            if predicate(e) { return e }
            if let found = e.firstDescendant(where: predicate) { return found }
        }
        return nil
    }
}

public enum XMLNamespace {
    public static let xhtml = "http://www.w3.org/1999/xhtml"
    public static let epub = "http://www.idpf.org/2007/ops"
    public static let opf = "http://www.idpf.org/2007/opf"
    public static let dc = "http://purl.org/dc/elements/1.1/"
    public static let container = "urn:oasis:names:tc:opendocument:xmlns:container"
    public static let svg = "http://www.w3.org/2000/svg"
    public static let mathml = "http://www.w3.org/1998/Math/MathML"
    public static let xlink = "http://www.w3.org/1999/xlink"
    public static let xml = "http://www.w3.org/XML/1998/namespace"
}

// MARK: - Builder

/// SAX delegate that builds the value tree. A mutable element stack is used while parsing; the result is
/// immutable once `parse()` returns.
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private final class Frame {
        var element: XMLElement
        var pendingText: String = ""
        init(element: XMLElement) { self.element = element }

        func flushText() {
            if !pendingText.isEmpty {
                if case .text(let last)? = element.children.last {
                    element.children[element.children.count - 1] = .text(last + pendingText)
                } else {
                    element.children.append(.text(pendingText))
                }
                pendingText = ""
            }
        }
    }

    private let tree: XMLDocument.Tree
    private var stack: [Frame] = []
    /// prefix → stack of URIs (innermost last)
    private var prefixMappings: [String: [String]] = [:]
    private(set) var root: XMLElement?
    private(set) var failure: Error?

    init(tree: XMLDocument.Tree) {
        self.tree = tree
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixMappings[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        if var uris = prefixMappings[prefix] {
            uris.removeLast()
            prefixMappings[prefix] = uris.isEmpty ? nil : uris
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.last?.flushText()
        let prefix: String? = {
            guard let q = qName, let colon = q.firstIndex(of: ":") else { return nil }
            return String(q[..<colon])
        }()
        var attributes: [XMLAttribute] = []
        attributes.reserveCapacity(attributeDict.count)
        // attributeDict is unordered; sort for a deterministic tree (attribute order is irrelevant to the DOM).
        for (key, value) in attributeDict.sorted(by: { $0.key < $1.key }) {
            if let colon = key.firstIndex(of: ":") {
                let p = String(key[..<colon])
                let local = String(key[key.index(after: colon)...])
                let uri: String? = p == "xml" ? XMLNamespace.xml : prefixMappings[p]?.last
                attributes.append(XMLAttribute(name: local, prefix: p, namespaceURI: uri, value: value))
            } else {
                attributes.append(XMLAttribute(name: key, prefix: nil, namespaceURI: nil, value: value))
            }
        }
        let element = XMLElement(
            name: elementName,
            prefix: prefix,
            namespaceURI: (namespaceURI?.isEmpty ?? true) ? nil : namespaceURI,
            attributes: attributes,
            children: []
        )
        stack.append(Frame(element: element))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        frame.flushText()
        if tree == .rendered, let parent = stack.last {
            let element = frame.element
            if element.name == "script", element.namespaceURI == XMLNamespace.xhtml || element.namespaceURI == XMLNamespace.svg {
                // Not in WebKit's DOM. The parent's text was flushed before the script started, so text after it
                // merges with the text before it on the next flush.
                return
            }
            if element.name == "template", element.namespaceURI == XMLNamespace.xhtml {
                frame.element.children = []
            }
            parent.element.children.append(.element(frame.element))
            return
        }
        if let parent = stack.last {
            parent.element.children.append(.element(frame.element))
        } else {
            root = frame.element
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.pendingText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.pendingText += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
        stack.last?.pendingText += whitespaceString
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = parseError }
    }
}
