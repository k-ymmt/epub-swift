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

    @State private var interaction = ProgressSliderInteraction()
    /// The page the thumb stays on between the release and the end of the move it started.
    @State private var settlingPage: Int?
    @State private var moveSerial = 0
    @State private var bubbleSize: CGSize = .zero
    @GestureState private var isPressed = false
    @Environment(\.colorScheme) private var colorScheme

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

    enum Metrics {
        #if os(macOS)
        static let height: CGFloat = 22
        static let thumbDiameter: CGFloat = 16
        static let thumbReach: CGFloat = 12
        static let markDiameter: CGFloat = 7
        static let markReach: CGFloat = 10
        #else
        static let height: CGFloat = 32
        static let thumbDiameter: CGFloat = 24
        static let thumbReach: CGFloat = 22
        static let markDiameter: CGFloat = 8
        static let markReach: CGFloat = 18
        #endif
        static let trackHeight: CGFloat = 4
        static let bubbleGap: CGFloat = 10
    }

    struct PlacedMark: Equatable {
        var index: Int
        var mark: Mark
        var page: Int
        var x: CGFloat
    }

    public var body: some View {
        GeometryReader { proxy in
            let geometry = ProgressSliderGeometry(totalPages: session.pagination.totalPages, width: proxy.size.width,
                                                  inset: Metrics.thumbDiameter / 2, isRightToLeft: session.isRightToLeft)
            let placed = placedMarks(in: geometry)
            let page = interaction.pendingPage ?? settlingPage ?? session.currentPage
            let middle = proxy.size.height / 2
            ZStack(alignment: .topLeading) {
                track(geometry: geometry, page: page, middle: middle)
                // The slider itself, for assistive technologies: the whole track, adjusted in steps of a hundredth
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityValue(Text(verbatim: page.map { description(ofPage: $0, in: geometry, separator: ", ") } ?? ""))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: step(by: 1, geometry: geometry)
                        case .decrement: step(by: -1, geometry: geometry)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("ReaderProgressSlider")
                ForEach(placed, id: \.mark.id) { item in
                    Circle()
                        .fill(markColor)
                        .frame(width: Metrics.markDiameter, height: Metrics.markDiameter)
                        .frame(width: Metrics.markReach * 2, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: item.mark.label))
                        .accessibilityValue(Text(verbatim: description(ofPage: item.page, in: geometry, separator: ", ")))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { go(.mark(item.mark), showing: item.page) }
                        .accessibilityIdentifier("ReaderProgressSliderMark-\(item.index)")
                        .position(x: item.x, y: middle)
                }
                if let page {
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .frame(width: Metrics.thumbDiameter, height: Metrics.thumbDiameter)
                        .position(x: geometry.x(ofPage: page), y: middle)
                        .accessibilityHidden(true)
                }
                if interaction.isDragging, let pending = interaction.pendingPage {
                    bubble(page: pending, geometry: geometry)
                }
            }
            .contentShape(Rectangle())
            .gesture(press(geometry: geometry, placed: placed), isEnabled: geometry.totalPages > 1)
            .focusable(geometry.totalPages > 1, interactions: .activate)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                // Arrow keys follow the picture: left is towards the left edge, whichever way the book runs
                let towardsRight = press.key == .rightArrow
                step(by: towardsRight != geometry.isRightToLeft ? 1 : -1, geometry: geometry)
                return .handled
            }
        }
        .frame(height: Metrics.height)
        // Positions are computed from the book's direction, not the interface's
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .onChange(of: isPressed) { _, pressed in
            // A press the system took away (no `onEnded`). Checked one turn later: `onEnded` runs around the same time
            // as this reset and must see the press first.
            guard !pressed else { return }
            Task { @MainActor in
                guard interaction.isActive else { return }
                interaction.cancelled()
                onEditingChanged(false)
            }
        }
    }

    // MARK: Drawing

    /// The text colour, opaque: `Color.primary` is drawn translucent on a glass or material background (the track
    /// showed through the marks).
    private var markColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private func track(geometry: ProgressSliderGeometry, page: Int?, middle: CGFloat) -> some View {
        let start = geometry.x(ofPage: 0)
        let end = geometry.x(ofPage: max(0, geometry.totalPages - 1))
        let thumb = page.map { geometry.x(ofPage: $0) } ?? start
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.primary.opacity(0.18))
                .frame(width: abs(end - start) + Metrics.trackHeight, height: Metrics.trackHeight)
                .position(x: (start + end) / 2, y: middle)
            Capsule()
                .fill(.tint)
                .frame(width: abs(thumb - start) + Metrics.trackHeight, height: Metrics.trackHeight)
                .position(x: (start + thumb) / 2, y: middle)
        }
        .accessibilityHidden(true)
    }

    /// The label above the thumb while it is dragged, kept inside the slider's width.
    private func bubble(page: Int, geometry: ProgressSliderGeometry) -> some View {
        let half = bubbleSize.width / 2
        let x = min(max(geometry.x(ofPage: page), half), max(half, geometry.width - half))
        return Text(verbatim: description(ofPage: page, in: geometry, separator: " · "))
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: geometry.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { bubbleSize = $0 }
            .position(x: x, y: -(Metrics.bubbleGap + bubbleSize.height / 2))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Pages

    private func placedMarks(in geometry: ProgressSliderGeometry) -> [PlacedMark] {
        guard geometry.totalPages > 0 else { return [] }
        return marks.enumerated().compactMap { index, mark in
            guard let page = session.pageIndex(for: mark.position) else { return nil }
            return PlacedMark(index: index, mark: mark, page: page, x: geometry.x(ofPage: page))
        }
    }

    /// "Chapter · 42%": the chapter that holds the page and the part of the book the page ends at.
    private func description(ofPage page: Int, in geometry: ProgressSliderGeometry, separator: String) -> String {
        let percent = geometry.progression(ofPage: page).formatted(.percent.precision(.fractionLength(0)))
        let title = session.pagination.location(ofPageIndex: page)
            .flatMap { session.publication.chapterTitle(forSpineIndex: $0.spineIndex) }
        guard let title, !title.isEmpty else { return percent }
        return title + separator + percent
    }

    // MARK: Moves

    private func press(geometry: ProgressSliderGeometry, placed: [PlacedMark]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isPressed) { _, pressed, _ in pressed = true }
            .onChanged { value in
                if !interaction.isActive {
                    let thumb = (settlingPage ?? session.currentPage).map { geometry.x(ofPage: $0) }
                    interaction.began(at: value.startLocation.x, thumbX: thumb, thumbReach: Metrics.thumbReach)
                    onEditingChanged(true)
                }
                interaction.moved(to: value.location.x, geometry: geometry)
            }
            .onEnded { value in
                guard interaction.isActive else { return }
                let outcome = interaction.ended(at: value.location.x, geometry: geometry, currentPage: settlingPage ?? session.currentPage,
                                                markXs: placed.map(\.x), markReach: Metrics.markReach)
                onEditingChanged(false)
                switch outcome {
                case .none: break
                case .page(let page): go(.page(page), showing: page)
                case .mark(let index): go(.mark(placed[index].mark), showing: placed[index].page)
                }
            }
    }

    /// One step of the adjustable action and the arrow keys: a hundredth of the book, at least a page, forward in
    /// reading order for a positive `direction`.
    private func step(by direction: Int, geometry: ProgressSliderGeometry) {
        guard geometry.totalPages > 1, let current = settlingPage ?? session.currentPage else { return }
        let stride = max(1, geometry.totalPages / 100)
        let page = min(max(0, current + direction * stride), geometry.totalPages - 1)
        guard page != current else { return }
        go(.page(page), showing: page)
    }

    /// Starts the move and keeps the thumb at its target until the session has arrived (or a newer move started).
    private func go(_ destination: Destination, showing page: Int) {
        settlingPage = page
        moveSerial += 1
        let serial = moveSerial
        Task { @MainActor in
            if let navigate {
                await navigate(destination)
            } else {
                await session.go(to: destination)
            }
            if serial == moveSerial { settlingPage = nil }
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
