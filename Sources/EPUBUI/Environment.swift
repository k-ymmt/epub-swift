import SwiftUI
import EPUBRenderer

/// Wrapper for the app's event handler (docs/design/03-api.md §4.1).
struct ReaderEventHandler: @unchecked Sendable {
    let handle: @MainActor (ReaderEvent) -> Void
}

private struct PageTransitionKey: EnvironmentKey {
    static let defaultValue = AnyPageTransition(SlidePageTransition())
}

private struct ReaderGesturesKey: EnvironmentKey {
    static let defaultValue = ReaderGestures.default
}

private struct ReaderEventHandlerKey: EnvironmentKey {
    static let defaultValue: ReaderEventHandler? = nil
}

extension EnvironmentValues {
    var pageTransition: AnyPageTransition {
        get { self[PageTransitionKey.self] }
        set { self[PageTransitionKey.self] = newValue }
    }

    var readerGestures: ReaderGestures {
        get { self[ReaderGesturesKey.self] }
        set { self[ReaderGesturesKey.self] = newValue }
    }

    var readerEventHandler: ReaderEventHandler? {
        get { self[ReaderEventHandlerKey.self] }
        set { self[ReaderEventHandlerKey.self] = newValue }
    }
}

extension View {
    /// Page-turn effect used by `EPUBReaderView` inside this view. Default: `.slide`.
    public func pageTransition(_ transition: some PageTransition) -> some View {
        environment(\.pageTransition, AnyPageTransition(transition))
    }

    /// Built-in gestures used by `EPUBReaderView` inside this view. Default: `.default`.
    public func readerGestures(_ gestures: ReaderGestures) -> some View {
        environment(\.readerGestures, gestures)
    }

    /// Receives `ReaderEvent`s from the `EPUBReaderView` inside this view.
    public func onReaderEvent(_ handler: @escaping @MainActor (ReaderEvent) -> Void) -> some View {
        environment(\.readerEventHandler, ReaderEventHandler(handle: handler))
    }
}
