import Foundation
import libxml2

/// How a content document is served (docs/design/01-core.md §4.1, 02-rendering §3.3).
public enum ContentDocumentState: Sendable, Hashable {
    /// Well-formed XML. The ZIP bytes are served untouched.
    case wellFormed
    /// Not well-formed; recovered with libxml2's HTML parser and re-serialized as well-formed XML.
    case repaired
    /// Not well-formed and the repaired output still did not parse as XML. The original bytes are served as
    /// `text/html`; position accuracy is given up for this document.
    case unrepairable
}

/// A spine document ready to be served by the scheme handler.
public struct ContentDocument: Sendable {
    public let path: String
    public let data: Data
    /// `application/xhtml+xml`, or `text/html` for `.unrepairable`.
    public let mediaType: String
    public let state: ContentDocumentState
    public let warnings: [PublicationWarning]

    public var isXML: Bool { mediaType != "text/html" }
}

/// Best-effort repair of XHTML that is not well-formed XML (docs/design/01-core.md §4.1).
///
/// 1. If `XMLParser` accepts the document, it is served as is.
/// 2. Otherwise libxml2's HTML parser recovers a tree, the root namespace and prefixed attributes get their
///    `xmlns` declarations, SVG / MathML names get their case back, and the tree is serialized with
///    `XML_SAVE_AS_XML`.
/// 3. The result is validated with `XMLParser` again. If it still fails the original is served as `text/html`.
public enum XHTMLRepair {
    public static let xhtmlMediaType = "application/xhtml+xml"
    public static let htmlMediaType = "text/html"

    /// Prepares the bytes of a spine item for serving.
    public static func prepare(_ data: Data, path: String) -> ContentDocument {
        prepareAndParse(data, path: path).document
    }

    /// `prepare` plus the parsed tree of the bytes that will be served (nil for the `text/html` fallback), so that
    /// callers who need the DOM (character counts, search) do not parse twice.
    public static func prepareAndParse(_ data: Data, path: String) -> (document: ContentDocument, tree: XMLDocument?) {
        if let tree = try? XMLDocument(data: data) {
            // Served bytes are always UTF-8 (the injector and the scheme handler work on UTF-8 text); a well-formed
            // UTF-16 document is transcoded, which leaves its DOM unchanged.
            if let utf8 = transcodedToUTF8(data), let utf8Tree = try? XMLDocument(data: utf8) {
                return (ContentDocument(path: path, data: utf8, mediaType: xhtmlMediaType, state: .wellFormed, warnings: []), utf8Tree)
            }
            return (ContentDocument(path: path, data: data, mediaType: xhtmlMediaType, state: .wellFormed, warnings: []), tree)
        }
        let warning = PublicationWarning.malformedXHTML(path: path)
        if let repaired = repair(data), let tree = try? XMLDocument(data: repaired) {
            return (ContentDocument(path: path, data: repaired, mediaType: xhtmlMediaType, state: .repaired, warnings: [warning]), tree)
        }
        return (ContentDocument(path: path, data: data, mediaType: htmlMediaType, state: .unrepairable, warnings: [warning]), nil)
    }

    /// Recovers `data` with libxml2's HTML parser and serializes the tree as XML. Returns nil if the parser
    /// produced no document. The caller validates the result.
    public static func repair(_ data: Data) -> Data? {
        let source = decodeToUTF8(data)
        // Implied html/head/body stay (no NOIMPLIED): WebKit's XML DOM needs them as real elements.
        let options = Int32(
            HTML_PARSE_RECOVER.rawValue
                | HTML_PARSE_NOERROR.rawValue
                | HTML_PARSE_NOWARNING.rawValue
                | HTML_PARSE_NONET.rawValue
                | HTML_PARSE_NODEFDTD.rawValue
        )
        let doc: htmlDocPtr? = source.withCString { cString in
            htmlReadMemory(cString, Int32(strlen(cString)), "document.xhtml", "UTF-8", options)
        }
        guard let doc else { return nil }
        defer { xmlFreeDoc(doc) }
        guard let root = xmlDocGetRootElement(doc) else { return nil }
        removeXMLDeclarationPI(doc)

        fixNamespaces(root: root)
        fixForeignNames(root: root)

        guard let buffer = xmlBufferCreate() else { return nil }
        defer { xmlBufferFree(buffer) }
        let saveOptions = Int32(XML_SAVE_AS_XML.rawValue)
        guard let ctxt = xmlSaveToBuffer(buffer, "UTF-8", saveOptions) else { return nil }
        let saved = xmlSaveDoc(ctxt, doc)
        xmlSaveClose(ctxt)
        guard saved >= 0, let content = xmlBufferContent(buffer) else { return nil }
        let length = Int(xmlBufferLength(buffer))
        return Data(bytes: content, count: length)
    }

    // MARK: - Namespaces

    private static let knownPrefixes: [String: String] = [
        "epub": XMLNamespace.epub,
        "xlink": XMLNamespace.xlink,
        "svg": XMLNamespace.svg,
        "m": XMLNamespace.mathml,
        "mml": XMLNamespace.mathml,
        "math": XMLNamespace.mathml,
        "ops": XMLNamespace.epub,
        "xsi": "http://www.w3.org/2001/XMLSchema-instance",
        "dc": XMLNamespace.dc,
        "dcterms": "http://purl.org/dc/terms/",
        "ibooks": "http://vocabulary.itunes.apple.com/rdf/ibooks/vocabulary-extensions-1.0/",
    ]

    /// The HTML parser knows nothing about namespaces: `xmlns` survives only as a plain attribute and prefixed
    /// names are plain names containing a colon. Make the output namespace-well-formed:
    /// - the root gets `xmlns="http://www.w3.org/1999/xhtml"` if it has no `xmlns`;
    /// - every prefix used by an element or attribute is declared on the root (URI from a declaration found
    ///   anywhere in the document, else from a table of well-known prefixes);
    /// - prefixes that cannot be resolved are stripped from the name;
    /// - `svg` / `math` elements without `xmlns` get their namespace.
    private static func fixNamespaces(root: xmlNodePtr) {
        if attributeValue(root, "xmlns") == nil {
            xmlNewProp(root, "xmlns", XMLNamespace.xhtml)
        }
        var declared: [String: String] = [:]
        var usedPrefixes: Set<String> = []
        var elementsToRename: [(xmlNodePtr, String)] = []
        var attributesToRename: [(xmlNodePtr, String, String)] = []  // (element, oldName, newName)

        forEachElement(root) { node in
            let name = nodeName(node)
            if let colon = name.firstIndex(of: ":") {
                let prefix = String(name[..<colon])
                if prefix != "xml" { usedPrefixes.insert(prefix) }
            }
            if name == "svg", attributeValue(node, "xmlns") == nil {
                xmlNewProp(node, "xmlns", XMLNamespace.svg)
            } else if name == "math", attributeValue(node, "xmlns") == nil {
                xmlNewProp(node, "xmlns", XMLNamespace.mathml)
            }
            var attr = node.pointee.properties
            while let a = attr {
                let attrName = String(cString: a.pointee.name)
                if attrName.hasPrefix("xmlns:") {
                    let prefix = String(attrName.dropFirst("xmlns:".count))
                    if let value = attributeValue(node, attrName), declared[prefix] == nil {
                        declared[prefix] = value
                    }
                } else if let colon = attrName.firstIndex(of: ":") {
                    let prefix = String(attrName[..<colon])
                    if prefix != "xml" && prefix != "xmlns" { usedPrefixes.insert(prefix) }
                }
                attr = a.pointee.next
            }
        }

        var rootDeclared: Set<String> = []
        var attr = root.pointee.properties
        while let a = attr {
            let attrName = String(cString: a.pointee.name)
            if attrName.hasPrefix("xmlns:") { rootDeclared.insert(String(attrName.dropFirst("xmlns:".count))) }
            attr = a.pointee.next
        }

        var unresolved: Set<String> = []
        for prefix in usedPrefixes.sorted() where !rootDeclared.contains(prefix) {
            if let uri = declared[prefix] ?? knownPrefixes[prefix] {
                xmlNewProp(root, "xmlns:\(prefix)", uri)
            } else {
                unresolved.insert(prefix)
            }
        }
        guard !unresolved.isEmpty else { return }

        forEachElement(root) { node in
            let name = nodeName(node)
            if let colon = name.firstIndex(of: ":"), unresolved.contains(String(name[..<colon])) {
                elementsToRename.append((node, String(name[name.index(after: colon)...])))
            }
            var attr = node.pointee.properties
            while let a = attr {
                let attrName = String(cString: a.pointee.name)
                if let colon = attrName.firstIndex(of: ":"), unresolved.contains(String(attrName[..<colon])) {
                    attributesToRename.append((node, attrName, String(attrName[attrName.index(after: colon)...])))
                }
                attr = a.pointee.next
            }
        }
        for (node, newName) in elementsToRename {
            xmlNodeSetName(node, newName)
        }
        for (node, oldName, newName) in attributesToRename {
            renameAttribute(node, from: oldName, to: newName)
        }
    }

    // MARK: - SVG / MathML case

    /// From the HTML Standard's "SVG element name adjustments" table.
    static let svgElementNames: [String: String] = Dictionary(uniqueKeysWithValues: [
        "altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform", "clipPath",
        "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting",
        "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR",
        "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset", "fePointLight",
        "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "foreignObject", "glyphRef", "linearGradient",
        "radialGradient", "textPath",
    ].map { ($0.lowercased(), $0) })

    /// From the HTML Standard's "SVG attribute name adjustments" table.
    static let svgAttributeNames: [String: String] = Dictionary(uniqueKeysWithValues: [
        "attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits",
        "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits",
        "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust",
        "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits",
        "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX",
        "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY",
        "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant",
        "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale",
        "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget", "xChannelSelector",
        "yChannelSelector", "zoomAndPan",
    ].map { ($0.lowercased(), $0) })

    private static func fixForeignNames(root: xmlNodePtr) {
        fixForeignNames(node: root, inSVG: false, inMathML: false)
    }

    private static func fixForeignNames(node: xmlNodePtr, inSVG: Bool, inMathML: Bool) {
        var inSVG = inSVG
        var inMathML = inMathML
        let name = nodeName(node)
        if name == "svg" { inSVG = true; inMathML = false }
        if name == "math" { inMathML = true; inSVG = false }
        if inSVG {
            if let canonical = svgElementNames[name], canonical != name {
                xmlNodeSetName(node, canonical)
            }
            var renames: [(String, String)] = []
            var attr = node.pointee.properties
            while let a = attr {
                let attrName = String(cString: a.pointee.name)
                if let canonical = svgAttributeNames[attrName], canonical != attrName {
                    renames.append((attrName, canonical))
                }
                attr = a.pointee.next
            }
            for (old, new) in renames { renameAttribute(node, from: old, to: new) }
        } else if inMathML {
            if attributeValue(node, "definitionurl") != nil {
                renameAttribute(node, from: "definitionurl", to: "definitionURL")
            }
        }
        var child = node.pointee.children
        while let c = child {
            if c.pointee.type == XML_ELEMENT_NODE {
                fixForeignNames(node: c, inSVG: inSVG, inMathML: inMathML)
            }
            child = c.pointee.next
        }
    }

    // MARK: - libxml2 helpers

    /// The HTML parser keeps a leading `<?xml ...?>` as a processing instruction named `xml`, which is not
    /// allowed in XML output (and would be emitted after the doctype). Drop such nodes at document level.
    private static func removeXMLDeclarationPI(_ doc: xmlDocPtr) {
        var child = doc.pointee.children
        while let c = child {
            let next = c.pointee.next
            if c.pointee.type == XML_PI_NODE, let name = c.pointee.name, String(cString: name).lowercased() == "xml" {
                xmlUnlinkNode(c)
                xmlFreeNode(c)
            }
            child = next
        }
    }

    private static func nodeName(_ node: xmlNodePtr) -> String {
        guard let name = node.pointee.name else { return "" }
        return String(cString: name)
    }

    private static func attributeValue(_ node: xmlNodePtr, _ name: String) -> String? {
        guard let value = xmlGetProp(node, name) else { return nil }
        defer { free(value) } // libxml2 uses malloc by default
        return String(cString: value)
    }

    private static func renameAttribute(_ node: xmlNodePtr, from oldName: String, to newName: String) {
        guard let value = attributeValue(node, oldName) else { return }
        xmlUnsetProp(node, oldName)
        if attributeValue(node, newName) == nil {
            xmlNewProp(node, newName, value)
        }
    }

    private static func forEachElement(_ root: xmlNodePtr, _ body: (xmlNodePtr) -> Void) {
        var stack: [xmlNodePtr] = [root]
        while let node = stack.popLast() {
            body(node)
            var child = node.pointee.children
            var children: [xmlNodePtr] = []
            while let c = child {
                if c.pointee.type == XML_ELEMENT_NODE { children.append(c) }
                child = c.pointee.next
            }
            stack.append(contentsOf: children.reversed())
        }
    }

    /// Whether `data` starts with a UTF-16 byte order mark (EPUB 3 allows only UTF-8 and UTF-16).
    private static func hasUTF16BOM(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
        return (b0 == 0xFE && b1 == 0xFF) || (b0 == 0xFF && b1 == 0xFE)
    }

    /// UTF-8 bytes of a UTF-16 (BOM) document with its XML declaration replaced by a UTF-8 one; nil for any other
    /// input (already UTF-8).
    static func transcodedToUTF8(_ data: Data) -> Data? {
        guard hasUTF16BOM(data), let text = String(data: data, encoding: .utf16) else { return nil }
        let body = stripXMLDeclaration(text).drop(while: { $0 == "\u{FEFF}" })
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + body).utf8)
    }

    /// libxml2's HTML parser is told the input is UTF-8; transcode UTF-16 input (BOM) first.
    private static func decodeToUTF8(_ data: Data) -> String {
        var text: String
        if hasUTF16BOM(data), let utf16 = String(data: data, encoding: .utf16) {
            text = utf16
        } else {
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        text = stripXMLDeclaration(text)
        return text
    }

    /// Removes a leading XML declaration; the output gets a fresh one from the serializer.
    private static func stripXMLDeclaration(_ s: String) -> String {
        let trimmedStart = s.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        // `<?xml` followed by whitespace: `<?xml-stylesheet …?>` is a processing instruction that must stay.
        guard trimmedStart.hasPrefix("<?xml"), trimmedStart.dropFirst(5).first?.isWhitespace == true,
              let end = trimmedStart.range(of: "?>") else { return s }
        return String(trimmedStart[end.upperBound...])
    }
}
