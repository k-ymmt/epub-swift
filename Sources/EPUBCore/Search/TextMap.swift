import Foundation

/// The searchable text of a content document and the mapping back to its nodes (docs/design/01-core.md §6.1).
///
/// Text nodes under `body` are concatenated in document order, skipping `rt` / `rp` (ruby annotations), `script`,
/// `style`, `template` and `head`. A newline is inserted at block boundaries so that a snippet never crosses them.
/// Offsets are UTF-16 code units, like `NSString` ranges and CFI character offsets.
public struct TextMap: Sendable, Hashable {
    /// A run of `text` that comes from one text node.
    public struct Segment: Sendable, Hashable {
        /// Child path of the text node (`DocumentLocation.path`).
        public let path: [Int]
        /// UTF-16 range in `text`.
        public let range: Range<Int>
    }

    public let text: String
    public let segments: [Segment]
    /// Characters as `TextLength` counts them: whitespace runs collapsed to one, none at the ends.
    public let collapsedCharacterCount: Int

    static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "dl", "dt", "dd", "td", "th", "tr", "table",
        "blockquote", "pre", "br", "hr", "section", "article", "aside", "header", "footer", "nav", "figure", "figcaption",
        "body", "address", "fieldset", "legend", "details", "summary", "main",
    ]

    public init(document: XMLDocument, excluding excluded: Set<String> = TextLength.excludedElements) {
        let root = document.root
        var text = ""
        var utf16Length = 0
        var segments: [Segment] = []
        var collapsed = 0
        var pendingWhitespace = false
        var hasText = false

        func appendNewline() {
            if utf16Length > 0, !text.hasSuffix("\n") {
                text.append("\n")
                utf16Length += 1
            }
        }

        func visit(_ element: XMLElement, _ path: [Int]) {
            if excluded.contains(element.name) { return }
            let isBlock = TextMap.blockElements.contains(element.name)
            if isBlock { appendNewline() }
            for (i, child) in element.children.enumerated() {
                switch child {
                case .text(let t):
                    guard !t.isEmpty else { continue }
                    let start = utf16Length
                    text.append(t)
                    utf16Length += t.utf16.count
                    segments.append(Segment(path: path + [i], range: start..<utf16Length))
                    for scalar in t.unicodeScalars {
                        if scalar.properties.isWhitespace {
                            pendingWhitespace = true
                        } else {
                            if pendingWhitespace && hasText { collapsed += 1 }
                            pendingWhitespace = false
                            hasText = true
                            collapsed += 1
                        }
                    }
                case .element(let e):
                    visit(e, path + [i])
                }
            }
            if isBlock { appendNewline() }
        }

        if let bodyIndex = root.children.firstIndex(where: { $0.element?.name == "body" }), let body = root.children[bodyIndex].element {
            visit(body, [bodyIndex])
        } else {
            visit(root, [])
        }
        self.text = text
        self.segments = segments
        self.collapsedCharacterCount = collapsed
    }

    /// The text node and in-node offset at a UTF-16 offset of `text`. Offsets inside an inserted newline map to
    /// the end of the preceding segment. nil when the map is empty.
    public func location(ofUTF16Offset offset: Int) -> DocumentLocation? {
        guard !segments.isEmpty else { return nil }
        // Binary search for the last segment starting at or before `offset`.
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].range.lowerBound <= offset { low = mid } else { high = mid - 1 }
        }
        let segment = segments[low]
        if offset < segment.range.lowerBound {
            return DocumentLocation(path: segment.path, offset: 0)
        }
        return DocumentLocation(path: segment.path, offset: min(offset, segment.range.upperBound) - segment.range.lowerBound)
    }

    /// The UTF-16 offset in `text` of a text location, or nil when the node is not part of the map.
    public func utf16Offset(of location: DocumentLocation) -> Int? {
        guard let segment = segments.first(where: { $0.path == location.path }) else { return nil }
        return segment.range.lowerBound + min(location.offset ?? 0, segment.range.count)
    }
}
