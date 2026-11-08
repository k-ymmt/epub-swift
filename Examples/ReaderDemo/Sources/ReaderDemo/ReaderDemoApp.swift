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
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 640, height: 860)
        #endif
    }
}
