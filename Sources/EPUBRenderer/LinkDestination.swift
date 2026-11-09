import Foundation
import EPUBCore

/// Where a link the document reported points (M5, docs/design/02-rendering.md §4.2).
@MainActor
enum LinkDestination: Equatable, Sendable {
    /// Outside the publication (http, mailto, …). The library does not navigate; the app gets `externalLink`.
    case external(URL)
    /// A spine item of this publication, with the fragment if any.
    case spineItem(index: Int, path: String, fragment: String?)
    /// A publication resource that is not in the spine (an image, a stylesheet). Not navigable.
    case resource(path: String)
    /// A path of this publication that the container does not have.
    case missing(path: String)
    /// Something that is neither (another publication's `epub://` URL, the library's own `_reader/` documents).
    case ignored

    /// Classifies a resolved `href` (an absolute URL, as `reader.js` reports it).
    static func resolve(_ href: String, publicationID: PublicationID, publication: Publication, contains: (String) -> Bool) -> LinkDestination {
        guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return .ignored }
        guard scheme == EPUBSchemeHandler.scheme else {
            // A document can only point outside through a real URL scheme; `about:` / `data:` / `blob:` are not links
            // for the reader.
            return ["about", "data", "blob", "javascript"].contains(scheme) ? .ignored : .external(url)
        }
        guard url.host == publicationID.description else { return .ignored }
        // `URL.path` is already percent-decoded (decoding again would break names containing "%").
        let path = ContainerPath.normalize(url.path)
        if path.hasPrefix("_reader/") || path.isEmpty { return .ignored }
        let fragment = url.fragment.flatMap { $0.isEmpty ? nil : ($0.removingPercentEncoding ?? $0) }
        if let index = publication.spineIndex(ofPath: path) {
            return .spineItem(index: index, path: path, fragment: fragment)
        }
        return contains(path) ? .resource(path: path) : .missing(path: path)
    }
}

/// Reads documents through EPUBCore to resolve link fragments into CFIs and notes into text, for targets in
/// documents other than the one on screen (M5).
enum FragmentLookup {
    /// The CFI of the element `fragment` names in the document at `path`; the document's body when `fragment` is nil.
    static func cfi(path: String, fragment: String?, spineIndex: Int, in container: EPUBContainer) async -> CFI? {
        let steps = container.publication.cfiSpineSteps(forSpineIndex: spineIndex)
        guard let fragment else { return nil }
        guard let tree = await tree(path: path, in: container) else { return nil }
        return CFIGenerator.cfi(forElementWithID: fragment, in: tree, spineSteps: steps)
    }

    /// The note element (`XMLDocument.notePath`) for a fragment: its CFI and whitespace-collapsed text.
    static func note(path: String, fragment: String, spineIndex: Int?, in container: EPUBContainer) async -> (cfi: CFI?, text: String)? {
        guard let tree = await tree(path: path, in: container), let notePath = tree.notePath(forElementWithID: fragment),
              let element = tree.element(at: notePath) else { return nil }
        let steps = spineIndex.map { container.publication.cfiSpineSteps(forSpineIndex: $0) } ?? []
        let cfi = spineIndex == nil ? nil : CFIGenerator.cfi(for: DocumentLocation(path: notePath), in: tree, spineSteps: steps)
        return (cfi, collapseWhitespace(element.textContent))
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func tree(path: String, in container: EPUBContainer) async -> EPUBCore.XMLDocument? {
        guard let document = try? await container.contentDocument(at: path), document.isXML else { return nil }
        return try? EPUBCore.XMLDocument(data: document.data)
    }
}
