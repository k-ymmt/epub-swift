import SwiftUI
import EPUBCore
import EPUBRenderer

/// Shows a `ReaderSession` with page-turn effects and the standard gestures (docs/design/03-api.md §4.1).
///
/// ```swift
/// EPUBReaderView(session: session)
///     .pageTransition(.slide)
///     .readerGestures(.default)
///     .onReaderEvent { event in ... }
/// ```
public struct EPUBReaderView: View {
    private let session: ReaderSession

    @Environment(\.pageTransition) private var transition
    @Environment(\.readerGestures) private var gestures
    @Environment(\.readerEventHandler) private var eventHandler

    @State private var turn = PageTurnController()

    public init(session: ReaderSession) {
        self.session = session
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            platformView
            if let context = turn.context(size: session.viewportSize, layoutDirection: layoutDirection) {
                transition.body(context)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(session.settings.theme.background))
        .contentShape(Rectangle())
        .gesture(dragGesture, isEnabled: gestures.swipeEnabled)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            guard size.width > 0, size.height > 0 else { return }
            session.viewportSize = size
            Task { await session.loadIfNeeded() }
        }
        .task(id: ObjectIdentifier(session)) {
            turn.configure(session: session, transition: transition)
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
            onKey: { command in
                guard gestures.keyboardEnabled else { return }
                Task { await turn.turn(command == .forward ? .forward : .backward) }
            },
            onScrollPhase: { event in
                guard gestures.swipeEnabled else { return }
                turn.handleScroll(event, layoutDirection: layoutDirection)
            }
        )
        #endif
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
            guard gestures.tapToTurnEnabled, !turn.isActive else { return }
            switch zone {
            case .leading:
                Task { await turn.turn(layoutDirection == .rightToLeft ? .forward : .backward) }
            case .trailing:
                Task { await turn.turn(layoutDirection == .rightToLeft ? .backward : .forward) }
            case .center:
                break
            }
        default:
            eventHandler?.handle(event)
        }
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
    @ObservationIgnored private var scrollAccumulator: CGFloat = 0
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
    /// Two-finger trackpad swipe: accumulates the horizontal delta while the gesture is active and commits when it
    /// exceeds a quarter page, mapped onto the same interactive turn as a drag.
    func handleScroll(_ event: ScrollPhaseEvent, layoutDirection: LayoutDirection) {
        switch event.phase {
        case .began:
            scrollAccumulator = 0
            scrollTurnStarted = false
        case .changed:
            scrollAccumulator += event.deltaX
            guard abs(scrollAccumulator) > 8 else { return }
            scrollTurnStarted = true
            dragChanged(translation: CGSize(width: scrollAccumulator, height: 0), layoutDirection: layoutDirection)
        case .ended, .cancelled:
            guard scrollTurnStarted else { return }
            scrollTurnStarted = false
            dragEnded(translation: CGSize(width: scrollAccumulator, height: 0), predictedTranslation: CGSize(width: scrollAccumulator * 2, height: 0), layoutDirection: layoutDirection)
            scrollAccumulator = 0
        case .momentum, .other:
            break
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
