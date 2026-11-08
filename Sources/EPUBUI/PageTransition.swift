import SwiftUI
import EPUBCore
import EPUBRenderer

/// Draws a page turn from two page images (docs/design/03-api.md §4.2, 02-rendering §7.2).
///
/// The transition sees only `from`, `to` and a `progress` in 0...1. While it is on screen the web view is
/// hidden underneath; when `progress` reaches 1 `EPUBReaderView` removes the transition and shows the web view.
public protocol PageTransition: Sendable {
    associatedtype Body: View
    @ViewBuilder @MainActor func body(_ context: PageTransitionContext) -> Body
}

public struct PageTransitionContext {
    /// Snapshot of the page being left.
    public let from: Image
    /// Snapshot of the destination page, or a background-colored rectangle when it is not available yet.
    public let to: Image
    public let direction: PageDirection
    /// 0...1. Follows the finger while `isInteractive`, otherwise animated.
    public let progress: Double
    /// Axis of the turn: horizontal for horizontal writing and for vertical writing (right-to-left books).
    public let axis: Axis
    /// `.rightToLeft` for right-bound books (`page-progression-direction="rtl"`): forward moves to the right.
    public let layoutDirection: LayoutDirection
    public let size: CGSize
    public let isInteractive: Bool

    public init(from: Image, to: Image, direction: PageDirection, progress: Double, axis: Axis = .horizontal, layoutDirection: LayoutDirection = .leftToRight, size: CGSize, isInteractive: Bool) {
        self.from = from
        self.to = to
        self.direction = direction
        self.progress = progress
        self.axis = axis
        self.layoutDirection = layoutDirection
        self.size = size
        self.isInteractive = isInteractive
    }

    /// +1 when the outgoing page moves toward positive x (backward in a left-to-right book), -1 otherwise.
    public var outgoingSign: CGFloat {
        let forwardSign: CGFloat = layoutDirection == .rightToLeft ? 1 : -1
        return direction == .forward ? forwardSign : -forwardSign
    }
}

/// The default: the current page slides out while the next one slides in.
public struct SlidePageTransition: PageTransition {
    public var duration: Double

    public init(duration: Double = 0.28) {
        self.duration = duration
    }

    public func body(_ context: PageTransitionContext) -> some View {
        let width = context.size.width
        let height = context.size.height
        let sign = context.outgoingSign
        ZStack(alignment: .topLeading) {
            context.to
                .resizable()
                .frame(width: width, height: height)
                .offset(x: -sign * width * (1 - context.progress))
            context.from
                .resizable()
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.18 * (1 - context.progress)), radius: 8, x: -sign * 4, y: 0)
                .offset(x: sign * width * context.progress)
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

/// Cross-fade between the two pages.
public struct FadePageTransition: PageTransition {
    public var duration: Double

    public init(duration: Double = 0.2) {
        self.duration = duration
    }

    public func body(_ context: PageTransitionContext) -> some View {
        ZStack {
            context.from.resizable().frame(width: context.size.width, height: context.size.height).opacity(1 - context.progress)
            context.to.resizable().frame(width: context.size.width, height: context.size.height).opacity(context.progress)
        }
    }
}

/// No animation: the destination page appears at once.
public struct NoPageTransition: PageTransition {
    public init() {}

    public func body(_ context: PageTransitionContext) -> some View {
        (context.progress < 1 ? context.from : context.to)
            .resizable()
            .frame(width: context.size.width, height: context.size.height)
    }
}

extension PageTransition where Self == SlidePageTransition {
    public static var slide: Self { SlidePageTransition() }
}

extension PageTransition where Self == FadePageTransition {
    public static var fade: Self { FadePageTransition() }
}

extension PageTransition where Self == NoPageTransition {
    public static var none: Self { NoPageTransition() }
}

/// Type-erased transition stored in the environment.
struct AnyPageTransition: @unchecked Sendable {
    let duration: Double
    private let makeBody: @MainActor (PageTransitionContext) -> AnyView

    init<T: PageTransition>(_ transition: T) {
        switch transition {
        case let slide as SlidePageTransition: duration = slide.duration
        case let fade as FadePageTransition: duration = fade.duration
        case is NoPageTransition: duration = 0
        default: duration = 0.28
        }
        makeBody = { AnyView(transition.body($0)) }
    }

    @MainActor func body(_ context: PageTransitionContext) -> AnyView {
        makeBody(context)
    }
}

// MARK: - Color conversion

extension Color {
    public init(_ readerColor: ReaderColor) {
        self.init(.sRGB, red: readerColor.red, green: readerColor.green, blue: readerColor.blue, opacity: readerColor.alpha)
    }
}

extension ReaderColor {
    /// Resolves a SwiftUI color in the given environment.
    public init(_ color: Color, in environment: EnvironmentValues) {
        let resolved = color.resolve(in: environment)
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), alpha: Double(resolved.opacity))
    }
}
