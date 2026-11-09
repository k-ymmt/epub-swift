import Foundation

/// A key the reader view handles (docs/design/03-api.md §4.3, M5). Platform-independent so that the mapping to
/// page moves can be tested without events.
enum ReaderKey: Sendable, Hashable {
    case left, right, up, down, pageUp, pageDown, space, shiftSpace, home, end
}

/// What a key does to the session.
enum ReaderKeyAction: Sendable, Hashable {
    case forward, backward
    /// First / last page of the current chapter (face).
    case chapterStart, chapterEnd
}

extension ReaderKey {
    /// The move for this key in a book that progresses left-to-right or right-to-left (`ReaderSession.isRightToLeft`:
    /// `page-progression-direction="rtl"`, or vertical-rl writing by default). The horizontal arrows follow the
    /// page progression (in a right-bound book the next page is to the left); the vertical arrows, page keys and
    /// space always mean "next" / "previous".
    func action(isRightToLeft: Bool) -> ReaderKeyAction {
        switch self {
        case .right: return isRightToLeft ? .backward : .forward
        case .left: return isRightToLeft ? .forward : .backward
        case .down, .pageDown, .space: return .forward
        case .up, .pageUp, .shiftSpace: return .backward
        case .home: return .chapterStart
        case .end: return .chapterEnd
        }
    }
}

#if canImport(AppKit)
import AppKit

extension ReaderKey {
    /// The reader key for a key-down event; nil for other keys and for chords (⌘ / ⌥ / ⌃, or ⇧ with anything but
    /// space, which extends a text selection).
    init?(event: NSEvent) {
        self.init(charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", modifierFlags: event.modifierFlags)
    }

    init?(charactersIgnoringModifiers chars: String, modifierFlags: NSEvent.ModifierFlags) {
        let modifiers = modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.intersection([.command, .option, .control]).isEmpty, let scalar = chars.unicodeScalars.first else { return nil }
        let shift = modifiers.contains(.shift)
        switch Int(scalar.value) {
        case 0x20: self = shift ? .shiftSpace : .space
        case _ where shift: return nil
        case NSRightArrowFunctionKey: self = .right
        case NSLeftArrowFunctionKey: self = .left
        case NSUpArrowFunctionKey: self = .up
        case NSDownArrowFunctionKey: self = .down
        case NSPageUpFunctionKey: self = .pageUp
        case NSPageDownFunctionKey: self = .pageDown
        case NSHomeFunctionKey: self = .home
        case NSEndFunctionKey: self = .end
        default: return nil
        }
    }
}

/// Trackpad scroll sample with its gesture phase (docs/design/03-api.md §4.3).
struct ScrollPhaseEvent {
    enum Phase { case began, changed, ended, cancelled, momentum, other }
    var phase: Phase
    /// Finger movement in points: positive when the fingers move right / down, whatever the "natural scrolling"
    /// setting (AppKit's scrolling deltas follow the content, which that setting inverts).
    var deltaX: CGFloat
    var deltaY: CGFloat

    init(phase: Phase, deltaX: CGFloat, deltaY: CGFloat) {
        self.phase = phase
        self.deltaX = deltaX
        self.deltaY = deltaY
    }

    init(event: NSEvent) {
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.momentumPhase != [] { phase = .momentum }
        else { phase = .other }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        deltaX = event.scrollingDeltaX * sign
        deltaY = event.scrollingDeltaY * sign
    }
}
#endif
