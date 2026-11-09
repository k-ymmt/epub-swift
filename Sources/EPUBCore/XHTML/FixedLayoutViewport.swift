import Foundation

/// The page size a fixed-layout (pre-paginated) document declares in `<meta name="viewport" content="width=W, height=H">`
/// (docs/design/01-core.md §3, 02-rendering §6.1). CSS pixels. The renderer draws such a document at this size and
/// scales it into the visible area.
public struct FixedLayoutViewport: Sendable, Hashable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Parses the `content` attribute of a viewport meta. Pairs are separated by `,` or `;`, values may carry a `px`
    /// suffix. Returns nil unless both `width` and `height` are positive numbers (`width=device-width`, the reflowable
    /// form, is not a fixed-layout viewport).
    public init?(metaContent: String) {
        var width: Double?
        var height: Double?
        for pair in metaContent.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            var value = parts[1].lowercased()
            if value.hasSuffix("px") { value = String(value.dropLast(2)).trimmingCharacters(in: .whitespaces) }
            guard let number = Double(value), number > 0, number.isFinite else { continue }
            switch parts[0].lowercased() {
            case "width": width = number
            case "height": height = number
            default: break
            }
        }
        guard let width, let height else { return nil }
        self.width = width
        self.height = height
    }

    /// The viewport declared by the first `meta[name=viewport]` in the document's `head` (any `meta` with that name
    /// when there is no `head`), or nil.
    public init?(document: XMLDocument) {
        let scope = document.root.firstChild(named: "head") ?? document.root
        let metas = scope.descendants { $0.name == "meta" && $0.attribute("name")?.lowercased() == "viewport" }
        for meta in metas {
            if let content = meta.attribute("content"), let viewport = FixedLayoutViewport(metaContent: content) {
                self = viewport
                return
            }
        }
        return nil
    }

    public var aspectRatio: Double { height > 0 ? width / height : 1 }
}
