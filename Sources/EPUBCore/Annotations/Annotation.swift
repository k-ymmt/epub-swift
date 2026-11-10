import Foundation

// EPUB Annotations 1.0 data model (W3C Working Draft 2026-10-15; docs/design/06-annotations.md §3).
// The position of an annotation is a CFI. The exchange selectors of the specification are generated from it and
// resolved to it by `AnnotationResolver`; selectors read from another Reading System are kept as originals so they
// round-trip unchanged (§2.1).

/// A set of annotations about one publication: the `annotations.json` document (06-annotations §3.1).
public struct AnnotationSet: Hashable, Sendable {
    /// `urn:uuid:<lowercase UUID>` for new sets.
    public var id: String
    public var generated: Date?
    public var about: About
    public var items: [Annotation]
    /// `@language` of the extra `@context` object: the language of plain-string texts.
    public var defaultLanguage: String?
    /// `@direction` of the extra `@context` object.
    public var defaultDirection: TextDirection?
    /// Properties of the set the library does not know, written back unchanged (§3.6).
    public var extensions: JSONObject

    public init(
        id: String = AnnotationSet.newID(),
        generated: Date? = nil,
        about: About = About(),
        items: [Annotation] = [],
        defaultLanguage: String? = nil,
        defaultDirection: TextDirection? = nil,
        extensions: JSONObject = [:]
    ) {
        self.id = id
        self.generated = generated
        self.about = about
        self.items = items
        self.defaultLanguage = defaultLanguage
        self.defaultDirection = defaultDirection
        self.extensions = extensions
    }

    /// A new `urn:uuid:` identifier (lowercase, as RFC 9562 recommends).
    public static func newID() -> String {
        "urn:uuid:" + UUID().uuidString.lowercased()
    }

    /// What the set is about: Dublin Core terms describing the publication (`about`).
    public struct About: Hashable, Sendable {
        public var title: LocalizableText?
        public var creators: [LocalizableText]
        public var publisher: LocalizableText?
        /// `dc:date`, kept as written (the specification recommends but does not require W3CDTF).
        public var date: String?
        /// `dc:identifier`: the package's unique identifier. A Dublin Core term this library adds (§2.3) to help
        /// match a set to a book; it is not proof that the set belongs to the book (§7).
        public var identifier: String?
        /// Other members (other DC terms) written back unchanged.
        public var extensions: JSONObject

        public init(
            title: LocalizableText? = nil,
            creators: [LocalizableText] = [],
            publisher: LocalizableText? = nil,
            date: String? = nil,
            identifier: String? = nil,
            extensions: JSONObject = [:]
        ) {
            self.title = title
            self.creators = creators
            self.publisher = publisher
            self.date = date
            self.identifier = identifier
            self.extensions = extensions
        }

        /// The publication's metadata (title, authors, publisher, `dc:date`, unique identifier).
        public init(publication: Publication) {
            let metadata = publication.metadata
            self.init(
                title: metadata.title.isEmpty ? nil : LocalizableText(metadata.title),
                creators: metadata.authors.map { LocalizableText($0) },
                publisher: metadata.publisher.map { LocalizableText($0) },
                date: metadata.rawMetadata["dc:date"]?.first,
                identifier: metadata.identifier
            )
        }
    }
}

/// One annotation: a highlight or a bookmark (06-annotations §3.2).
public struct Annotation: Identifiable, Hashable, Sendable {
    public enum Motivation: String, Hashable, Sendable, CaseIterable {
        case highlighting, bookmarking
    }

    /// A URI. New annotations get `urn:uuid:…`; any URI from another system is kept.
    public var id: String
    /// A missing `motivation` reads as `.bookmarking` (the specification's default). Always written.
    public var motivation: Motivation
    public var created: Date
    public var modified: Date?
    /// Who made the annotation. Not verified: an imported creator is only what the file says (§11).
    public var creator: Creator?
    public var target: Target
    public var body: Body?
    /// Where the annotation came from. Library information, not written on export (§4.3).
    public var origin: Origin
    public var extensions: JSONObject

    public init(
        id: String = AnnotationSet.newID(),
        motivation: Motivation,
        created: Date = Annotation.now(),
        modified: Date? = nil,
        creator: Creator? = nil,
        target: Target,
        body: Body? = nil,
        origin: Origin = .local,
        extensions: JSONObject = [:]
    ) {
        self.id = id
        self.motivation = motivation
        self.created = created
        self.modified = modified
        self.creator = creator
        self.target = target
        self.body = body
        self.origin = origin
        self.extensions = extensions
    }

    /// A highlight of `range`. The target's `source` is the path of the spine item the range is in.
    ///
    /// `note` is the reader's own note on the passage, not the selected text (the text is kept by the
    /// TextQuoteSelector on export). Show it as plain text only (§11).
    public static func highlight(
        _ range: CFIRange,
        in publication: Publication,
        color: HighlightColor = .yellow,
        style: HighlightStyle = .solid,
        note: LocalizableText? = nil,
        tags: [String] = [],
        at date: Date = .now
    ) -> Annotation {
        Annotation(
            motivation: .highlighting,
            created: Annotation.truncated(date),
            target: Target(source: publication.sourcePath(for: range.start), position: .range(range)),
            body: Body(content: note.map { .text($0) }, color: color, style: style, tags: tags)
        )
    }

    /// A bookmark at `position`. A body is only attached when there is a note.
    public static func bookmark(at position: CFI, in publication: Publication, note: LocalizableText? = nil, at date: Date = .now) -> Annotation {
        Annotation(
            motivation: .bookmarking,
            created: Annotation.truncated(date),
            target: Target(source: publication.sourcePath(for: position), position: .point(position)),
            body: note.map { Body(content: .text($0)) }
        )
    }

    /// The current time truncated to milliseconds, the precision the storage encoding keeps (so a stored
    /// annotation decodes equal to itself).
    public static func now() -> Date {
        truncated(.now)
    }

    static func truncated(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    /// Spine index from the CFI, when the position is resolved.
    public var spineIndex: Int? {
        switch target.position {
        case .range(let range): return range.spineIndex
        case .point(let cfi): return cfi.spineIndex
        case .resource, .unresolved: return nil
        }
    }

    /// The range of a highlight, when resolved.
    public var range: CFIRange? {
        if case .range(let range) = target.position { return range }
        return nil
    }

    /// The start of the range, or the point.
    public var startCFI: CFI? {
        switch target.position {
        case .range(let range): return range.start
        case .point(let cfi): return cfi
        case .resource, .unresolved: return nil
        }
    }

    /// Body color, or the specification's default (yellow) when there is no body.
    public var color: HighlightColor { body?.color ?? .yellow }
    /// Body style, or the default (solid) when there is no body.
    public var style: HighlightStyle { body?.style ?? .solid }

    /// The text note, if the body is a textual note.
    public var note: LocalizableText? {
        get {
            if case .text(let text)? = body?.content { return text }
            return nil
        }
        set {
            if body == nil {
                guard let newValue else { return }
                body = Body(content: .text(newValue))
            } else {
                body?.content = newValue.map { .text($0) }
            }
        }
    }
}

public struct Creator: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case person = "Person", organization = "Organization", software = "Software"
    }

    public var id: String
    public var kind: Kind
    public var name: LocalizableText?
    public var extensions: JSONObject

    public init(id: String, kind: Kind = .person, name: LocalizableText? = nil, extensions: JSONObject = [:]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.extensions = extensions
    }
}

/// Where an annotation came from (library information; written only by the storage encoding).
public enum Origin: Hashable, Sendable {
    /// Made in this app.
    case local
    /// Taken in from a detached annotation file (the specification's §11.5 distinction between one's own and
    /// imported annotations).
    case imported(setID: String, importedAt: Date)
    /// Embedded in the EPUB (`META-INF/annotations.json`). Read-only (§9.3).
    case publication

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case local, imported, publication
    }

    public var kind: Kind {
        switch self {
        case .local: return .local
        case .imported: return .imported
        case .publication: return .publication
        }
    }
}

/// What an annotation points at (06-annotations §3.3).
public struct Target: Hashable, Sendable {
    public enum Position: Hashable, Sendable {
        /// A highlight.
        case range(CFIRange)
        /// A bookmark.
        case point(CFI)
        /// No selector: the whole document.
        case resource
        /// Not resolved yet, not resolvable, or not expressible as a CFI (an image region, a time range). The
        /// original selectors are kept.
        case unresolved

        /// The CFI string of a resolved position.
        public var cfiString: String? {
            switch self {
            case .range(let range): return range.description
            case .point(let cfi): return cfi.description
            case .resource, .unresolved: return nil
            }
        }
    }

    /// Path from the root of the container, percent-decoded (`OEBPS/text/chapter1.xhtml`). Written
    /// percent-encoded.
    public var source: String
    /// Changing the position drops the original and generated selectors: they describe the old position (§2.1).
    public var position: Position {
        didSet {
            if position != oldValue {
                originalSelectors = nil
                originalSelectorJSON = nil
                generatedSelectors = nil
            }
        }
    }
    /// The selectors as read from another Reading System (including any `epubswift:CfiSelector`); nil for
    /// annotations made here, and when only a CFI selector was read. Written back unchanged while the position is
    /// unchanged.
    public private(set) var originalSelectors: [Selector]?
    /// The exchange selectors `AnnotationResolver.generatingSelectors(for:)` made from the position, for export.
    /// Not stored by the storage encoding.
    public internal(set) var generatedSelectors: [Selector]?
    public var extensions: JSONObject
    /// The selector array exactly as read (so `refinedBy` keeps its single/array form and unknown members of
    /// known selector types survive).
    var originalSelectorJSON: [JSONValue]?

    public init(source: String, position: Position, extensions: JSONObject = [:]) {
        self.source = source
        self.position = position
        self.extensions = extensions
    }

    init(source: String, position: Position, originalSelectors: [Selector]?, originalSelectorJSON: [JSONValue]?, extensions: JSONObject) {
        self.source = source
        self.position = position
        self.originalSelectors = originalSelectors
        self.originalSelectorJSON = originalSelectorJSON
        self.extensions = extensions
    }

    /// Sets the position found by resolving the original selectors without dropping them (§6.2: imported
    /// annotations keep their originals after resolution).
    mutating func setResolvedPosition(_ position: Position) {
        let originals = originalSelectors
        let json = originalSelectorJSON
        self.position = position
        originalSelectors = originals
        originalSelectorJSON = json
    }
}

/// A selector of the specification (plus the Web Annotation TextQuoteSelector and this library's CFI selector),
/// kept so that read selectors are not lost (06-annotations §3.4). Apps do not need to build these.
public indirect enum Selector: Hashable, Sendable {
    case fragment(value: String, conformsTo: String?, refinedBy: [Selector])
    case css(value: String, refinedBy: [Selector])
    /// Unicode code points into the `textContent` of the selected element (or the document's `body`).
    case textPosition(start: Int, end: Int, refinedBy: [Selector])
    case textQuote(exact: String, prefix: String?, suffix: String?)
    /// `epubswift:CfiSelector`.
    case cfi(String)
    /// A type this library does not know, written back as read.
    case unknown(JSONObject)

    public var isCFI: Bool {
        if case .cfi = self { return true }
        return false
    }
}

/// The body of an annotation: the note and the highlight's look (06-annotations §3.5).
public struct Body: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        /// `TextualBody`: plain text only. Never render it as HTML (§11).
        case text(LocalizableText)
        /// Relative URL (inside the `.annotations` ZIP, or under `META-INF` for embedded annotations), or an
        /// absolute URL the library does not fetch (`isExternal`).
        case image(String)
        case audio(String)
        case video(String)
    }

    /// nil: no note (written as `value: ""`).
    public var content: Content?
    /// Media type. Only `text/plain` is valid for a textual body.
    public var format: String?
    public var color: HighlightColor
    public var style: HighlightStyle
    public var tags: [String]
    public var extensions: JSONObject

    public init(content: Content? = nil, format: String? = nil, color: HighlightColor = .yellow, style: HighlightStyle = .solid, tags: [String] = [], extensions: JSONObject = [:]) {
        self.content = content
        self.format = format
        self.color = color
        self.style = style
        self.tags = tags
        self.extensions = extensions
    }

    /// Whether an audio, image or video body points at an absolute URL. The library never fetches it; an app that
    /// wants to must ask the reader first (§11).
    public var isExternal: Bool {
        switch content {
        case .image(let url), .audio(let url), .video(let url): return AnnotationPath.isAbsoluteURL(url)
        case .text, nil: return false
        }
    }
}

/// The six color labels of the specification, plus any other value read from a file (kept, drawn gray).
public enum HighlightColor: Hashable, Sendable, RawRepresentable {
    case pink, orange, yellow, green, blue, purple
    case other(String)

    /// The labels the specification defines, in its order.
    public static let standard: [HighlightColor] = [.pink, .orange, .yellow, .green, .blue, .purple]

    public init(rawValue: String) {
        switch rawValue {
        case "pink": self = .pink
        case "orange": self = .orange
        case "yellow": self = .yellow
        case "green": self = .green
        case "blue": self = .blue
        case "purple": self = .purple
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pink: return "pink"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .blue: return "blue"
        case .purple: return "purple"
        case .other(let value): return value
        }
    }
}

/// The four highlight styles of the specification, plus any other value read from a file (kept, drawn solid).
public enum HighlightStyle: Hashable, Sendable, RawRepresentable {
    case solid, underline, strikethrough, outline
    case other(String)

    public static let standard: [HighlightStyle] = [.solid, .underline, .strikethrough, .outline]

    public init(rawValue: String) {
        switch rawValue {
        case "solid": self = .solid
        case "underline": self = .underline
        case "strikethrough": self = .strikethrough
        case "outline": self = .outline
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .solid: return "solid"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .outline: return "outline"
        case .other(let value): return value
        }
    }
}

public enum TextDirection: String, Hashable, Sendable {
    case ltr, rtl
}

/// A string with an optional language and base direction: a plain JSON string, or `{text, language, direction}`.
public struct LocalizableText: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var text: String
    /// BCP 47 language tag. nil: the set's default.
    public var language: String?
    public var direction: TextDirection?

    public init(_ text: String, language: String? = nil, direction: TextDirection? = nil) {
        self.text = text
        self.language = language
        self.direction = direction
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { text }
}

extension Publication {
    /// The container path of the spine item a CFI addresses (empty when it addresses none).
    func sourcePath(for cfi: CFI) -> String {
        guard let index = spineIndex(of: cfi), readingOrder.indices.contains(index) else { return "" }
        return readingOrder[index].path
    }
}
