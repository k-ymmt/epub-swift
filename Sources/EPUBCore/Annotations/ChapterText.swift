import Foundation

// The two trees of a chapter that selectors and CFIs are counted on (06-annotations §5 step 4):
// - `.source`: every element as written (the DOM a Reading System that runs scripts builds). Exchange selectors
//   (`nth-child`, `textContent` positions, quotes) count this tree.
// - `.rendered`: WebKit's DOM with content JavaScript off, without `script` elements and `template` children. CFIs
//   count this tree.
// `.rendered` is `.source` minus some elements, with the text on both sides of a removed `script` merged, so the
// nodes correspond one to one (a rendered text node may be several source text nodes).

/// Document order of two paths in the same tree: an ancestor comes before its descendants.
func comparePaths(_ a: [Int], _ b: [Int]) -> Int {
    for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
    if a.count == b.count { return 0 }
    return a.count < b.count ? -1 : 1
}

/// Which way to go when a position sits on a boundary between two text nodes (or must be moved off text that the
/// other tree does not have): a range start goes forward, a range end backward, so the range covers no extra text.
enum Bias {
    case forward, backward
}

/// The text nodes of a tree in document order, with cumulative offsets in Unicode code points (selectors) and
/// UTF-16 code units (CFIs).
struct TextIndex {
    struct Node {
        var path: [Int]
        var text: String
        var scalarStart: Int
        var scalarCount: Int
        var utf16Start: Int
        var utf16Count: Int
    }

    let nodes: [Node]
    let totalScalars: Int

    init(_ document: XMLDocument) {
        var nodes: [Node] = []
        var scalars = 0
        var utf16 = 0
        for (path, text) in document.textNodes() {
            let s = text.unicodeScalars.count
            let u = text.utf16.count
            nodes.append(Node(path: path, text: text, scalarStart: scalars, scalarCount: s, utf16Start: utf16, utf16Count: u))
            scalars += s
            utf16 += u
        }
        self.nodes = nodes
        self.totalScalars = scalars
    }

    /// Index of the first node at or after `path` in document order (the nodes inside an element come after it).
    func firstNode(atOrAfter path: [Int]) -> Int {
        var lo = 0, hi = nodes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if comparePaths(nodes[mid].path, path) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index of the node holding code point `scalar` (the last node for the end of the text).
    func firstNodeContaining(scalar: Int) -> Int {
        var lo = 0, hi = nodes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if nodes[mid].scalarStart + nodes[mid].scalarCount <= scalar { lo = mid + 1 } else { hi = mid }
        }
        return min(lo, max(0, nodes.count - 1))
    }

    /// The nodes inside the element at `path`.
    func nodeRange(under path: [Int]) -> Range<Int> {
        let start = firstNode(atOrAfter: path)
        var end = start
        while end < nodes.count, nodes[end].path.starts(with: path) { end += 1 }
        return start..<end
    }

    func nodeIndex(ofPath path: [Int]) -> Int? {
        let i = firstNode(atOrAfter: path)
        return i < nodes.count && nodes[i].path == path ? i : nil
    }

    /// Code points of text before `location` (a text node and UTF-16 offset, or an element: the text before it).
    func scalarOffset(of location: DocumentLocation) -> Int? {
        if let offset = location.offset {
            guard let i = nodeIndex(ofPath: location.path) else { return nil }
            let node = nodes[i]
            return node.scalarStart + Self.scalars(inUTF16Prefix: offset, of: node.text)
        }
        let i = firstNode(atOrAfter: location.path)
        return i < nodes.count ? nodes[i].scalarStart : totalScalars
    }

    /// UTF-16 code units of text before `location`.
    func utf16Offset(of location: DocumentLocation) -> Int? {
        if let offset = location.offset {
            guard let i = nodeIndex(ofPath: location.path) else { return nil }
            return nodes[i].utf16Start + min(offset, nodes[i].utf16Count)
        }
        let i = firstNode(atOrAfter: location.path)
        return i < nodes.count ? nodes[i].utf16Start : (nodes.last.map { $0.utf16Start + $0.utf16Count } ?? 0)
    }

    /// The location `scalar` code points into the whole text, restricted to `range` of nodes. On a boundary
    /// between two nodes `.forward` picks the start of the later one and `.backward` the end of the earlier one.
    /// nil when the offset is past the text of the range; an element location of `emptyElement` when the range has no
    /// text and the offset is 0 at its start.
    func location(atScalar scalar: Int, in range: Range<Int>, bias: Bias, emptyElement: [Int]? = nil) -> DocumentLocation? {
        guard !range.isEmpty else {
            return emptyElement.map { DocumentLocation(path: $0) }
        }
        let first = nodes[range.lowerBound]
        let last = nodes[range.upperBound - 1]
        guard scalar >= first.scalarStart, scalar <= last.scalarStart + last.scalarCount else { return nil }
        var chosen = range.upperBound - 1
        for i in range {
            let end = nodes[i].scalarStart + nodes[i].scalarCount
            if bias == .forward ? scalar < end : scalar <= end { chosen = i; break }
        }
        let node = nodes[chosen]
        return DocumentLocation(path: node.path, offset: Self.utf16(inScalarPrefix: scalar - node.scalarStart, of: node.text))
    }

    /// The location `utf16` code units into the whole text (same boundary rules as `location(atScalar:…)`).
    func location(atUTF16 utf16: Int, bias: Bias) -> DocumentLocation? {
        guard let last = nodes.last, utf16 >= 0, utf16 <= last.utf16Start + last.utf16Count else { return nil }
        var chosen = nodes.count - 1
        for (i, node) in nodes.enumerated() {
            let end = node.utf16Start + node.utf16Count
            if bias == .forward ? utf16 < end : utf16 <= end { chosen = i; break }
        }
        return DocumentLocation(path: nodes[chosen].path, offset: utf16 - nodes[chosen].utf16Start)
    }

    /// The code points of the text of nodes `range`.
    func scalars(in range: Range<Int>) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for i in range { out.append(contentsOf: nodes[i].text.unicodeScalars) }
        return out
    }

    static func scalars(inUTF16Prefix offset: Int, of text: String) -> Int {
        var units = 0
        var count = 0
        for scalar in text.unicodeScalars {
            if units >= offset { break }
            units += UTF16.width(scalar)
            count += 1
        }
        return count
    }

    static func utf16(inScalarPrefix count: Int, of text: String) -> Int {
        var units = 0
        for (k, scalar) in text.unicodeScalars.enumerated() {
            if k >= count { break }
            units += UTF16.width(scalar)
        }
        return units
    }
}

/// Correspondence between a chapter's `.rendered` and `.source` trees.
struct TreeCorrespondence {
    struct Segment {
        var sourcePath: [Int]
        /// UTF-16 offset of this source text node within the rendered text node.
        var renderedOffset: Int
        var length: Int
    }

    /// Rendered text node → the source text nodes it merges, in order.
    private(set) var segments: [[Int]: [Segment]] = [:]
    /// Rendered element → source element.
    private(set) var renderedElementToSource: [[Int]: [Int]] = [[]: []]
    /// Source text node → (rendered text node, offset of its first code unit in it).
    private(set) var sourceTextToRendered: [[Int]: (path: [Int], offset: Int)] = [:]
    /// Source element → rendered element (absent for removed elements and template contents).
    private(set) var sourceElementToRendered: [[Int]: [Int]] = [[]: []]

    init(rendered: XMLDocument, source: XMLDocument) {
        walk(rendered.root, [], source.root, [])
    }

    static func isRemoved(_ element: XMLElement) -> Bool {
        element.name == "script" && (element.namespaceURI == XMLNamespace.xhtml || element.namespaceURI == XMLNamespace.svg)
    }

    private mutating func walk(_ rendered: XMLElement, _ renderedPath: [Int], _ source: XMLElement, _ sourcePath: [Int]) {
        // Template contents are not in the rendered tree.
        if source.name == "template", source.namespaceURI == XMLNamespace.xhtml { return }
        var r = 0
        // The rendered text node collecting source text while only removed elements come between.
        var open: (index: Int, length: Int)?
        for (s, child) in source.children.enumerated() {
            switch child {
            case .text(let text):
                if let current = open {
                    let path = renderedPath + [current.index]
                    segments[path, default: []].append(Segment(sourcePath: sourcePath + [s], renderedOffset: current.length, length: text.utf16.count))
                    sourceTextToRendered[sourcePath + [s]] = (path, current.length)
                    open = (current.index, current.length + text.utf16.count)
                } else {
                    guard r < rendered.children.count, case .text = rendered.children[r] else { return }
                    let path = renderedPath + [r]
                    segments[path] = [Segment(sourcePath: sourcePath + [s], renderedOffset: 0, length: text.utf16.count)]
                    sourceTextToRendered[sourcePath + [s]] = (path, 0)
                    open = (r, text.utf16.count)
                    r += 1
                }
            case .element(let element):
                if Self.isRemoved(element) { continue }
                open = nil
                guard r < rendered.children.count, case .element(let renderedChild) = rendered.children[r] else { return }
                renderedElementToSource[renderedPath + [r]] = sourcePath + [s]
                sourceElementToRendered[sourcePath + [s]] = renderedPath + [r]
                walk(renderedChild, renderedPath + [r], element, sourcePath + [s])
                r += 1
            }
        }
    }

    /// The source location of a rendered location. On the boundary between two merged source nodes (where a
    /// `script` was), `.forward` gives the start of the later node and `.backward` the end of the earlier.
    func sourceLocation(forRendered location: DocumentLocation, bias: Bias) -> DocumentLocation? {
        guard let offset = location.offset else {
            return renderedElementToSource[location.path].map { DocumentLocation(path: $0) }
        }
        guard let list = segments[location.path], !list.isEmpty else { return nil }
        var chosen = list[list.count - 1]
        for (k, segment) in list.enumerated() {
            let end = segment.renderedOffset + segment.length
            if offset < end || (offset == end && (bias == .backward || k == list.count - 1)) {
                chosen = segment
                break
            }
        }
        return DocumentLocation(path: chosen.sourcePath, offset: max(0, min(offset - chosen.renderedOffset, chosen.length)))
    }

    /// The rendered location of a source location. A location inside text the rendered tree does not have (a
    /// script, template contents) moves to the nearest rendered text in `bias` direction, using `sourceText`.
    func renderedLocation(forSource location: DocumentLocation, bias: Bias, sourceText: TextIndex) -> DocumentLocation? {
        if let offset = location.offset {
            if let mapped = sourceTextToRendered[location.path] {
                return DocumentLocation(path: mapped.path, offset: mapped.offset + offset)
            }
        } else if let mapped = sourceElementToRendered[location.path] {
            return DocumentLocation(path: mapped)
        }
        // Not in the rendered tree: the nearest mapped text node.
        var i = sourceText.firstNode(atOrAfter: location.path)
        if location.offset != nil, i < sourceText.nodes.count, sourceText.nodes[i].path == location.path, bias == .forward { i += 1 }
        switch bias {
        case .forward:
            while i < sourceText.nodes.count {
                if let mapped = sourceTextToRendered[sourceText.nodes[i].path] {
                    return DocumentLocation(path: mapped.path, offset: mapped.offset)
                }
                i += 1
            }
        case .backward:
            i -= 1
            while i >= 0 {
                let node = sourceText.nodes[i]
                if let mapped = sourceTextToRendered[node.path] {
                    return DocumentLocation(path: mapped.path, offset: mapped.offset + node.utf16Count)
                }
                i -= 1
            }
        }
        return nil
    }
}

/// One chapter opened for selector work: both trees, their text, and the correspondence.
struct ChapterText {
    let spineIndex: Int
    let spineSteps: [CFI.Step]
    let rendered: XMLDocument
    let source: XMLDocument
    let renderedText: TextIndex
    let sourceText: TextIndex
    let correspondence: TreeCorrespondence
    /// The source `body` element (or the root for documents without one, such as SVG).
    let bodyPath: [Int]
    /// Number of elements per `id` in the source tree (an id is only used in a CssSelector when unique).
    let idCounts: [String: Int]
    /// Code points of the body's `textContent` (source tree).
    let body: [Unicode.Scalar]
    /// Code points of text before the start of the body.
    let bodyStart: Int

    init?(data: Data, spineIndex: Int, spineSteps: [CFI.Step]) {
        guard let rendered = try? XMLDocument(data: data, tree: .rendered),
              let source = try? XMLDocument(data: data, tree: .source) else { return nil }
        self.spineIndex = spineIndex
        self.spineSteps = spineSteps
        self.rendered = rendered
        self.source = source
        self.renderedText = TextIndex(rendered)
        self.sourceText = TextIndex(source)
        self.correspondence = TreeCorrespondence(rendered: rendered, source: source)
        if let body = source.root.children.firstIndex(where: { $0.element?.name == "body" }) {
            bodyPath = [body]
        } else {
            bodyPath = []
        }
        var counts: [String: Int] = [:]
        func count(_ element: XMLElement) {
            if let id = element.id, !id.isEmpty { counts[id, default: 0] += 1 }
            for child in element.childElements { count(child) }
        }
        count(source.root)
        idCounts = counts
        let bodyRange = sourceText.nodeRange(under: bodyPath)
        body = sourceText.scalars(in: bodyRange)
        bodyStart = sourceText.scalarOffset(of: DocumentLocation(path: bodyPath)) ?? 0
    }

    /// The source text between two code-point offsets into the whole text.
    func sourceString(_ range: Range<Int>) -> String {
        var out = String.UnicodeScalarView()
        let first = sourceText.firstNodeContaining(scalar: range.lowerBound)
        for node in sourceText.nodes[first...] {
            if node.scalarStart >= range.upperBound { break }
            let lower = max(range.lowerBound, node.scalarStart) - node.scalarStart
            let upper = min(range.upperBound, node.scalarStart + node.scalarCount) - node.scalarStart
            guard lower < upper else { continue }
            let scalars = node.text.unicodeScalars
            let from = scalars.index(scalars.startIndex, offsetBy: lower)
            let to = scalars.index(from, offsetBy: upper - lower)
            out.append(contentsOf: scalars[from..<to])
        }
        return String(out)
    }
}
