import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether the reader's hands are scrolling the scrolled layout (docs/design/08-continuous-scroll.md §5.6). While
/// they are, the scroll position belongs to them: the scroll controller writes it only at rest. "No scroll event for
/// 150 ms" is not rest (a finger held still passes that test), so each platform reports what it knows: iOS the scroll
/// view's tracking / dragging / decelerating flags, macOS the phases of the scroll-wheel events (this type).
///
/// A trackpad gesture is active from its `began` to its `ended`, and on through the momentum events that follow; the
/// short gap between the gesture's end and the momentum's start counts too. A wheel without phases (a mouse) is
/// active until 150 ms after its last event.
///
/// `stop` ends the interaction early (a jump or a relayout is about to write the scroll position): the rest of the
/// gesture and of its momentum is withheld from the web view, up to the event that ends each phase.
struct WheelInteraction: Equatable {
    enum Phase: Equatable {
        case none, mayBegin, began, changed, ended, cancelled
    }

    struct Event: Equatable {
        var phase: Phase = .none
        var momentumPhase: Phase = .none
        /// Seconds on any monotonic clock.
        var time: TimeInterval
    }

    /// A wheel without phases keeps the interaction active this long after its last event.
    static let phaselessTail: TimeInterval = 0.15
    /// After a gesture ends, its momentum may start within this time.
    static let momentumGrace: TimeInterval = 0.1

    private(set) var gestureActive = false
    private(set) var momentumActive = false
    /// The interaction stays active until this time without any phase being open.
    private(set) var activeUntil: TimeInterval?
    /// `stop` was called during a gesture or its momentum: the remaining events are not delivered.
    private(set) var isWithholding = false
    /// Events of a wheel without phases are not delivered before this time (`stop` during such a wheel's tail).
    private(set) var withholdUntil: TimeInterval?

    func isActive(at time: TimeInterval) -> Bool {
        if isWithholding { return false }
        if gestureActive || momentumActive { return true }
        if let activeUntil, time < activeUntil { return true }
        return false
    }

    /// When the active state can change without another event (the caller sets a timer), if at all.
    func deadline(after time: TimeInterval) -> TimeInterval? {
        guard !isWithholding, !gestureActive, !momentumActive, let activeUntil, activeUntil > time else { return nil }
        return activeUntil
    }

    /// Takes one scroll-wheel event. Returns whether the web view gets it.
    mutating func handle(_ event: Event) -> Bool {
        if event.momentumPhase != .none {
            switch event.momentumPhase {
            case .began, .changed, .mayBegin:
                momentumActive = true
                activeUntil = nil
                return !isWithholding
            case .ended, .cancelled:
                momentumActive = false
                activeUntil = nil
                // The event that closes the momentum is delivered even while withholding, so the web view sees the
                // sequence end; nothing after it is withheld.
                isWithholding = false
                withholdUntil = nil
                return true
            case .none:
                return true
            }
        }
        switch event.phase {
        case .mayBegin, .began:
            // A new gesture: whatever was withheld belonged to the previous one.
            isWithholding = false
            withholdUntil = nil
            gestureActive = true
            momentumActive = false
            activeUntil = nil
            return true
        case .changed:
            gestureActive = true
            return !isWithholding
        case .ended, .cancelled:
            gestureActive = false
            if isWithholding {
                // The momentum of a stopped gesture is withheld too; without one the withholding ends with the grace.
                activeUntil = nil
                withholdUntil = event.time + Self.momentumGrace
            } else {
                activeUntil = event.time + Self.momentumGrace
            }
            return true
        case .none:
            if let withholdUntil, event.time < withholdUntil { return false }
            expireWithholding(at: event.time)
            guard !isWithholding else { return false }
            activeUntil = event.time + Self.phaselessTail
            return true
        }
    }

    /// Ends the interaction now. Returns whether anything was in progress.
    @discardableResult
    mutating func stop(at time: TimeInterval) -> Bool {
        expireWithholding(at: time)
        if gestureActive || momentumActive {
            isWithholding = true
            activeUntil = nil
            return true
        }
        if let activeUntil, time < activeUntil {
            // Either the gap before a momentum (withhold it when it comes) or the tail of a wheel without phases.
            isWithholding = true
            withholdUntil = activeUntil
            self.activeUntil = nil
            return true
        }
        return false
    }

    /// A stopped gesture whose momentum never came, or the tail of a stopped phaseless wheel: withholding ends.
    mutating func expireWithholding(at time: TimeInterval) {
        guard isWithholding, !gestureActive, !momentumActive, let withholdUntil, time >= withholdUntil else { return }
        isWithholding = false
        self.withholdUntil = nil
    }
}

/// The scroll view's state on iOS, reduced to the one question the scroll controller asks (§5.6).
enum ScrollViewInteraction {
    static func isActive(isTracking: Bool, isDragging: Bool, isDecelerating: Bool) -> Bool {
        isTracking || isDragging || isDecelerating
    }
}

/// Whether VoiceOver is running: the scrolled layout then keeps the chapters far from the viewport in its window, so
/// the reading cursor is not pulled out from under it (docs/design/08-continuous-scroll.md §5.1).
@MainActor
enum ScreenReader {
    static var isRunning: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning
        #elseif canImport(AppKit)
        return NSWorkspace.shared.isVoiceOverEnabled
        #else
        return false
        #endif
    }
}
