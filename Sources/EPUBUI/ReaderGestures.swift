import Foundation
import EPUBRenderer

/// Standard gestures provided by `EPUBReaderView` (docs/design/03-api.md §4.3).
///
/// In right-to-left progression (`page-progression-direction="rtl"`, vertical writing) the right tap zone and a
/// rightward swipe mean "forward"; `EPUBReaderView` flips them based on `ReaderSession.publication.pageProgression`.
public struct ReaderGestures: Sendable, Hashable {
    /// Left / center / right width ratios for tap-to-turn. Default 0.25 / 0.5 / 0.25.
    public var tapZones: TapZones
    /// Horizontal swipe turns the page (on macOS also a two-finger trackpad swipe: one swipe, one page).
    public var swipeEnabled: Bool
    /// Tapping the left or right zone turns the page.
    public var tapToTurnEnabled: Bool
    /// macOS keyboard: ← → follow the page progression (← is "next" in a right-bound book), ↓ PageDown space
    /// next, ↑ PageUp ⇧space previous, Home / End the first / last page of the chapter. Ignored while a text field
    /// or list elsewhere in the window has focus, and while a fixed-layout face is zoomed in.
    public var keyboardEnabled: Bool

    public init(tapZones: TapZones = .default, swipeEnabled: Bool = true, tapToTurnEnabled: Bool = true, keyboardEnabled: Bool = true) {
        self.tapZones = tapZones
        self.swipeEnabled = swipeEnabled
        self.tapToTurnEnabled = tapToTurnEnabled
        self.keyboardEnabled = keyboardEnabled
    }

    public static let `default` = ReaderGestures()

    /// No built-in gestures; the app calls `ReaderSession.goForward()` / `goBackward()` itself.
    public static let disabled = ReaderGestures(swipeEnabled: false, tapToTurnEnabled: false, keyboardEnabled: false)
}

/// Horizontal division of a page into tap zones.
public struct TapZones: Sendable, Hashable {
    public var leading: Double
    public var center: Double
    public var trailing: Double

    public init(leading: Double = 0.25, center: Double = 0.5, trailing: Double = 0.25) {
        self.leading = leading
        self.center = center
        self.trailing = trailing
    }

    public static let `default` = TapZones()

    /// Classifies an x position (0...width) into a zone.
    public func zone(forX x: Double, width: Double) -> TapZone {
        guard width > 0 else { return .center }
        let total = leading + center + trailing
        guard total > 0 else { return .center }
        let ratio = x / width
        if ratio < leading / total { return .leading }
        if ratio >= (leading + center) / total { return .trailing }
        return .center
    }
}
