import Foundation

/// Text length of a content document for page-count estimation (docs/design/02-rendering.md §5.2).
///
/// Counts the characters of the text nodes under `body`, excluding ruby annotations (`rt`, `rp`), `script`,
/// `style` and `template` elements, with runs of whitespace collapsed to one character and leading/trailing
/// whitespace dropped. The walk is `TextMap`'s, which the search index uses too (M3).
public enum TextLength {
    public static let excludedElements: Set<String> = ["rt", "rp", "script", "style", "template", "head", "title"]

    /// Character count of `document`'s body (or of the root when there is no body).
    public static func characterCount(of document: XMLDocument) -> Int {
        TextMap(document: document).collapsedCharacterCount
    }
}
