import SwiftUI
import EPUBCore
import EPUBRenderer

/// A slider over the whole book: the thumb is the visible page, and dragging it (or tapping the track) moves the
/// session there (docs/design/03-api.md §4.6).
///
/// ```swift
/// ReaderProgressSlider(session: session, marks: previousPlaces)
///     .tint(.orange)
/// ```
///
/// - The page changes when the thumb is released. While it is dragged a label above it names the chapter and the
///   part of the book under it.
/// - `marks` are places the app wants to show on the track (where the reader was before a jump, for example). A
///   tap on a mark goes to its position.
/// - A right-bound book (`ReaderSession.isRightToLeft`) runs from the right edge to the left, like its page turns.
/// - The slider draws only the track, the marks and the thumb: the bar around it and when it is shown are the app's.
///
/// Pages are `ReaderSession.pagination`'s: estimates until every chapter has been measured, so the thumb and the
/// marks can shift a little while a book is being paginated.
///
/// The control is `PageProgressSlider`, which takes page numbers instead of a session: a reader of another format
/// uses that one directly.
public struct ReaderProgressSlider: View {
    /// A place shown on the track.
    public struct Mark: Identifiable, Hashable, Sendable {
        public var id: String
        public var position: ReadingPosition
        /// What the mark is, for assistive technologies ("Previous position"). Its value is the chapter and the
        /// part of the book, which the slider adds.
        public var label: String

        public init(id: String, position: ReadingPosition, label: String) {
            self.id = id
            self.position = position
            self.label = label
        }
    }

    /// Where a release sends the session.
    public enum Destination: Hashable, Sendable {
        /// Book page (0-based, `BookPagination` numbering): the thumb was dragged or the track was tapped.
        case page(Int)
        case mark(Mark)
    }

    private let session: ReaderSession
    private let marks: [Mark]
    private let label: String
    private let navigate: (@MainActor (Destination) async -> Void)?
    private let onEditingChanged: @MainActor (Bool) -> Void

    /// Whether the slider has keyboard focus (what `PageProgressSlider` last reported).
    @State private var isFocused = false

    /// - Parameters:
    ///   - label: the slider's name for assistive technologies.
    ///   - navigate: performs the move; nil (the default) moves the session with `ReaderSession.go(to:)`. An app that
    ///     needs to know about the move before it happens passes its own and calls `go(to:)` from it.
    ///   - onEditingChanged: `true` when a press starts, `false` when it ends (released or cancelled).
    public init(session: ReaderSession, marks: [Mark] = [], label: String = "Reading Progress",
                navigate: (@MainActor (Destination) async -> Void)? = nil,
                onEditingChanged: @escaping @MainActor (Bool) -> Void = { _ in })
    {
        self.session = session
        self.marks = marks
        self.label = label
        self.navigate = navigate
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        // The control itself is `PageProgressSlider`, which knows pages only: this view reads them from the session
        // and turns what a release asks for back into a position of the book.
        PageProgressSlider(
            pages: .init(total: session.pagination.totalPages, current: session.currentPage, visible: session.visiblePages,
                         isRightToLeft: session.isRightToLeft),
            marks: marks.map { PageProgressSlider.Mark(id: $0.id, page: session.pageIndex(for: $0.position), label: $0.label) },
            label: label,
            pageTitle: { page in
                // The chapter that holds the page
                session.pagination.location(ofPageIndex: page)
                    .flatMap { session.publication.chapterTitle(forSpineIndex: $0.spineIndex) }
            },
            // Read when a step starts, not when this view was last updated: a step right after a move must start
            // from where the session is now
            visiblePages: { session.visiblePages },
            navigate: { requested in
                guard let destination = Self.destination(for: requested, among: marks) else { return }
                if let navigate {
                    await navigate(destination)
                } else {
                    await session.go(to: destination)
                }
            },
            onEditingChanged: onEditingChanged,
            onFocusChanged: { focused in
                isFocused = focused
                ProgressSliderFocus.set(focused, for: session)
            })
            .onChange(of: ObjectIdentifier(session)) { old, new in
                // The same slider with another session (the app opened another book in place)
                ProgressSliderFocus.set(false, for: old)
                ProgressSliderFocus.set(isFocused, for: new)
            }
            .onDisappear { ProgressSliderFocus.set(false, for: session) }
    }

    /// What a release of the page slider means for a session: the page, or the mark with that id (nil when the mark
    /// is not among `marks`: nothing to go to).
    static func destination(for requested: PageProgressSlider.Destination, among marks: [Mark]) -> Destination? {
        switch requested {
        case .page(let page): .page(page)
        case .mark(let id): marks.first { $0.id == id }.map(Destination.mark)
        }
    }
}

extension ReaderSession {
    /// Moves where a `ReaderProgressSlider` release points: to the book page, or to the mark's position.
    public func go(to destination: ReaderProgressSlider.Destination) async {
        switch destination {
        case .page(let page): await go(toPage: page)
        case .mark(let mark): await go(to: mark.position)
        }
    }
}
