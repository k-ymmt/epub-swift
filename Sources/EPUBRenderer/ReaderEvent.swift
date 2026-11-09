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
    /// A tap on one of `ReaderSession.highlights`. Rects are in the visible page's coordinate space (M3).
    case highlightTapped(Highlight.ID, rects: [CGRect])
    /// The text selection changed; nil when it was cleared (M3). Mirrors `ReaderSession.currentSelection`.
    case selectionChanged(SelectedText?)
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
