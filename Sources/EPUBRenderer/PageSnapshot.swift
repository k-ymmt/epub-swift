import CoreGraphics
import Foundation

/// A rendered page image for page-turn effects (docs/design/02-rendering.md §7.1).
///
/// `image` has `scale` pixels per point; `size` is in points. EPUBUI draws it at `size`.
public struct PageSnapshot: @unchecked Sendable {
    public let image: CGImage
    public let scale: CGFloat
    public let size: CGSize
    public let spineIndex: Int
    public let pageIndex: Int

    public init(image: CGImage, scale: CGFloat, size: CGSize, spineIndex: Int, pageIndex: Int) {
        self.image = image
        self.scale = scale
        self.size = size
        self.spineIndex = spineIndex
        self.pageIndex = pageIndex
    }
}

/// Which page to snapshot relative to the current one.
public enum PageSnapshotTarget: Sendable, Hashable {
    case current
    case next
    case previous
}

/// Reading direction of a page turn.
public enum PageDirection: Sendable, Hashable {
    case forward
    case backward
}
