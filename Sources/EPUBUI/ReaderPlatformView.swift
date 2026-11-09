import SwiftUI
@_spi(EPUBUI) import EPUBRenderer

#if canImport(UIKit)
import UIKit

/// Hosts the session's page view (the clipped web view) in SwiftUI.
struct ReaderPlatformView: UIViewRepresentable {
    let session: ReaderSession
    /// VoiceOver's three-finger swipe (`accessibilityScroll`) on the page (M5, 02-rendering §7.3). Returns whether
    /// the page moved.
    var onAccessibilityScroll: (@MainActor (UIAccessibilityScrollDirection) -> Bool)?

    func makeUIView(context: Context) -> HostView {
        let view = HostView(content: session.platformView)
        view.onAccessibilityScroll = onAccessibilityScroll
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.content = session.platformView
        uiView.onAccessibilityScroll = onAccessibilityScroll
    }

    final class HostView: UIView {
        var content: UIView {
            didSet {
                guard oldValue !== content else { return }
                oldValue.removeFromSuperview()
                addSubview(content)
                setNeedsLayout()
            }
        }

        init(content: UIView) {
            self.content = content
            super.init(frame: .zero)
            clipsToBounds = true
            addSubview(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        var onAccessibilityScroll: (@MainActor (UIAccessibilityScrollDirection) -> Bool)?

        override func layoutSubviews() {
            super.layoutSubviews()
            content.frame = bounds
        }

        /// The web view does not scroll by itself (paging is the library's), so the scroll gesture of VoiceOver
        /// reaches this ancestor and turns the page.
        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            onAccessibilityScroll?(direction) ?? false
        }
    }
}

#elseif canImport(AppKit)
import AppKit

struct ReaderPlatformView: NSViewRepresentable {
    let session: ReaderSession
    /// Called for key presses and trackpad scrolls while the view's window is key (docs/design/03-api.md §4.3).
    /// Returning true consumes the event (the web view does not see it).
    var onKey: (@MainActor (ReaderKey) -> Bool)?
    var onScrollPhase: (@MainActor (ScrollPhaseEvent) -> Bool)?

    func makeNSView(context: Context) -> HostView {
        let view = HostView(content: session.platformView)
        view.onKey = onKey
        view.onScrollPhase = onScrollPhase
        return view
    }

    func updateNSView(_ nsView: HostView, context: Context) {
        nsView.content = session.platformView
        nsView.onKey = onKey
        nsView.onScrollPhase = onScrollPhase
    }

    final class HostView: NSView {
        var content: NSView {
            didSet {
                guard oldValue !== content else { return }
                oldValue.removeFromSuperview()
                addSubview(content)
                needsLayout = true
            }
        }
        var onKey: (@MainActor (ReaderKey) -> Bool)?
        var onScrollPhase: (@MainActor (ScrollPhaseEvent) -> Bool)?
        private var monitor: Any?

        init(content: NSView) {
            self.content = content
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            addSubview(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            content.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            // The web view is first responder for most of the time, so key and scroll events are observed with a
            // local monitor restricted to this view's window. Handled events are consumed so the web view does not
            // also scroll; everything else passes through.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                let key = event.type == .keyDown ? ReaderKey(event: event) : nil
                let scroll = event.type == .scrollWheel ? ScrollPhaseEvent(event: event) : nil
                let location = event.locationInWindow
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    if let key {
                        guard self.acceptsReaderKeys(in: window) else { return false }
                        return self.onKey?(key) ?? false
                    }
                    guard let scroll, self.bounds.contains(self.convert(location, from: nil)) else { return false }
                    return self.onScrollPhase?(scroll) ?? false
                }
                return consumed ? nil : event
            }
        }

        /// Keys belong to the reader unless something else in the window is taking text or list input (a search
        /// field, a table): the first responder is the web view (or this view), or nothing in particular.
        private func acceptsReaderKeys(in window: NSWindow) -> Bool {
            guard let responder = window.firstResponder, responder !== window else { return true }
            if let view = responder as? NSView, view === self || view.isDescendant(of: self) { return true }
            if responder is NSText || responder is NSTableView || responder is NSCollectionView || responder is NSTextInputClient { return false }
            if let view = responder as? NSView, view.enclosingScrollView != nil, !(view.enclosingScrollView!.isDescendant(of: self)) {
                // A scrolling list or text view elsewhere uses the arrow keys itself.
                return false
            }
            return true
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

#endif
