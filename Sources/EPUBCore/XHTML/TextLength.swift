import Foundation

/// Text length of a content document for page-count estimation (docs/design/02-rendering.md §5.2).
///
/// Counts the characters of the text nodes under `body`, excluding ruby annotations (`rt`, `rp`), `script`,
/// `style` and `template` elements, with runs of whitespace collapsed to one character and leading/trailing
/// whitespace dropped. The same walk will feed the search index in M3.
public enum TextLength {
    static let excludedElements: Set<String> = ["rt", "rp", "script", "style", "template", "head", "title"]

    /// Character count of `document`'s body (or of the root when there is no body).
    public static func characterCount(of document: XMLDocument) -> Int {
        let root = document.root
        let body = root.firstChild(named: "body") ?? root
        var count = 0
        var pendingWhitespace = false
        var hasText = false
        func visit(_ element: XMLElement) {
            if excludedElements.contains(element.name) { return }
            for child in element.children {
                switch child {
                case .text(let text):
                    for scalar in text.unicodeScalars {
                        if scalar.properties.isWhitespace {
                            pendingWhitespace = true
                        } else {
                            if pendingWhitespace && hasText { count += 1 }
                            pendingWhitespace = false
                            hasText = true
                            count += 1
                        }
                    }
                case .element(let e):
                    visit(e)
                }
            }
        }
        visit(body)
        return count
    }
}
