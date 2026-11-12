import Foundation
import Testing
@testable import EPUBRenderer

@Suite struct ReaderSettingsTests {
    @Test func defaultsMatchTheDesign() {
        let s = ReaderSettings()
        #expect(s.font == .publisher)
        #expect(s.respectsPublisherFonts)
        #expect(s.fontScale == 1.0)
        #expect(s.lineHeight == 1.6)
        #expect(s.pageMargins == PageMargins(horizontal: 24, vertical: 20))
        #expect(s.theme == .light)
    }

    @Test func themeColorsDoNotAffectTheLayoutKey() {
        var a = ReaderSettings()
        var b = ReaderSettings()
        b.theme = .dark
        #expect(a.layoutKey == b.layoutKey)
        a.fontScale = 1.2
        #expect(a.layoutKey != b.layoutKey)
    }

    @Test func roundTripsThroughCodable() throws {
        var s = ReaderSettings()
        s.font = .system(name: "Hiragino Mincho ProN")
        s.theme = .sepia
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: data)
        #expect(decoded == s)
    }

    @Test func systemUIRoundTripsThroughCodableAndChangesTheLayoutKey() throws {
        var s = ReaderSettings()
        s.font = .systemUI
        #expect(!s.respectsPublisherFonts)
        #expect(s.layoutKey != ReaderSettings().layoutKey)
        let decoded = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.font == .systemUI)
    }
}
