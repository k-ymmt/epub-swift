import Foundation

/// Builds CFIs from `DocumentLocation`s on the Core DOM (docs/design/01-core.md §5.3).
public enum CFIGenerator {
    /// Number of UTF-16 code units of context on each side of a character offset in the text assertion.
    public static let assertionContextLength = 10

    /// The CFI of `location` in `document`, prefixed with `spineSteps`. Element steps carry the element's `id` as
    /// an ID assertion; a text location gets a text assertion from the text node itself. nil when the path does
    /// not exist in the document.
    public static func cfi(for location: DocumentLocation, in document: XMLDocument, spineSteps: [CFI.Step]) -> CFI? {
        guard let steps = steps(forPath: location.path, in: document) else { return nil }
        var offset: Int?
        var assertion: CFI.TextAssertion?
        if case .text(let text)? = document.node(at: location.path) {
            let clamped = min(max(0, location.offset ?? 0), text.utf16.count)
            offset = clamped
            assertion = textAssertion(in: text, offset: clamped)
        } else if location.offset != nil {
            return nil // an offset on an element
        }
        return CFI(spineSteps: spineSteps, steps: steps, characterOffset: offset, textAssertion: assertion)
    }

    /// Steps for a child path: `2 × (1-based element index)` for elements, `2 × (preceding element count) + 1`
    /// for text.
    public static func steps(forPath path: [Int], in document: XMLDocument) -> [CFI.Step]? {
        var steps: [CFI.Step] = []
        var element = document.root
        for (position, index) in path.enumerated() {
            guard element.children.indices.contains(index) else { return nil }
            var elementsBefore = 0
            for child in element.children.prefix(index) where child.element != nil { elementsBefore += 1 }
            switch element.children[index] {
            case .element(let e):
                let id = e.id.flatMap { $0.isEmpty ? nil : $0 }
                steps.append(CFI.Step(index: 2 * (elementsBefore + 1), id: id))
                element = e
            case .text:
                // A text node is a leaf: the path must end here.
                guard position == path.count - 1 else { return nil }
                steps.append(CFI.Step(index: 2 * elementsBefore + 1))
            }
        }
        return steps
    }

    /// Up to `assertionContextLength` UTF-16 code units before and after `offset` in `text`.
    public static func textAssertion(in text: String, offset: Int) -> CFI.TextAssertion? {
        let utf16 = Array(text.utf16)
        let clamped = min(max(0, offset), utf16.count)
        let before = String(decoding: utf16[max(0, clamped - assertionContextLength)..<clamped], as: UTF16.self)
        let after = String(decoding: utf16[clamped..<min(utf16.count, clamped + assertionContextLength)], as: UTF16.self)
        let assertion = CFI.TextAssertion(before: before, after: after)
        return assertion.isEmpty ? nil : assertion
    }
}
