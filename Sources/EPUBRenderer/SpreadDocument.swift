import Foundation
import EPUBCore

/// The wrapper document the scheme handler serves at `epub://<id>/_reader/spread?kind=…&pages=…` (M4,
/// docs/design/02-rendering.md §6.2). It holds one or two same-origin iframes, one per page of the face; `reader.js`
/// in the wrapper (the "spread controller") lays the frames out, scales fixed-layout pages into the visible area and
/// proxies the bridge calls to the frames' own `reader.js`.
@MainActor
enum SpreadDocument {
    enum Kind: String, Sendable {
        /// One or two pre-paginated documents, scaled to fit.
        case fixed
        /// One reflowable vertical-writing document shown twice, the two frames scrolled to adjacent pages.
        case vertical
    }

    struct Page: Sendable, Hashable {
        var spineIndex: Int
        var placement: SpreadPlan.Placement
    }

    static let path = "_reader/spread"

    /// `pages` in reading order; placements `l` / `r` / `f`.
    static func url(publicationID: PublicationID, kind: Kind, pages: [Page]) -> URL {
        var components = URLComponents()
        components.scheme = EPUBSchemeHandler.scheme
        components.host = publicationID.description
        components.path = "/" + path
        let list = pages.map { "\($0.spineIndex)\(letter($0.placement))" }.joined(separator: ",")
        components.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "pages", value: list)]
        return components.url!
    }

    /// The wrapper for a plan unit, or nil for a unit the document itself is loaded for (a reflowable item).
    static func url(publicationID: PublicationID, unit: SpreadPlan.Unit) -> URL? {
        guard case .fixed(let pages) = unit else { return nil }
        return url(publicationID: publicationID, kind: .fixed, pages: pages.map { Page(spineIndex: $0.spineIndex, placement: $0.placement) })
    }

    /// The wrapper that shows a vertical-writing reflowable chapter as two facing pages: the same document in both
    /// frames, the first page of the pair on the side the writing mode starts on (right for vertical-rl).
    static func verticalURL(publicationID: PublicationID, spineIndex: Int, writingMode: WritingMode) -> URL {
        let first: SpreadPlan.Placement = writingMode == .verticalLR ? .left : .right
        let second: SpreadPlan.Placement = first == .left ? .right : .left
        return url(publicationID: publicationID, kind: .vertical, pages: [Page(spineIndex: spineIndex, placement: first), Page(spineIndex: spineIndex, placement: second)])
    }

    /// Parses the query of a wrapper URL. nil when it is malformed.
    static func parse(query items: [URLQueryItem]?) -> (kind: Kind, pages: [Page])? {
        guard let items, let kindValue = items.first(where: { $0.name == "kind" })?.value, let kind = Kind(rawValue: kindValue),
              let list = items.first(where: { $0.name == "pages" })?.value else { return nil }
        var pages: [Page] = []
        for spec in list.split(separator: ",") {
            guard let last = spec.last, let placement = placement(letter: last), let index = Int(spec.dropLast()) else { return nil }
            pages.append(Page(spineIndex: index, placement: placement))
        }
        guard (1...2).contains(pages.count) else { return nil }
        return (kind, pages)
    }

    private static func letter(_ placement: SpreadPlan.Placement) -> String {
        switch placement {
        case .left: "l"
        case .right: "r"
        case .full: "f"
        }
    }

    private static func placement(letter: Character) -> SpreadPlan.Placement? {
        switch letter {
        case "l": .left
        case "r": .right
        case "f": .full
        default: nil
        }
    }

    /// The wrapper HTML. Frames carry the data `reader.js` needs: spine index, spine steps, the declared viewport size
    /// (0 when the document has none: the controller then uses the available area) and the placement.
    static func html(publication: Publication, publicationID: PublicationID, kind: Kind, pages: [Page], rootStyle: String) -> String? {
        var frames: [String] = []
        for (order, page) in pages.enumerated() {
            guard publication.readingOrder.indices.contains(page.spineIndex) else { return nil }
            let item = publication.readingOrder[page.spineIndex]
            let src = EPUBSchemeHandler.url(publicationID: publicationID, path: item.path).absoluteString
            let steps = CFI.render(steps: publication.cfiSpineSteps(forSpineIndex: page.spineIndex))
            let viewport = item.viewport
            frames.append(
                "<iframe id=\"__reader_frame_\(order)\" data-order=\"\(order)\" data-spine-index=\"\(page.spineIndex)\""
                + " data-spine-steps=\"\(ContentInjector.escapeAttribute(steps))\""
                + " data-width=\"\(ContentInjector.cssLength(viewport?.width ?? 0).dropLast(2))\" data-height=\"\(ContentInjector.cssLength(viewport?.height ?? 0).dropLast(2))\""
                + " data-placement=\"\(letter(page.placement))\" src=\"\(ContentInjector.escapeAttribute(src))\" scrolling=\"no\" frameborder=\"0\"></iframe>"
            )
        }
        let progression = publication.pageProgression == .rtl ? "rtl" : "ltr"
        return """
        <!DOCTYPE html>
        <html data-reader-spread="\(kind.rawValue)" data-reader-progression="\(progression)">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, \(kind == .fixed ? "maximum-scale=4" : "user-scalable=no")"/>
        <style>
        :root { --reader-bg: #ffffff; }
        html, body { margin: 0; padding: 0; overflow: hidden; background-color: var(--reader-bg); }
        #__reader_stage { position: relative; overflow: hidden; }
        iframe { position: absolute; border: 0; margin: 0; padding: 0; transform-origin: 0 0; visibility: hidden; background: transparent; }
        </style>
        \(rootStyle.isEmpty ? "" : "<style id=\"__reader_settings\">\(rootStyle)</style>")
        </head>
        <body><div id="__reader_stage">\(frames.joined())</div></body>
        </html>
        """
    }
}
