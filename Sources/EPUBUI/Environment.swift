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

private struct SelectionActionsKey: EnvironmentKey {
    static let defaultValue: [SelectionAction] = []
}

private struct ReaderContentInsetsKey: EnvironmentKey {
    static let defaultValue = ReaderInsets()
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

    var selectionActions: [SelectionAction] {
        get { self[SelectionActionsKey.self] }
        set { self[SelectionActionsKey.self] = newValue }
    }

    var readerContentInsets: ReaderInsets {
        get { self[ReaderContentInsetsKey.self] }
        set { self[ReaderContentInsetsKey.self] = newValue }
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

    /// Entries added to the text selection menu of the `EPUBReaderView` inside this view (docs/design/03-api.md §4.4).
    /// Forwarded to `ReaderSession.selectionActions`. Default: none.
    public func selectionActions(_ actions: [SelectionAction]) -> some View {
        environment(\.selectionActions, actions)
    }

    /// What bars and safe areas cover at the top and the bottom of the `EPUBReaderView` inside this view, in points
    /// (docs/design/08-continuous-scroll.md §3.4). Forwarded to `ReaderSession.contentInsets`. Default: 0.
    ///
    /// The scrolled layout is meant to be placed under the bars: the text runs to the frame's edges, and the reading
    /// line, the restored position and the height of one page are counted inside these insets. Changing them lays
    /// the text out again, so they should not follow bars that come and go. The paged layout ignores them.
    public func readerContentInsets(top: Double, bottom: Double) -> some View {
        environment(\.readerContentInsets, ReaderInsets(top: top, bottom: bottom))
    }

    /// Receives `ReaderEvent`s from the `EPUBReaderView` inside this view.
    public func onReaderEvent(_ handler: @escaping @MainActor (ReaderEvent) -> Void) -> some View {
        environment(\.readerEventHandler, ReaderEventHandler(handle: handler))
    }
}
