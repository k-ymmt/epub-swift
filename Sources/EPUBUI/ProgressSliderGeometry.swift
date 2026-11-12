import CoreGraphics

/// Where book pages sit along the slider's track (docs/design/03-api.md §4.6).
///
/// The first page is at the start edge and the last page at the end edge, both inset by half a thumb so the thumb
/// never leaves the track. A right-bound book (`isRightToLeft`) starts at the right edge, like its page turns.
struct ProgressSliderGeometry: Equatable {
    var totalPages: Int
    var width: CGFloat
    /// Half the thumb's width: the distance between the track's edge and the first / last page.
    var inset: CGFloat
    var isRightToLeft: Bool

    private var span: CGFloat { max(0, width - inset * 2) }

    private func clamped(_ page: Int) -> Int {
        min(max(0, page), max(0, totalPages - 1))
    }

    /// 0 at the first page, 1 at the last, in reading order.
    func fraction(ofPage page: Int) -> Double {
        guard totalPages > 1 else { return 0 }
        return Double(clamped(page)) / Double(totalPages - 1)
    }

    func x(ofPage page: Int) -> CGFloat {
        let along = inset + span * fraction(ofPage: page)
        return isRightToLeft ? width - along : along
    }

    /// The page nearest to `x`, clamped to the book.
    func page(atX x: CGFloat) -> Int {
        guard totalPages > 1, span > 0 else { return 0 }
        let along = (isRightToLeft ? width - x : x) - inset
        let fraction = min(1, max(0, Double(along / span)))
        return clamped(Int((fraction * Double(totalPages - 1)).rounded()))
    }

    /// The page one step away from the visible pages: a hundredth of the book, at least one page, forward in reading
    /// order for a positive `direction`. A step starts from the visible page on that side (the far page of a
    /// two-page spread), so it always leaves what is shown; nil when there is nowhere to go.
    func page(steppingFrom visible: ClosedRange<Int>, by direction: Int) -> Int? {
        guard totalPages > 1, direction != 0 else { return nil }
        let stride = max(1, totalPages / 100)
        let page = direction > 0 ? clamped(visible.upperBound + stride) : clamped(visible.lowerBound - stride)
        return visible.contains(page) ? nil : page
    }

    /// The part of the book this page ends at, as shown to readers (`BookPagination.progression`'s arithmetic).
    func progression(ofPage page: Int) -> Double {
        guard totalPages > 0 else { return 0 }
        return Double(clamped(page) + 1) / Double(totalPages)
    }
}

/// One press on the slider, from touch-down to release: a drag of the thumb, a tap on a mark, or a tap on the track.
///
/// The page changes only on release. A press that starts on the thumb keeps the distance between the finger and
/// the thumb's centre, so the thumb does not jump under the finger; a press anywhere else brings the thumb to the
/// finger once it moves.
struct ProgressSliderInteraction: Equatable {
    enum Outcome: Equatable {
        case none
        case page(Int)
        /// Index into the marks handed to `ended`.
        case mark(Int)
    }

    /// Movement below this is a tap.
    static let tapSlop: CGFloat = 4

    private var startX: CGFloat?
    private var grabOffset: CGFloat = 0
    private var grabbedThumb = false
    private(set) var isDragging = false
    /// The page under the thumb while dragging; nil before the press has moved.
    private(set) var pendingPage: Int?

    var isActive: Bool { startX != nil }

    /// - Parameters:
    ///   - thumbX: the thumb's centre, nil when no page is shown (nothing to grab).
    ///   - thumbReach: how far from its centre a press still grabs the thumb.
    mutating func began(at x: CGFloat, thumbX: CGFloat?, thumbReach: CGFloat) {
        startX = x
        isDragging = false
        pendingPage = nil
        if let thumbX, abs(x - thumbX) <= thumbReach {
            grabbedThumb = true
            grabOffset = thumbX - x
        } else {
            grabbedThumb = false
            grabOffset = 0
        }
    }

    mutating func moved(to x: CGFloat, geometry: ProgressSliderGeometry) {
        guard let startX else { return }
        if !isDragging, abs(x - startX) > Self.tapSlop { isDragging = true }
        if isDragging { pendingPage = geometry.page(atX: x + grabOffset) }
    }

    /// - Parameters:
    ///   - markXs: the centres of the marks, in the order the outcome's index refers to.
    ///   - markReach: how far from its centre a tap still counts for a mark.
    mutating func ended(at x: CGFloat, geometry: ProgressSliderGeometry, currentPage: Int?, markXs: [CGFloat], markReach: CGFloat) -> Outcome {
        defer { self = ProgressSliderInteraction() }
        guard let startX else { return .none }
        if isDragging {
            let page = geometry.page(atX: x + grabOffset)
            return page == currentPage ? .none : .page(page)
        }
        // A tap. The nearest mark within reach wins over the track; the thumb wins over a mark only when the tap is
        // nearer to it. Of two marks at the same distance the later one (the newer) is taken.
        var nearest: (index: Int, distance: CGFloat)?
        for (index, markX) in markXs.enumerated() {
            let distance = abs(startX - markX)
            guard distance <= markReach else { continue }
            if nearest.map({ distance <= $0.distance }) ?? true { nearest = (index, distance) }
        }
        if let nearest, !(grabbedThumb && abs(grabOffset) < nearest.distance) { return .mark(nearest.index) }
        if grabbedThumb { return .none }
        let page = geometry.page(atX: startX)
        return page == currentPage ? .none : .page(page)
    }

    mutating func cancelled() {
        self = ProgressSliderInteraction()
    }
}

/// Sessions whose progress slider has keyboard focus. On macOS the reader observes keys with a window-wide monitor
/// (the web view is first responder most of the time), which runs before the focused view: while the slider of the
/// same session has focus, the reader leaves the arrow keys to it (`EPUBReaderView`).
@MainActor
enum ProgressSliderFocus {
    private static var focused: Set<ObjectIdentifier> = []

    static func set(_ isFocused: Bool, for session: AnyObject) {
        set(isFocused, for: ObjectIdentifier(session))
    }

    /// By identifier: for a session the slider no longer has (it was given another one).
    static func set(_ isFocused: Bool, for session: ObjectIdentifier) {
        if isFocused {
            focused.insert(session)
        } else {
            focused.remove(session)
        }
    }

    static func isFocused(_ session: AnyObject) -> Bool {
        focused.contains(ObjectIdentifier(session))
    }
}
