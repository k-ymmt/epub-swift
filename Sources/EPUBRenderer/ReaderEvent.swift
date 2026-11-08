import Foundation
import EPUBCore

/// Events a `ReaderSession` emits to the app (docs/design/03-api.md §3.4). M1 implements the subset that does not
/// depend on CFI; the CFI-based cases (`positionChanged`, `internalLink`, highlights, selection) arrive with M3.
public enum ReaderEvent: Sendable {
    /// The visible chapter and/or page changed. `pageIndex` is within the chapter.
    case pageChanged(spineIndex: Int, pageIndex: Int, pageCount: Int)
    /// A link to a resource outside the publication. The library does not navigate; the app opens it.
    case externalLink(URL)
    /// A tap (or click) that hit neither a link nor an image. The point is in the visible page's coordinate space.
    case tapped(CGPoint, zone: TapZone)
    case warning(PublicationWarning)
    case error(ReaderError)
    /// Book-wide page numbering changed: a chapter was measured, or the layout changed and the counts were reset
    /// to estimates / restored from the cache (M2).
    case paginationUpdated(BookPagination)
}

/// Horizontal third of the page a tap landed in, as classified by the UI layer's tap zones.
public enum TapZone: Sendable, Hashable {
    case leading, center, trailing
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
