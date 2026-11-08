import Testing
import EPUB

/// The umbrella module must re-export every layer so that `import EPUB` alone is enough for an app.
@Suite struct UmbrellaTests {
    @Test func reexportsAllLayers() {
        let id = PublicationID()                       // EPUBCore
        let settings = ReaderSettings()                // EPUBRenderer
        let gestures = ReaderGestures.default          // EPUBUI
        #expect(!id.description.isEmpty)
        #expect(settings.fontScale == 1.0)
        #expect(gestures.swipeEnabled)
    }
}
