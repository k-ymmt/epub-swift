import SwiftUI

/// A slider over the pages of a book, for a reader of any format (docs/design/03-api.md §4.7): the thumb is the visible
/// page, and dragging it (or tapping the track) asks the app to go there.
///
/// ```swift
/// PageProgressSlider(pages: .init(total: document.pageCount, current: page, visible: [page]),
///                    marks: previousPlaces,
///                    pageTitle: { outline.title(ofPage: $0) },
///                    navigate: { destination in await reader.go(to: destination) })
/// ```
///
/// This is the control `ReaderProgressSlider` draws for an EPUB `ReaderSession`. It takes plain page numbers instead
/// of a session and reading positions, so it has nothing of EPUB in it: the app says how many pages there are, which
/// one is shown, and performs the move.
///
/// - The page changes when the thumb is released. While it is dragged a label above it names the page
///   (`pageTitle`) and the part of the book under it.
/// - `marks` are places the app wants to show on the track. A tap on a mark asks for `.mark(id:)`.
/// - A right-bound book (`Pages.isRightToLeft`) runs from the right edge to the left.
/// - The slider draws only the track, the marks and the thumb: the bar around it and when it is shown are the app's.
public struct PageProgressSlider: View {
    /// The book as the slider sees it. Pages are 0-based.
    public struct Pages: Equatable, Sendable {
        /// How many pages the book has. With fewer than two the slider cannot be moved.
        public var total: Int
        /// The page the thumb sits on; nil when no page is shown (the thumb is not drawn).
        public var current: Int?
        /// Every page on screen, in order (both pages of a spread). One step of the keyboard or of assistive
        /// technologies starts from these, so it always leaves what is shown. Empty: nothing to step from.
        public var visible: [Int]
        /// The book runs from the right edge to the left.
        public var isRightToLeft: Bool

        public init(total: Int, current: Int?, visible: [Int], isRightToLeft: Bool = false) {
            self.total = total
            self.current = current
            self.visible = visible
            self.isRightToLeft = isRightToLeft
        }
    }

    /// A place shown on the track.
    public struct Mark: Identifiable, Hashable, Sendable {
        public var id: String
        /// The page the mark is on; nil when the app does not know it (yet). Such a mark is not drawn, but it keeps
        /// its place in `marks`, so the accessibility identifiers of the others do not change.
        public var page: Int?
        /// What the mark is, for assistive technologies ("Previous position"). Its value is the page's title and the
        /// part of the book, which the slider adds.
        public var label: String

        public init(id: String, page: Int?, label: String) {
            self.id = id
            self.page = page
            self.label = label
        }
    }

    /// Where a release asks the app to go.
    public enum Destination: Hashable, Sendable {
        /// Page (0-based): the thumb was dragged or the track was tapped.
        case page(Int)
        /// The mark with this id was tapped.
        case mark(id: String)
    }

    private let pages: Pages
    private let marks: [Mark]
    private let label: String
    private let pageTitle: @MainActor (Int) -> String?
    private let visiblePages: (@MainActor () -> [Int])?
    private let navigate: @MainActor (Destination) async -> Void
    private let onEditingChanged: @MainActor (Bool) -> Void
    private let onFocusChanged: @MainActor (Bool) -> Void

    @State private var interaction = ProgressSliderInteraction()
    /// The page the thumb stays on between the release and the end of the move it started.
    @State private var settlingPage: Int?
    @State private var moveSerial = 0
    /// The last move started; the next one waits for it, so moves happen in the order of the releases even when
    /// the app's `navigate` awaits something of its own first.
    @State private var lastMove: Task<Void, Never>?
    /// Counts presses: a cancellation noticed for one press must not end the next.
    @State private var pressSerial = 0
    @State private var bubbleSize: CGSize = .zero
    @GestureState private var isPressed = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - label: the slider's name for assistive technologies.
    ///   - pageTitle: what a page is called next to the part of the book ("Chapter 3 · 42%"): the chapter that holds
    ///     it, for example. nil or empty shows the percentage alone. It is only asked about pages of the book
    ///     (`0..<pages.total`): a mark or a move in flight that points outside is described as the nearest page, which
    ///     is also where it is drawn.
    ///   - visiblePages: the pages on screen, read at the moment a step of the keyboard or of assistive technologies
    ///     starts. nil (the default) uses `pages.visible`, which is what the view was last updated with: a step that
    ///     arrives after `navigate` has returned and before SwiftUI has updated the view then starts from the pages
    ///     of before the move. A reader whose state the closure can read directly passes it.
    ///   - navigate: performs the move. Moves are started one at a time, in the order of the releases: the next one
    ///     waits until this returns.
    ///   - onEditingChanged: `true` when a press starts, `false` when it ends (released or cancelled).
    ///   - onFocusChanged: the slider took or lost keyboard focus; also called with `false` when the slider goes
    ///     away. A reader that handles the arrow keys itself leaves them to the slider while it has focus.
    public init(pages: Pages, marks: [Mark] = [], label: String = "Reading Progress",
                pageTitle: @escaping @MainActor (Int) -> String? = { _ in nil },
                visiblePages: (@MainActor () -> [Int])? = nil,
                navigate: @escaping @MainActor (Destination) async -> Void,
                onEditingChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                onFocusChanged: @escaping @MainActor (Bool) -> Void = { _ in })
    {
        self.pages = pages
        self.marks = marks
        self.label = label
        self.pageTitle = pageTitle
        self.visiblePages = visiblePages
        self.navigate = navigate
        self.onEditingChanged = onEditingChanged
        self.onFocusChanged = onFocusChanged
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

    /// A mark that has a place on the track.
    struct PlacedMark: Equatable {
        /// Its index in `marks` (the accessibility identifier).
        var index: Int
        var mark: Mark
        var page: Int
        var x: CGFloat
    }

    public var body: some View {
        GeometryReader { proxy in
            let geometry = ProgressSliderGeometry(totalPages: pages.total, width: proxy.size.width,
                                                  inset: Metrics.thumbDiameter / 2, isRightToLeft: pages.isRightToLeft)
            let placed = Self.placedMarks(marks, in: geometry)
            let page = interaction.pendingPage ?? settlingPage ?? pages.current
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
                        .accessibilityAction { go(.mark(id: item.mark.id), showing: item.page) }
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
            .focused($isFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                // Arrow keys follow the picture: left is towards the left edge, whichever way the book runs. A key
                // that cannot move (no page shown) is left to whoever else wants it.
                let towardsRight = press.key == .rightArrow
                return step(by: towardsRight != geometry.isRightToLeft ? 1 : -1, geometry: geometry) ? .handled : .ignored
            }
        }
        .frame(height: Metrics.height)
        // Positions are computed from the book's direction, not the interface's
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .onChange(of: isPressed) { _, pressed in
            // A press the system took away (no `onEnded`). Checked one turn later: `onEnded` runs around the same time
            // as this reset and must see the press first. Only the press that was taken away is ended: a new one
            // may have started by then.
            guard !pressed else { return }
            let press = pressSerial
            Task { @MainActor in
                guard press == pressSerial else { return }
                endPressWithoutMoving()
            }
        }
        .onChange(of: isFocused) { _, focused in onFocusChanged(focused) }
        .onDisappear {
            // Removed while pressed (the app hid its bar) or focused: neither `onEnded` nor the reset above runs
            endPressWithoutMoving()
            onFocusChanged(false)
        }
    }

    private func endPressWithoutMoving() {
        guard interaction.isActive else { return }
        interaction.cancelled()
        onEditingChanged(false)
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
            // As wide as its text, at most the slider's width (a long title is truncated). `fixedSize` after the
            // frame: without it the frame takes the whole proposed width, the measured width is the slider's, and
            // the label sits in the middle of the track instead of above the thumb.
            .frame(maxWidth: geometry.width)
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { bubbleSize = $0 }
            .position(x: x, y: -(Metrics.bubbleGap + bubbleSize.height / 2))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Pages

    /// The marks that can be drawn: those with a page, in a book that has pages. `index` stays the mark's index in
    /// `marks`.
    static func placedMarks(_ marks: [Mark], in geometry: ProgressSliderGeometry) -> [PlacedMark] {
        guard geometry.totalPages > 0 else { return [] }
        return marks.enumerated().compactMap { index, mark in
            guard let page = mark.page else { return nil }
            return PlacedMark(index: index, mark: mark, page: page, x: geometry.x(ofPage: page))
        }
    }

    /// "Chapter · 42%": the page's title and the part of the book the page ends at.
    private func description(ofPage page: Int, in geometry: ProgressSliderGeometry, separator: String) -> String {
        let title = Self.titledPage(page, totalPages: geometry.totalPages).flatMap { pageTitle($0) }
        return Self.description(title: title, progression: geometry.progression(ofPage: page), separator: separator)
    }

    /// The page whose title describes `page`: the nearest page of the book, like the place it is drawn at. A mark
    /// can point past the end, and so can the page of a move in flight after the book got shorter; the app's
    /// `pageTitle` (an array lookup, say) is never asked about a page that does not exist. nil: the book has no pages.
    static func titledPage(_ page: Int, totalPages: Int) -> Int? {
        guard totalPages > 0 else { return nil }
        return min(max(page, 0), totalPages - 1)
    }

    static func description(title: String?, progression: Double, separator: String) -> String {
        let percent = progression.formatted(.percent.precision(.fractionLength(0)))
        guard let title, !title.isEmpty else { return percent }
        return title + separator + percent
    }

    /// The pages a step starts from: the page a move in flight is heading for; otherwise what is visible (both pages
    /// of a spread, so a step never lands on the page next to the one counted as current). nil: nothing is shown.
    static func stepOrigin(settlingPage: Int?, visible: [Int]) -> ClosedRange<Int>? {
        if let settlingPage { return settlingPage...settlingPage }
        guard let first = visible.first, let last = visible.last, first <= last else { return nil }
        return first...last
    }

    // MARK: Moves

    private func press(geometry: ProgressSliderGeometry, placed: [PlacedMark]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($isPressed) { _, pressed, _ in pressed = true }
            .onChanged { value in
                if !interaction.isActive {
                    let thumb = (settlingPage ?? pages.current).map { geometry.x(ofPage: $0) }
                    interaction.began(at: value.startLocation.x, thumbX: thumb, thumbReach: Metrics.thumbReach)
                    pressSerial += 1
                    onEditingChanged(true)
                }
                interaction.moved(to: value.location.x, geometry: geometry)
            }
            .onEnded { value in
                guard interaction.isActive else { return }
                let outcome = interaction.ended(at: value.location.x, geometry: geometry, currentPage: settlingPage ?? pages.current,
                                                markXs: placed.map(\.x), markReach: Metrics.markReach)
                onEditingChanged(false)
                switch outcome {
                case .none: break
                case .page(let page): go(.page(page), showing: page)
                case .mark(let index): go(.mark(id: placed[index].mark.id), showing: placed[index].page)
                }
            }
    }

    /// One step of the adjustable action and the arrow keys: a hundredth of the book, at least a page, forward in
    /// reading order for a positive `direction`. Returns whether there was somewhere to go.
    @discardableResult
    private func step(by direction: Int, geometry: ProgressSliderGeometry) -> Bool {
        guard let origin = Self.stepOrigin(settlingPage: settlingPage, visible: visiblePages?() ?? pages.visible),
              let page = geometry.page(steppingFrom: origin, by: direction)
        else { return false }
        go(.page(page), showing: page)
        return true
    }

    /// Starts the move and keeps the thumb at its target until the app has arrived (or a newer move started).
    /// Moves run one after the other, in the order they were started.
    private func go(_ destination: Destination, showing page: Int) {
        settlingPage = page
        moveSerial += 1
        let serial = moveSerial
        let previous = lastMove
        lastMove = Task { @MainActor in
            await previous?.value
            await navigate(destination)
            if serial == moveSerial {
                settlingPage = nil
                lastMove = nil
            }
        }
    }
}
