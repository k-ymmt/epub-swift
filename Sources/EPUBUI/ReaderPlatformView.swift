import SwiftUI
@_spi(EPUBUI) import EPUBRenderer

#if canImport(UIKit)
import UIKit

/// Hosts the session's page view (the clipped web view) in SwiftUI.
struct ReaderPlatformView: UIViewRepresentable {
    let session: ReaderSession

    func makeUIView(context: Context) -> HostView {
        HostView(content: session.platformView)
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.content = session.platformView
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

        override func layoutSubviews() {
            super.layoutSubviews()
            content.frame = bounds
        }
    }
}

#elseif canImport(AppKit)
import AppKit

struct ReaderPlatformView: NSViewRepresentable {
    let session: ReaderSession
    /// Called for key presses and trackpad swipes while the view's window is key (docs/design/03-api.md §4.3).
    var onKey: (@MainActor (ReaderKeyCommand) -> Void)?
    var onScrollPhase: (@MainActor (ScrollPhaseEvent) -> Void)?

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
        var onKey: (@MainActor (ReaderKeyCommand) -> Void)?
        var onScrollPhase: (@MainActor (ScrollPhaseEvent) -> Void)?
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
            // local monitor restricted to this view's window. Events are passed through.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
                MainActor.assumeIsolated {
                    if event.type == .keyDown, let command = ReaderKeyCommand(event: event) {
                        self.onKey?(command)
                    } else if event.type == .scrollWheel {
                        let location = self.convert(event.locationInWindow, from: nil)
                        guard self.bounds.contains(location) else { return }
                        self.onScrollPhase?(ScrollPhaseEvent(event: event))
                    }
                }
                return event
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

enum ReaderKeyCommand {
    case forward, backward

    init?(event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return nil }
        guard let chars = event.charactersIgnoringModifiers, let scalar = chars.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSRightArrowFunctionKey, NSPageDownFunctionKey, NSDownArrowFunctionKey: self = .forward
        case NSLeftArrowFunctionKey, NSPageUpFunctionKey, NSUpArrowFunctionKey: self = .backward
        case 0x20: self = event.modifierFlags.contains(.shift) ? .backward : .forward
        default: return nil
        }
    }
}

/// Trackpad swipe sample (two-finger scroll with phases).
struct ScrollPhaseEvent {
    enum Phase { case began, changed, ended, cancelled, momentum, other }
    var phase: Phase
    var deltaX: CGFloat
    var deltaY: CGFloat

    init(event: NSEvent) {
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.changed) { phase = .changed }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.momentumPhase != [] { phase = .momentum }
        else { phase = .other }
        deltaX = event.scrollingDeltaX
        deltaY = event.scrollingDeltaY
    }
}
#endif
