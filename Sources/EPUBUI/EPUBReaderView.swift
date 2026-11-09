import SwiftUI
import EPUBCore
import EPUBRenderer

/// Shows a `ReaderSession` with page-turn effects and the standard gestures (docs/design/03-api.md §4.1).
///
/// ```swift
/// EPUBReaderView(session: session)
///     .pageTransition(.slide)
///     .readerGestures(.default)
///     .selectionActions([SelectionAction(title: "Highlight", systemImage: "highlighter") { selected in ... }])
///     .onReaderEvent { event in ... }
/// ```
public struct EPUBReaderView: View {
    private let session: ReaderSession

    @Environment(\.pageTransition) private var transition
    @Environment(\.readerGestures) private var gestures
    @Environment(\.readerEventHandler) private var eventHandler
    @Environment(\.selectionActions) private var selectionActions

    @State private var turn = PageTurnController()

    public init(session: ReaderSession) {
        self.session = session
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            platformView
            if let snapshot = session.relayoutSnapshot {
                // The page as it was before a resize or settings change, until the position is restored in the new
                // layout (03-api §4.5). Anchored top-leading so the text the reader was looking at stays put.
                Image(decorative: snapshot.image, scale: snapshot.scale)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: session.viewportSize.width, height: session.viewportSize.height, alignment: .topLeading)
                    .clipped()
                    .background(Color(session.settings.theme.background))
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let context = turn.context(size: session.viewportSize, layoutDirection: layoutDirection) {
                transition.body(context)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(session.settings.theme.background))
        .animation(.easeOut(duration: 0.2), value: session.relayoutSnapshot == nil)
        .contentShape(Rectangle())
        // While a fixed-layout page is zoomed in, drags pan the page instead of turning it (02-rendering §6.3, M4).
        .gesture(dragGesture, isEnabled: gestures.swipeEnabled && !session.isZoomed)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            guard size.width > 0, size.height > 0 else { return }
            session.viewportSize = size
            Task { await session.loadIfNeeded() }
        }
        .onChange(of: selectionActions.map(\.id), initial: true) { _, _ in
            session.selectionActions = selectionActions
        }
        .task(id: ObjectIdentifier(session)) {
            turn.configure(session: session, transition: transition)
            session.selectionActions = selectionActions
            for await event in session.events {
                handle(event)
            }
        }
        .onChange(of: transition.duration) { _, _ in
            turn.configure(session: session, transition: transition)
        }
    }

    /// Right-bound books (`page-progression-direction="rtl"`, vertical writing) turn pages the other way
    /// (docs/design/03-api.md §4.3).
    private var layoutDirection: LayoutDirection {
        session.isRightToLeft ? .rightToLeft : .leftToRight
    }

    @ViewBuilder private var platformView: some View {
        #if canImport(UIKit)
        ReaderPlatformView(session: session)
        #else
        ReaderPlatformView(
            session: session,
            onKey: { key in
                // While a fixed-layout face is zoomed in the keys are left to the web view (M4 / M5).
                guard gestures.keyboardEnabled, session.hasLoaded, !session.isZoomed else { return false }
                perform(key.action(isRightToLeft: session.isRightToLeft))
                return true
            },
            onScrollPhase: { event in
                guard gestures.swipeEnabled, !session.isZoomed else { return false }
                return turn.handleScroll(event, layoutDirection: layoutDirection)
            }
        )
        #endif
    }

    /// Keyboard moves (03-api §4.3, M5): page turns go through the turn controller (with the effect); chapter
    /// start / end jump without one.
    private func perform(_ action: ReaderKeyAction) {
        switch action {
        case .forward:
            Task { await turn.turn(.forward) }
        case .backward:
            Task { await turn.turn(.backward) }
        case .chapterStart:
            guard !turn.isActive else { return }
            Task { await session.go(toPageInChapter: 0) }
        case .chapterEnd:
            guard !turn.isActive else { return }
            Task { await session.go(toPageInChapter: max(0, session.chapterPageCount - 1)) }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                turn.dragChanged(translation: value.translation, layoutDirection: layoutDirection)
            }
            .onEnded { value in
                turn.dragEnded(translation: value.translation, predictedTranslation: value.predictedEndTranslation, layoutDirection: layoutDirection)
            }
    }

    private func handle(_ event: ReaderEvent) {
        switch event {
        case .tapped(let point, _):
            let zone = gestures.tapZones.zone(forX: point.x, width: session.viewportSize.width)
            eventHandler?.handle(.tapped(point, zone: zone))
            turnForTap(in: zone)
        case .imageTapped(let image):
            // A picture that fills the page (a cover, an illustration) would otherwise swallow every tap: in a side
            // zone the tap turns the page as anywhere else, and only a tap in the centre opens the image (M5).
            let zone = gestures.tapZones.zone(forX: image.point.x, width: session.viewportSize.width)
            if zone != .center, turnForTap(in: zone) { return }
            eventHandler?.handle(event)
        default:
            eventHandler?.handle(event)
        }
    }

    /// Turns the page for a tap in a side zone. Returns false when tap-to-turn does not apply (centre, disabled,
    /// zoomed in, a turn already running).
    @discardableResult
    private func turnForTap(in zone: TapZone) -> Bool {
        guard gestures.tapToTurnEnabled, !session.isZoomed else { return false }
        let direction: PageDirection
        switch zone {
        case .leading: direction = layoutDirection == .rightToLeft ? .forward : .backward
        case .trailing: direction = layoutDirection == .rightToLeft ? .backward : .forward
        case .center: return false
        }
        guard !turn.isActive else { return true }
        Task { await turn.turn(direction) }
        return true
    }
}

// MARK: - Page turn controller

/// Owns the transition state: snapshots, progress, and the animation that drives them
/// (docs/design/02-rendering.md §7.2).
@MainActor
@Observable
final class PageTurnController {
    struct Turn {
        var from: Image
        var to: Image
        var direction: PageDirection
        var progress: Double
        var isInteractive: Bool
        /// `to` is a placeholder until the destination chapter has loaded.
        var destinationPending: Bool
    }

    private(set) var current: Turn?
    @ObservationIgnored private weak var session: ReaderSession?
    @ObservationIgnored private var transition = AnyPageTransition(SlidePageTransition())
    @ObservationIgnored private var isBusy = false
    @ObservationIgnored private var interactivePreparation: Task<Void, Never>?
    @ObservationIgnored private var scrollAccumulator: CGSize = .zero
    /// Axis the current trackpad gesture was locked to; nil until it has moved far enough to tell.
    @ObservationIgnored private var scrollAxisIsHorizontal: Bool?
    @ObservationIgnored private var scrollTurnStarted = false

    var isActive: Bool { current != nil || isBusy }

    func configure(session: ReaderSession, transition: AnyPageTransition) {
        self.session = session
        self.transition = transition
    }

    func context(size: CGSize, layoutDirection: LayoutDirection) -> PageTransitionContext? {
        guard let current, size.width > 0 else { return nil }
        return PageTransitionContext(
            from: current.from,
            to: current.to,
            direction: current.direction,
            progress: current.progress,
            axis: .horizontal,
            layoutDirection: layoutDirection,
            size: size,
            isInteractive: current.isInteractive
        )
    }

    // MARK: Programmatic turn

    /// Turns one page with the animation. Within a chapter the destination snapshot is taken first and the web
    /// view scrolls behind the animation; across chapters the current page stays on top until the next chapter is
    /// ready, then the animation runs with the real destination.
    func turn(_ direction: PageDirection) async {
        guard let session, !isBusy, session.hasLoaded, !session.isLoading else { return }
        if direction == .forward, session.isAtEnd { return }
        if direction == .backward, session.isAtStart { return }
        isBusy = true
        defer { isBusy = false }

        let from = await session.pageSnapshot(.current)
        let destination = await session.pageSnapshot(direction == .forward ? .next : .previous)
        guard let from else {
            // No snapshot (e.g. not yet visible): navigate without an effect.
            await navigate(direction)
            return
        }
        if let destination {
            current = Turn(from: image(from), to: image(destination), direction: direction, progress: 0, isInteractive: false, destinationPending: false)
            async let navigation: Void = navigate(direction)
            await animateProgress(to: 1)
            await navigation
        } else {
            current = Turn(from: image(from), to: blankImage(), direction: direction, progress: 0, isInteractive: false, destinationPending: true)
            await navigate(direction)
            if let arrived = await session.pageSnapshot(.current) {
                current?.to = image(arrived)
            }
            current?.destinationPending = false
            await animateProgress(to: 1)
        }
        current = nil
    }

    private func navigate(_ direction: PageDirection) async {
        guard let session else { return }
        if direction == .forward { await session.goForward() } else { await session.goBackward() }
    }

    // MARK: Interactive drag

    func dragChanged(translation: CGSize, layoutDirection: LayoutDirection) {
        guard let session, session.hasLoaded else { return }
        let width = max(1, session.viewportSize.width)
        if current == nil {
            guard !isBusy, interactivePreparation == nil else { return }
            guard abs(translation.width) > abs(translation.height) else { return }
            let direction = direction(forDragX: translation.width, layoutDirection: layoutDirection)
            if direction == .forward, session.isAtEnd { return }
            if direction == .backward, session.isAtStart { return }
            isBusy = true
            interactivePreparation = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.interactivePreparation = nil }
                let from = await session.pageSnapshot(.current)
                let destination = await session.pageSnapshot(direction == .forward ? .next : .previous)
                guard let from, self.isBusy, !Task.isCancelled else { self.isBusy = false; return }
                self.current = Turn(
                    from: self.image(from),
                    to: destination.map { self.image($0) } ?? self.blankImage(),
                    direction: direction,
                    progress: 0,
                    isInteractive: true,
                    destinationPending: destination == nil
                )
            }
            return
        }
        guard var turn = current, turn.isInteractive else { return }
        let expectedSign: CGFloat = turn.direction == direction(forDragX: -1, layoutDirection: layoutDirection) ? -1 : 1
        let along = translation.width * expectedSign
        turn.progress = min(1, max(0, Double(along / width)))
        current = turn
    }

    func dragEnded(translation: CGSize, predictedTranslation: CGSize, layoutDirection: LayoutDirection) {
        if current == nil {
            // The snapshot preparation may still be running: cancel it and treat as a plain swipe.
            if let preparation = interactivePreparation {
                preparation.cancel()
                interactivePreparation = nil
                isBusy = false
                guard abs(translation.width) > 40, abs(translation.width) > abs(translation.height) else { return }
                let direction = direction(forDragX: translation.width, layoutDirection: layoutDirection)
                Task { await turn(direction) }
            }
            return
        }
        guard let turn = current, turn.isInteractive else { return }
        let width = max(1, session?.viewportSize.width ?? 1)
        let expectedSign: CGFloat = turn.direction == direction(forDragX: -1, layoutDirection: layoutDirection) ? -1 : 1
        let predicted = Double(predictedTranslation.width * expectedSign / width)
        let commit = turn.progress > 0.3 || predicted > 0.6
        Task { await finishInteractive(commit: commit) }
    }

    private func finishInteractive(commit: Bool) async {
        guard var turn = current else { isBusy = false; return }
        turn.isInteractive = false
        current = turn
        defer {
            current = nil
            isBusy = false
        }
        guard commit, let session else {
            await animateProgress(to: 0)
            return
        }
        if turn.destinationPending {
            await navigate(turn.direction)
            if let arrived = await session.pageSnapshot(.current) {
                current?.to = image(arrived)
            }
            current?.destinationPending = false
            await animateProgress(to: 1)
        } else {
            async let navigation: Void = navigate(turn.direction)
            await animateProgress(to: 1)
            await navigation
        }
    }

    #if canImport(AppKit)
    /// Two-finger trackpad swipe (03-api §4.3): once the fingers have moved a few points the gesture is locked to an
    /// axis; a horizontal one drives the same interactive turn as a drag and commits (or cancels) when the fingers
    /// lift. Momentum events after that are swallowed, so one swipe turns at most one page. Returns whether the event
    /// was used (the web view then does not see it).
    func handleScroll(_ event: ScrollPhaseEvent, layoutDirection: LayoutDirection) -> Bool {
        switch event.phase {
        case .began:
            scrollAccumulator = .zero
            scrollAxisIsHorizontal = nil
            scrollTurnStarted = false
            return false
        case .changed:
            scrollAccumulator.width += event.deltaX
            scrollAccumulator.height += event.deltaY
            if scrollAxisIsHorizontal == nil, hypot(scrollAccumulator.width, scrollAccumulator.height) > 6 {
                scrollAxisIsHorizontal = abs(scrollAccumulator.width) > abs(scrollAccumulator.height) * 1.2
            }
            guard scrollAxisIsHorizontal == true else { return false }
            scrollTurnStarted = true
            dragChanged(translation: CGSize(width: scrollAccumulator.width, height: 0), layoutDirection: layoutDirection)
            return true
        case .ended, .cancelled:
            defer { scrollAccumulator = .zero }
            guard scrollTurnStarted else { return false }
            scrollTurnStarted = false
            let translation = CGSize(width: event.phase == .cancelled ? 0 : scrollAccumulator.width, height: 0)
            dragEnded(translation: translation, predictedTranslation: CGSize(width: translation.width * 2, height: 0), layoutDirection: layoutDirection)
            return true
        case .momentum:
            return scrollAxisIsHorizontal == true
        case .other:
            return false
        }
    }
    #endif

    private func direction(forDragX x: CGFloat, layoutDirection: LayoutDirection) -> PageDirection {
        let leftward = x < 0
        switch layoutDirection {
        case .rightToLeft: return leftward ? .backward : .forward
        default: return leftward ? .forward : .backward
        }
    }

    // MARK: Animation

    private func animateProgress(to target: Double) async {
        guard current != nil else { return }
        let duration = transition.duration
        if duration <= 0 {
            current?.progress = target
            return
        }
        let remaining = abs((current?.progress ?? 0) - target)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withAnimation(.easeInOut(duration: duration * max(0.3, remaining)), completionCriteria: .logicallyComplete) {
                current?.progress = target
            } completion: {
                continuation.resume()
            }
        }
    }

    // MARK: Images

    private func image(_ snapshot: PageSnapshot) -> Image {
        Image(decorative: snapshot.image, scale: snapshot.scale)
    }

    private func blankImage() -> Image {
        let color = session?.settings.theme.background ?? ReaderTheme.light.background
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixel: [UInt8] = [UInt8(color.red * 255), UInt8(color.green * 255), UInt8(color.blue * 255), 255]
        let image = pixel.withUnsafeMutableBytes { bytes -> CGImage? in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        if let image { return Image(decorative: image, scale: 1) }
        return Image(systemName: "square.fill")
    }
}
