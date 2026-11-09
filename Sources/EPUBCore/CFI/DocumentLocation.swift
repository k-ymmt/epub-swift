import Foundation

/// A node (and, for text, a UTF-16 offset) in an `XMLDocument`, addressed by child indices from the root element
/// (docs/design/01-core.md §5.3). `path` indexes `XMLElement.children`, so it counts text and element children
/// alike; an empty path is the root element itself.
public struct DocumentLocation: Hashable, Sendable {
    public var path: [Int]
    /// UTF-16 offset into the text node at `path`; nil when the location is an element.
    public var offset: Int?

    public init(path: [Int], offset: Int? = nil) {
        self.path = path
        self.offset = offset
    }
}

extension XMLDocument {
    /// The node at `path`, or nil when the path leaves the tree.
    public func node(at path: [Int]) -> XMLNode? {
        var node = XMLNode.element(root)
        for index in path {
            guard case .element(let element) = node, element.children.indices.contains(index) else { return nil }
            node = element.children[index]
        }
        return node
    }

    /// The element at `path`, or nil when the path does not end at an element.
    public func element(at path: [Int]) -> XMLElement? {
        node(at: path)?.element
    }

    /// Path of the first element with this `id` (document order), searched from the root.
    public func path(ofElementWithID id: String) -> [Int]? {
        func search(_ element: XMLElement, _ path: [Int]) -> [Int]? {
            for (i, child) in element.children.enumerated() {
                guard case .element(let e) = child else { continue }
                if e.id == id { return path + [i] }
                if let found = search(e, path + [i]) { return found }
            }
            return nil
        }
        if root.id == id { return [] }
        return search(root, [])
    }

    /// Every text node under `path` (or the root) in document order, with its path.
    public func textNodes(under path: [Int] = []) -> [(path: [Int], text: String)] {
        guard let start = element(at: path) else { return [] }
        var out: [(path: [Int], text: String)] = []
        func walk(_ element: XMLElement, _ path: [Int]) {
            for (i, child) in element.children.enumerated() {
                switch child {
                case .text(let t): out.append((path + [i], t))
                case .element(let e): walk(e, path + [i])
                }
            }
        }
        walk(start, path)
        return out
    }
}
