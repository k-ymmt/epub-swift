import Foundation
import EPUBCore

/// The wrapper document of the scrolled layout, served at `epub://<id>/_reader/scroll?start=<spineIndex>`
/// (docs/design/08-continuous-scroll.md §4.1). Its main frame scrolls vertically; `reader.js` in it (the "scroll
/// controller") stacks one same-origin iframe per chapter in `#__reader_stage`, each as tall as its content, and
/// stands in for the chapters it has not loaded with the blocks before and after the stage.
///
/// The document lists the chapters it can show: the linear reading order, or with `single` one item alone (a
/// non-linear item opened by a link or `go(toSpineIndex:)` is not part of the flow, §1).
@MainActor
enum ScrollDocument {
    static let path = "_reader/scroll"

    static func url(publicationID: PublicationID, start spineIndex: Int, single: Bool) -> URL {
        var components = URLComponents()
        components.scheme = EPUBSchemeHandler.scheme
        components.host = publicationID.description
        components.path = "/" + path
        components.queryItems = [URLQueryItem(name: "start", value: String(spineIndex))] + (single ? [URLQueryItem(name: "single", value: "1")] : [])
        return components.url!
    }

    /// Parses the query of a wrapper URL. nil when it is malformed.
    static func parse(query items: [URLQueryItem]?) -> (start: Int, single: Bool)? {
        guard let items, let value = items.first(where: { $0.name == "start" })?.value, let start = Int(value), start >= 0 else { return nil }
        return (start, items.first(where: { $0.name == "single" })?.value == "1")
    }

    /// Spine indices of the chapters the document holds, in order: every linear item, or just `start` with `single`.
    static func spineIndices(publication: Publication, start: Int, single: Bool) -> [Int] {
        single ? [start] : publication.linearReadingOrder.map(\.index)
    }

    /// Whether the item at `spineIndex` is shown alone rather than in the flow of the linear reading order.
    static func isSingle(publication: Publication, spineIndex: Int) -> Bool {
        guard publication.readingOrder.indices.contains(spineIndex) else { return false }
        return !publication.readingOrder[spineIndex].isLinear
    }

    static func html(publication: Publication, publicationID: PublicationID, start: Int, single: Bool, rootStyle: String) -> String? {
        guard publication.readingOrder.indices.contains(start) else { return nil }
        let items: [[String: Any]] = spineIndices(publication: publication, start: start, single: single).map { index in
            let item = publication.readingOrder[index]
            return [
                "i": index,
                "s": CFI.render(steps: publication.cfiSpineSteps(forSpineIndex: index)),
                "u": EPUBSchemeHandler.url(publicationID: publicationID, path: item.path).absoluteString,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items), let json = String(data: data, encoding: .utf8) else { return nil }
        // `overflow-anchor: none`: scroll anchoring is not used (07 §2.3); the controller corrects the position itself.
        // `display: flow-root` keeps the stage's negative top margin (§5.4) from collapsing through the body.
        return """
        <!DOCTYPE html>
        <html data-reader-scroll="\(single ? "single" : "linear")" data-reader-start="\(start)" data-reader-spine="\(ContentInjector.escapeAttribute(json))">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no"/>
        <style>
        :root { --reader-bg: #ffffff; }
        html { margin: 0; padding: 0; overflow-x: hidden; overflow-anchor: none; scrollbar-width: none; background-color: var(--reader-bg); }
        html::-webkit-scrollbar { display: none; }
        body { display: flow-root; margin: 0; padding: 0; overflow-anchor: none; }
        #__reader_head, #__reader_runway, #__reader_tail, #__reader_foot { height: 0; margin: 0; padding: 0; border: 0; }
        #__reader_stage { margin: 0; padding: 0; border: 0; }
        #__reader_stage > iframe { display: block; width: 100%; border: 0; margin: 0; padding: 0; background: transparent; }
        </style>
        \(rootStyle.isEmpty ? "" : "<style id=\"__reader_settings\">\(rootStyle)</style>")
        </head>
        <body><div id="__reader_head"></div><div id="__reader_runway"></div><div id="__reader_stage"></div><div id="__reader_tail"></div><div id="__reader_foot"></div></body>
        </html>
        """
    }
}
