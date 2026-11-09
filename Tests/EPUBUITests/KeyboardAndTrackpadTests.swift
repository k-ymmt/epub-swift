import Foundation
import Testing
import SwiftUI
@testable import EPUBUI

#if canImport(AppKit)
import AppKit
#endif

/// macOS keyboard and trackpad input (M5, docs/design/03-api.md §4.3).
@MainActor struct KeyboardAndTrackpadTests {
    @Test func horizontalArrowsFollowThePageProgression() {
        #expect(ReaderKey.right.action(isRightToLeft: false) == .forward)
        #expect(ReaderKey.left.action(isRightToLeft: false) == .backward)
        // Right-bound books (vertical-rl, page-progression-direction="rtl"): the next page is on the left.
        #expect(ReaderKey.left.action(isRightToLeft: true) == .forward)
        #expect(ReaderKey.right.action(isRightToLeft: true) == .backward)
    }

    @Test func pageKeysAndSpaceAlwaysMeanNextAndPrevious() {
        for rtl in [false, true] {
            #expect(ReaderKey.space.action(isRightToLeft: rtl) == .forward)
            #expect(ReaderKey.pageDown.action(isRightToLeft: rtl) == .forward)
            #expect(ReaderKey.down.action(isRightToLeft: rtl) == .forward)
            #expect(ReaderKey.shiftSpace.action(isRightToLeft: rtl) == .backward)
            #expect(ReaderKey.pageUp.action(isRightToLeft: rtl) == .backward)
            #expect(ReaderKey.up.action(isRightToLeft: rtl) == .backward)
            #expect(ReaderKey.home.action(isRightToLeft: rtl) == .chapterStart)
            #expect(ReaderKey.end.action(isRightToLeft: rtl) == .chapterEnd)
        }
    }

    #if canImport(AppKit)
    @Test func keyEventsMapToReaderKeys() {
        func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) -> ReaderKey? {
            ReaderKey(charactersIgnoringModifiers: String(UnicodeScalar(UInt32(code))!), modifierFlags: flags)
        }
        #expect(key(NSRightArrowFunctionKey) == .right)
        #expect(key(NSLeftArrowFunctionKey) == .left)
        #expect(key(NSPageDownFunctionKey) == .pageDown)
        #expect(key(NSHomeFunctionKey) == .home)
        #expect(key(NSEndFunctionKey) == .end)
        #expect(key(0x20) == .space)
        #expect(key(0x20, .shift) == .shiftSpace)
        // Chords are left alone: ⌘← (line start in text), ⇧→ (extend the selection), ⌥ PageDown.
        #expect(key(NSLeftArrowFunctionKey, .command) == nil)
        #expect(key(NSRightArrowFunctionKey, .shift) == nil)
        #expect(key(NSPageDownFunctionKey, .option) == nil)
        #expect(key(0x61) == nil) // "a"
    }

    @Test func oneTrackpadSwipeIsOneGestureAndMomentumIsSwallowed() {
        let controller = PageTurnController()
        func send(_ phase: ScrollPhaseEvent.Phase, _ dx: CGFloat, _ dy: CGFloat = 0) -> Bool {
            controller.handleScroll(ScrollPhaseEvent(phase: phase, deltaX: dx, deltaY: dy), layoutDirection: .leftToRight)
        }
        // A horizontal swipe: used from the moment the axis is known until the momentum ends.
        #expect(!send(.began, 0))
        #expect(!send(.changed, -3))
        #expect(send(.changed, -10))
        #expect(send(.changed, -20))
        #expect(send(.ended, 0))
        #expect(send(.momentum, -30))
        #expect(send(.momentum, -10))
        // A vertical scroll is left to the web view, momentum included.
        #expect(!send(.began, 0))
        #expect(!send(.changed, 1, -12))
        #expect(!send(.changed, 0, -20))
        #expect(!send(.ended, 0))
        #expect(!send(.momentum, 0, -30))
        // A plain mouse wheel (no phase) never turns pages.
        #expect(!send(.other, -40))
    }
    #endif
}
