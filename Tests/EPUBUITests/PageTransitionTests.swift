import SwiftUI
import Testing
import EPUBCore
import EPUBRenderer
@testable import EPUBUI

@Suite struct PageTransitionTests {
    private func context(direction: PageDirection, layout: LayoutDirection, progress: Double = 0.5) -> PageTransitionContext {
        PageTransitionContext(
            from: Image(systemName: "a.square"),
            to: Image(systemName: "b.square"),
            direction: direction,
            progress: progress,
            layoutDirection: layout,
            size: CGSize(width: 300, height: 500),
            isInteractive: false
        )
    }

    @Test func outgoingPageMovesLeftWhenGoingForwardInLTR() {
        #expect(context(direction: .forward, layout: .leftToRight).outgoingSign == -1)
        #expect(context(direction: .backward, layout: .leftToRight).outgoingSign == 1)
    }

    @Test func outgoingPageMovesRightWhenGoingForwardInRTL() {
        #expect(context(direction: .forward, layout: .rightToLeft).outgoingSign == 1)
        #expect(context(direction: .backward, layout: .rightToLeft).outgoingSign == -1)
    }

    @Test func erasedTransitionKeepsDuration() {
        #expect(AnyPageTransition(SlidePageTransition(duration: 0.4)).duration == 0.4)
        #expect(AnyPageTransition(FadePageTransition(duration: 0.1)).duration == 0.1)
        #expect(AnyPageTransition(NoPageTransition()).duration == 0)
    }

    @Test func readerColorRoundTripsThroughSwiftUIColor() {
        let original = ReaderColor(hex: 0x3366CC)
        let color = Color(original)
        let back = ReaderColor(color, in: EnvironmentValues())
        #expect(abs(back.red - original.red) < 0.01)
        #expect(abs(back.green - original.green) < 0.01)
        #expect(abs(back.blue - original.blue) < 0.01)
    }
}
