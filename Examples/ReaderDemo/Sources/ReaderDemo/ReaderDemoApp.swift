import SwiftUI
import EPUB

@main
struct ReaderDemoApp: App {
    init() {
        #if os(macOS)
        // `swift run` starts a bare executable; make it a regular app so a window and the menu bar appear.
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                #if os(macOS)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    // Recording mode: a page in a covered window gets no frames. `READERDEMO_FLOAT=1` keeps the window
                    // above everything else on screen while the recording runs.
                    if ProcessInfo.processInfo.environment["READERDEMO_FLOAT"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            for window in NSApp.windows { window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())) }
                        }
                    }
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 640, height: 860)
        #endif
    }
}
