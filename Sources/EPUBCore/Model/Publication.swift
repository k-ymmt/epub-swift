import Foundation

/// The parsed structure of an opened EPUB (docs/design/01-core.md §3).
public struct Publication: Sendable {
    public let id: PublicationID
    public let metadata: Metadata
    /// Every manifest item, in document order. Use `manifestItem(withID:)` / `manifestItem(atPath:)` to look up.
    public let manifest: [ManifestItem]
    /// Spine order. Items with `linear="no"` are included with `isLinear == false`.
    public let readingOrder: [SpineItem]
    public let toc: [TOCEntry]
    public let pageList: [TOCEntry]
    public let landmarks: [TOCEntry]
    /// Book-level default (`rendition:layout`).
    public let layout: RenditionLayout
    /// Book-level default (`rendition:spread`). Itemrefs may override it (`SpineItem.spread`).
    public let spread: RenditionSpread
    /// Book-level default (`rendition:orientation`). Read but not enforced: the library does not lock the device
    /// orientation (M4).
    public let orientation: RenditionOrientation
    public let pageProgression: PageProgression
    /// Container path of the manifest item with `properties="cover-image"`, if any.
    public let coverImagePath: String?
    /// Container path of the OPF. Relative hrefs in the OPF resolve against its directory.
    public let packageDocumentPath: String
    /// Container path of the nav document, if one was declared.
    public let navigationDocumentPath: String?
    /// CFI step index of the `spine` element among the `package` element's children (`/6` when it is the third
    /// element child, docs/design/01-core.md §5.3).
    public let spineElementIndex: Int
    public let warnings: [PublicationWarning]

    private let manifestByID: [String: Int]
    private let manifestByPath: [String: Int]
    private let spineByPath: [String: Int]

    public init(
        id: PublicationID,
        metadata: Metadata,
        manifest: [ManifestItem],
        readingOrder: [SpineItem],
        toc: [TOCEntry],
        pageList: [TOCEntry],
        landmarks: [TOCEntry],
        layout: RenditionLayout,
        spread: RenditionSpread,
        orientation: RenditionOrientation = .auto,
        pageProgression: PageProgression,
        coverImagePath: String?,
        packageDocumentPath: String,
        navigationDocumentPath: String?,
        spineElementIndex: Int = 6,
        warnings: [PublicationWarning]
    ) {
        self.id = id
        self.metadata = metadata
        self.manifest = manifest
        self.readingOrder = readingOrder
        self.toc = toc
        self.pageList = pageList
        self.landmarks = landmarks
        self.layout = layout
        self.spread = spread
        self.orientation = orientation
        self.pageProgression = pageProgression
        self.coverImagePath = coverImagePath
        self.packageDocumentPath = packageDocumentPath
        self.navigationDocumentPath = navigationDocumentPath
        self.spineElementIndex = spineElementIndex
        self.warnings = warnings
        var byID: [String: Int] = [:]
        var byPath: [String: Int] = [:]
        for (i, item) in manifest.enumerated() {
            if byID[item.id] == nil { byID[item.id] = i }
            if byPath[item.path] == nil { byPath[item.path] = i }
        }
        manifestByID = byID
        manifestByPath = byPath
        var spineByPath: [String: Int] = [:]
        for item in readingOrder where spineByPath[item.path] == nil {
            spineByPath[item.path] = item.index
        }
        self.spineByPath = spineByPath
    }

    public func manifestItem(withID id: String) -> ManifestItem? {
        manifestByID[id].map { manifest[$0] }
    }

    public func manifestItem(atPath path: String) -> ManifestItem? {
        manifestByPath[ContainerPath.normalize(path)].map { manifest[$0] }
    }

    /// Spine index of the item served at `path` (container path), if the path is a spine item.
    public func spineIndex(ofPath path: String) -> Int? {
        spineByPath[ContainerPath.normalize(path)]
    }

    /// Spine items that take part in the reading order (`linear != "no"`).
    public var linearReadingOrder: [SpineItem] {
        readingOrder.filter(\.isLinear)
    }

    // MARK: - CFI

    /// The spine steps of a CFI into spine item `index`: `/<spineElementIndex>/<itemref step>[idref]`.
    public func cfiSpineSteps(forSpineIndex index: Int) -> [CFI.Step] {
        guard readingOrder.indices.contains(index) else { return [] }
        let item = readingOrder[index]
        return [CFI.Step(index: spineElementIndex), CFI.Step(index: item.cfiStepIndex, id: item.id.isEmpty ? nil : item.id)]
    }

    /// The spine index a CFI addresses: by the itemref ID assertion when present, else by the itemref step index.
    /// nil when neither matches a spine item (no guess from the step index: with skipped itemrefs it would name
    /// another chapter).
    public func spineIndex(of cfi: CFI) -> Int? {
        guard let step = cfi.spineSteps.last else { return nil }
        if let id = step.id, let item = readingOrder.first(where: { $0.id == id }) { return item.index }
        return readingOrder.first(where: { $0.cfiStepIndex == step.index })?.index
    }
}

public struct Metadata: Sendable, Hashable {
    public var title: String
    /// Additional titles (subtitle, collection, ...) in document order, excluding `title`.
    public var alternativeTitles: [String]
    public var authors: [String]
    public var language: String?
    /// The `dc:identifier` named by `unique-identifier`, or the first one.
    public var identifier: String?
    public var publisher: String?
    public var modified: Date?
    /// Every `meta[property]` value by property name, plus `dc:*` elements under their qualified names
    /// (for example `dc:date`, `dc:rights`).
    public var rawMetadata: [String: [String]]

    public init(
        title: String = "",
        alternativeTitles: [String] = [],
        authors: [String] = [],
        language: String? = nil,
        identifier: String? = nil,
        publisher: String? = nil,
        modified: Date? = nil,
        rawMetadata: [String: [String]] = [:]
    ) {
        self.title = title
        self.alternativeTitles = alternativeTitles
        self.authors = authors
        self.language = language
        self.identifier = identifier
        self.publisher = publisher
        self.modified = modified
        self.rawMetadata = rawMetadata
    }
}

public struct ManifestItem: Sendable, Hashable, Identifiable {
    public let id: String
    /// `href` as written in the OPF.
    public let href: String
    /// Normalized container path (resolved against the OPF directory, percent-decoded).
    public let path: String
    public let mediaType: String
    /// Space-separated `properties` values (`nav`, `cover-image`, `scripted`, `svg`, `mathml`, `remote-resources`).
    public let properties: Set<String>
    public let fallback: String?
    public let mediaOverlay: String?

    public init(id: String, href: String, path: String, mediaType: String, properties: Set<String>, fallback: String?, mediaOverlay: String?) {
        self.id = id
        self.href = href
        self.path = path
        self.mediaType = mediaType
        self.properties = properties
        self.fallback = fallback
        self.mediaOverlay = mediaOverlay
    }

    public var isNavigation: Bool { properties.contains("nav") }
    public var isCoverImage: Bool { properties.contains("cover-image") }
    public var isXHTML: Bool { mediaType == "application/xhtml+xml" }
}

public struct SpineItem: Sendable, Hashable, Identifiable {
    /// `idref`
    public let id: String
    /// Position in the spine (0-based).
    public let index: Int
    /// Container path.
    public let path: String
    public let mediaType: String
    public let isLinear: Bool
    /// Book-level layout, overridden by `rendition:layout-*` on the itemref.
    public let layout: RenditionLayout
    /// `page-spread-left` / `page-spread-right` / `rendition:page-spread-center` on the itemref.
    public let spreadPosition: SpreadPosition?
    /// `rendition:spread-*` on the itemref; nil means the book-level `Publication.spread` applies (M4).
    public let spread: RenditionSpread?
    /// `rendition:orientation-*` on the itemref; nil means the book-level value applies (M4). Not enforced.
    public let orientation: RenditionOrientation?
    /// The `<meta name="viewport">` size of the document, filled when the container is opened (M4). A fixed-layout
    /// document without one gets `PublicationWarning.missingViewport` and is drawn at the visible page size.
    public let viewport: FixedLayoutViewport?
    /// Filled when the container is opened (Core DOM text count). Used to estimate page counts.
    public let characterCount: Int?
    /// CFI step index of this itemref among the `spine` element's children (`2 × (1-based position)`). Differs
    /// from `2 × (index + 1)` only when the spine has non-itemref children or unresolvable itemrefs.
    public let cfiStepIndex: Int

    public init(id: String, index: Int, path: String, mediaType: String, isLinear: Bool, layout: RenditionLayout, spreadPosition: SpreadPosition?, spread: RenditionSpread? = nil, orientation: RenditionOrientation? = nil, viewport: FixedLayoutViewport? = nil, characterCount: Int? = nil, cfiStepIndex: Int? = nil) {
        self.id = id
        self.index = index
        self.path = path
        self.mediaType = mediaType
        self.isLinear = isLinear
        self.layout = layout
        self.spreadPosition = spreadPosition
        self.spread = spread
        self.orientation = orientation
        self.viewport = viewport
        self.characterCount = characterCount
        self.cfiStepIndex = cfiStepIndex ?? 2 * (index + 1)
    }

    /// Whether this item is laid out as a fixed page (`rendition:layout` pre-paginated, after the itemref override).
    public var isFixedLayout: Bool { layout == .prePaginated }
}

/// An entry of the `toc`, `page-list` or `landmarks` nav.
public struct TOCEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(href ?? "")#\(label)@\(depthToken)" }
    public let label: String
    /// Container path of the target (fragment removed), resolved against the nav document. nil for headings without links.
    public let href: String?
    /// Spine index of the target document, if the target is a spine item.
    public let spineIndex: Int?
    public let fragment: String?
    public let children: [TOCEntry]
    private let depthToken: String

    public init(label: String, href: String?, spineIndex: Int?, fragment: String?, children: [TOCEntry] = [], depthToken: String = "") {
        self.label = label
        self.href = href
        self.spineIndex = spineIndex
        self.fragment = fragment
        self.children = children
        self.depthToken = depthToken
    }

    /// Depth of the deepest entry in this subtree (a leaf has depth 1).
    public var depth: Int {
        1 + (children.map(\.depth).max() ?? 0)
    }
}

public enum RenditionLayout: String, Sendable, Hashable {
    case reflowable
    case prePaginated = "pre-paginated"
}

public enum RenditionSpread: String, Sendable, Hashable {
    case auto, none, landscape, both
}

/// `rendition:orientation` (M4). Read for completeness; the library does not lock the orientation.
public enum RenditionOrientation: String, Sendable, Hashable {
    case auto, landscape, portrait
}

public enum PageProgression: String, Sendable, Hashable {
    case ltr, rtl, `default`
}

public enum SpreadPosition: String, Sendable, Hashable {
    case left, right, center
}

public enum PublicationWarning: Sendable, Hashable {
    case missingMimetype
    case missingNavigation
    case malformedXHTML(path: String)
    case missingResource(path: String, referencedFrom: String)
    case unsupportedEncryption(path: String, algorithm: String)
    case unknownMediaType(path: String)
    case duplicateManifestID(id: String)
    /// `rendition:layout` is pre-paginated but the document declares no viewport meta (required by the FXL spec).
    case missingViewport(path: String)
    /// The ZIP local header disagreed with the central directory; the central directory values were used.
    case inconsistentZIPEntry(path: String)
    /// `META-INF/encryption.xml` exists but is not well-formed XML; no resource is treated as encrypted.
    case malformedEncryptionXML
}

/// Thrown only when the EPUB cannot be opened at all (docs/design/00-overview.md §5.2).
public enum EPUBError: Error, Sendable {
    case notAZIPArchive
    case unsupportedCompression(path: String, method: Int)
    case corruptEntry(path: String)
    case missingContainerXML
    case missingPackageDocument(path: String)
    case invalidPackage(String)
    case missingResource(path: String)
    case encryptedResource(path: String)
}
