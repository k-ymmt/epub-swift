import Foundation
import EPUBCore

/// Events a `ReaderSession` emits to the app (docs/design/03-api.md §3.4).
public enum ReaderEvent: Sendable {
    /// The reading position changed: another page or chapter is visible, or the layout changed under the same
    /// text. Mirrors `ReaderSession.position` (M3; replaces M1's `pageChanged`).
    case positionChanged(ReadingPosition)
    /// A link to a resource outside the publication. The library does not navigate; the app opens it.
    case externalLink(URL)
    /// A tap (or click) that hit neither a link nor an image. The point is in the visible page's coordinate space.
    case tapped(CGPoint, zone: TapZone)
    case warning(PublicationWarning)
    case error(ReaderError)
    /// Book-wide page numbering changed: a chapter was measured, or the layout changed and the counts were reset
    /// to estimates / restored from the cache (M2).
    case paginationUpdated(BookPagination)
    /// A tap on a drawn highlight: one of `ReaderSession.annotations`, or of `publicationAnnotations` (look the id
    /// up in both; the app's annotation is on top when both cover the tap). Rects are in the visible page's
    /// coordinate space (M6; replaces `highlightTapped`).
    case annotationTapped(Annotation.ID, rects: [CGRect])
    /// The text selection changed; nil when it was cleared (M3). Mirrors `ReaderSession.currentSelection`.
    case selectionChanged(SelectedText?)
    /// A fixed-layout face was pinch-zoomed in (`true`) or returned to scale 1 (M4). Mirrors `ReaderSession.isZoomed`.
    case zoomChanged(Bool)
    /// A link inside the publication was followed (M5). The session has already moved there; the CFI is the link's
    /// target element (the fragment), or the first text of the target document when the link has no fragment.
    case internalLink(CFI)
    /// A tap on a noteref (`<a epub:type="noteref">`, M5). The session does not move; the app shows the note
    /// (a popover, a sheet) or goes to `NoteContent.cfi`.
    case noteref(NoteContent)
    /// A tap on an image (`<img>`, SVG `<image>`) that is not inside a link, on a reflowable page (M5).
    case imageTapped(TappedImage)
    /// The visible page changed because the reader moved: a page turn, a jump (`go(to:)`, `go(toPage:)`,
    /// `show(_:)`, …) or a followed link. Emitted after the move's `positionChanged` (and before `internalLink`).
    /// Not emitted for the first load, nor when only the layout changed under the same text (settings, resize, a
    /// late page count): apps tell "the reader went somewhere" from "the page was laid out again" by this event.
    case navigated(ReaderNavigation)
}

/// One move of the reader (docs/design/03-api.md §3.4): why the visible page changed, and from where to where.
public struct ReaderNavigation: Sendable, Hashable {
    public enum Cause: Sendable, Hashable {
        /// `goForward()` / `goBackward()`: the next or previous page (EPUBUI's taps, swipes and keys).
        case pageTurn
        /// A move the app asked for: `go(to:)`, `go(toPage:)`, `go(toSpineIndex:)`, `go(toPageInChapter:)`, `show(_:)`.
        case jump
        /// A link inside the publication that the reader tapped (`ReaderEvent.internalLink` follows).
        case link
    }

    public var cause: Cause
    /// The position before the move; nil when none had been published yet.
    public var from: ReadingPosition?
    /// The position after the move (`ReaderSession.position`). On a page without text it can hold the same CFI as
    /// `from`.
    public var to: ReadingPosition

    public init(cause: Cause, from: ReadingPosition?, to: ReadingPosition) {
        self.cause = cause
        self.from = from
        self.to = to
    }
}

/// The note a noteref points at (docs/design/03-api.md §3.4, M5).
///
/// For a note in the same document the content comes from the rendered DOM (`html` is the note element's
/// `innerHTML`, `text` its whitespace-collapsed text). For a note in another document of the publication, `text`
/// comes from EPUBCore's parse of that document and `html` is nil. `cfi` addresses the note element in both cases,
/// so the app can `go(to:)` it.
public struct NoteContent: Sendable, Hashable {
    /// Container path of the document that holds the note.
    public let path: String
    /// Fragment of the link (the note element's id), if any.
    public let fragment: String?
    /// Spine index of the note's document; nil when the document is not in the spine.
    public let spineIndex: Int?
    /// The note element; nil when the target could not be resolved.
    public let cfi: CFI?
    /// The note's markup (same-document notes only).
    public let html: String?
    /// The note's text with whitespace collapsed; nil when the target could not be resolved.
    public let text: String?
    /// `true` when the note is in the document that holds the noteref.
    public let isInSameDocument: Bool
    /// The noteref's box on the visible page (anchor for a popover).
    public let sourceRect: CGRect

    public init(path: String, fragment: String?, spineIndex: Int?, cfi: CFI?, html: String?, text: String?, isInSameDocument: Bool, sourceRect: CGRect) {
        self.path = path
        self.fragment = fragment
        self.spineIndex = spineIndex
        self.cfi = cfi
        self.html = html
        self.text = text
        self.isInSameDocument = isInSameDocument
        self.sourceRect = sourceRect
    }
}

/// An image the reader tapped (docs/design/03-api.md §3.4, M5).
public struct TappedImage: Sendable {
    /// The image URL as the document resolved it (`epub://…` for publication resources).
    public let url: URL
    /// Container path of the image; nil when it is not a publication resource (a `data:` URL).
    public let path: String?
    /// `alt` (or the SVG's `aria-label` / `<title>`); nil when there is none.
    public let alt: String?
    /// The image's box on the visible page (it may extend past the page).
    public let rect: CGRect
    /// Where the tap landed, on the visible page. EPUBUI turns the page instead of reporting the image when this is
    /// in a side tap zone.
    public let point: CGPoint
    /// Reads the image bytes from the container (font-obfuscation rules do not apply to images), or decodes a
    /// `data:` URL.
    public let data: @Sendable () async throws -> Data

    public init(url: URL, path: String?, alt: String?, rect: CGRect, point: CGPoint, data: @escaping @Sendable () async throws -> Data) {
        self.url = url
        self.path = path
        self.alt = alt
        self.rect = rect
        self.point = point
        self.data = data
    }
}

/// Horizontal third of the page a tap landed in, as classified by the UI layer's tap zones.
public enum TapZone: Sendable, Hashable {
    case leading, center, trailing
}

/// The current text selection (docs/design/03-api.md §3.4). Rects are in the visible page's coordinate space.
public struct SelectedText: Sendable, Hashable {
    public let range: CFIRange
    public let text: String
    public let rects: [CGRect]

    public init(range: CFIRange, text: String, rects: [CGRect]) {
        self.range = range
        self.text = text
        self.rects = rects
    }
}

public enum ReaderError: Error, Sendable {
    /// `ready` did not arrive within the timeout (10 s). Retrying is left to the app.
    case loadTimeout(spineIndex: Int)
    /// The spine item could not be read from the container.
    case loadFailed(spineIndex: Int, underlying: String)
    /// The bridge script failed. The message is WebKit's description.
    case scriptFailed(String)
    /// The WebContent process was terminated by the system. The session reloads the current chapter.
    case webContentTerminated
}
