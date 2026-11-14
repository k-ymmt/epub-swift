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

    @Test func theLayoutIsPagedUnlessAskedOtherwiseAndOldSettingsDecodeAsPaged() throws {
        let s = ReaderSettings()
        #expect(s.layout == .paged)
        #expect(s.scrolledTextWidth == 36)
        // Settings saved before the scrolled layout existed have neither key (08-continuous-scroll §3.1).
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        object["layout"] = nil
        object["scrolledTextWidth"] = nil
        let old = try JSONDecoder().decode(ReaderSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old == s)
        var scrolled = s
        scrolled.layout = .scrolled
        scrolled.scrolledTextWidth = 30
        #expect(try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(scrolled)) == scrolled)
    }

    @Test func theLayoutKeyHoldsOnlyWhatTheLayoutInUseReads() {
        var paged = ReaderSettings()
        var scrolled = ReaderSettings()
        scrolled.layout = .scrolled
        #expect(paged.layoutKey != scrolled.layoutKey)
        // The text width changes the scrolled layout only.
        var wide = scrolled
        wide.scrolledTextWidth = 44
        #expect(wide.layoutKey != scrolled.layoutKey)
        var pagedWide = paged
        pagedWide.scrolledTextWidth = 44
        #expect(pagedWide.layoutKey == paged.layoutKey)
        // The spread policy changes the paged layout only.
        var never = scrolled
        never.spreadPolicy = .never
        #expect(never.layoutKey == scrolled.layoutKey)
        paged.spreadPolicy = .never
        #expect(paged.layoutKey != ReaderSettings().layoutKey)
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
