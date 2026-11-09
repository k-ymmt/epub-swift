import Foundation

/// Resolves CFIs to `DocumentLocation`s on the Core DOM (docs/design/01-core.md §5.3).
///
/// Element steps follow the index, except that an ID assertion wins when the indexed element does not carry
/// that id (the element with the id is looked up anywhere in the document). A text assertion is checked against
/// the resolved text; on a mismatch (or when the structural resolution fails) the document's text is searched for
/// `before + after` and the occurrence nearest to the structural position is used. The same algorithm runs in
/// `reader.js` on the live DOM.
public enum CFIResolver {
    public struct Resolution: Hashable, Sendable {
        public var location: DocumentLocation
        /// `true` when the position came from the text assertion rather than the steps.
        public var usedTextAssertion: Bool
    }

    public static func resolve(_ cfi: CFI, in document: XMLDocument) -> DocumentLocation? {
        resolution(of: cfi, in: document)?.location
    }

    public static func resolution(of cfi: CFI, in document: XMLDocument) -> Resolution? {
        let structural = resolveSteps(cfi.steps, offset: cfi.characterOffset, in: document)
        guard let assertion = cfi.textAssertion, !assertion.isEmpty else {
            return structural.map { Resolution(location: $0, usedTextAssertion: false) }
        }
        if let structural, matches(assertion, at: structural, in: document) {
            return Resolution(location: structural, usedTextAssertion: false)
        }
        if let repaired = search(assertion, near: structural, in: document) {
            return Resolution(location: repaired, usedTextAssertion: true)
        }
        return structural.map { Resolution(location: $0, usedTextAssertion: false) }
    }

    // MARK: - Steps

    /// Follows the steps. Returns nil when a step cannot be satisfied (including a text step with no text node).
    static func resolveSteps(_ steps: [CFI.Step], offset: Int?, in document: XMLDocument) -> DocumentLocation? {
        var path: [Int] = []
        var element = document.root
        for (position, step) in steps.enumerated() {
            if step.isElement {
                let elements = element.children.enumerated().filter { $0.element.element != nil }
                let k = step.index / 2 - 1
                var chosen: (offset: Int, element: XMLElement)? = nil
                if elements.indices.contains(k), k >= 0 {
                    let candidate = elements[k]
                    chosen = (candidate.offset, candidate.element.element!)
                }
                if let id = step.id, chosen?.element.id != id {
                    if let found = document.path(ofElementWithID: id), let e = document.element(at: found) {
                        path = found
                        element = e
                        continue
                    }
                }
                guard let chosen else { return nil }
                path.append(chosen.offset)
                element = chosen.element
            } else {
                guard position == steps.count - 1 else { return nil } // text steps are terminal
                let n = (step.index - 1) / 2
                var elementsSeen = 0
                var textIndex: Int?
                for (i, child) in element.children.enumerated() {
                    switch child {
                    case .element:
                        elementsSeen += 1
                    case .text:
                        if elementsSeen == n { textIndex = i }
                    }
                    if elementsSeen > n { break }
                }
                guard let textIndex, case .text(let text) = element.children[textIndex] else { return nil }
                path.append(textIndex)
                return DocumentLocation(path: path, offset: min(max(0, offset ?? 0), text.utf16.count))
            }
        }
        if offset != nil {
            // An offset on an element step: treat it as offset 0 of the element's first text (rare, tolerated).
            return DocumentLocation(path: path, offset: nil)
        }
        return DocumentLocation(path: path, offset: nil)
    }

    // MARK: - Text assertion

    static func matches(_ assertion: CFI.TextAssertion, at location: DocumentLocation, in document: XMLDocument) -> Bool {
        guard let offset = location.offset, case .text(let text)? = document.node(at: location.path) else { return false }
        let utf16 = Array(text.utf16)
        let before = Array(assertion.before.utf16)
        let after = Array(assertion.after.utf16)
        guard offset - before.count >= 0, offset + after.count <= utf16.count else { return false }
        return Array(utf16[(offset - before.count)..<offset]) == before && Array(utf16[offset..<(offset + after.count)]) == after
    }

    /// Finds `before + after` in the concatenated text of the document and returns the location of the boundary
    /// between them, choosing the occurrence nearest to `near` when there are several.
    static func search(_ assertion: CFI.TextAssertion, near: DocumentLocation?, in document: XMLDocument) -> DocumentLocation? {
        let nodes = document.textNodes()
        guard !nodes.isEmpty else { return nil }
        var starts: [Int] = []
        var combined: [UInt16] = []
        for node in nodes {
            starts.append(combined.count)
            combined.append(contentsOf: node.text.utf16)
        }
        let needle = Array((assertion.before + assertion.after).utf16)
        guard !needle.isEmpty, needle.count <= combined.count else { return nil }
        var candidates: [Int] = []
        var i = 0
        while i + needle.count <= combined.count {
            if combined[i] == needle[0], Array(combined[i..<(i + needle.count)]) == needle {
                candidates.append(i + assertion.before.utf16.count)
            }
            i += 1
        }
        guard !candidates.isEmpty else { return nil }
        var target = candidates[0]
        if let near, let nearIndex = nodes.firstIndex(where: { $0.path == near.path }) {
            let nearGlobal = starts[nearIndex] + (near.offset ?? 0)
            target = candidates.min { abs($0 - nearGlobal) < abs($1 - nearGlobal) } ?? target
        }
        // Map the global offset back to a node. A boundary at the end of a node maps to that node's end.
        var nodeIndex = 0
        for (k, start) in starts.enumerated() where start <= target { nodeIndex = k }
        let local = target - starts[nodeIndex]
        return DocumentLocation(path: nodes[nodeIndex].path, offset: local)
    }
}
