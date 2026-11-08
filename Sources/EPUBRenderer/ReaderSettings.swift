import Foundation
import EPUBCore

/// Reader-side display settings (docs/design/03-api.md §3.1). Changing a value on `ReaderSession.settings`
/// re-layouts the current document through CSS variables (02-rendering §3.5) and restores the reading position.
public struct ReaderSettings: Codable, Hashable, Sendable {
    public var font: FontChoice = .publisher
    /// 1.0 = the publisher's font size. Applied as `html { font-size: calc(100% * scale) }` so `rem`/`em` ratios survive.
    public var fontScale: Double = 1.0
    public var lineHeight: Double = 1.6
    public var pageMargins: PageMargins = PageMargins(horizontal: 24, vertical: 20)
    public var theme: ReaderTheme = .light
    public var spreadPolicy: SpreadPolicy = .auto

    public var respectsPublisherFonts: Bool { font == .publisher }

    public init(
        font: FontChoice = .publisher,
        fontScale: Double = 1.0,
        lineHeight: Double = 1.6,
        pageMargins: PageMargins = PageMargins(horizontal: 24, vertical: 20),
        theme: ReaderTheme = .light,
        spreadPolicy: SpreadPolicy = .auto
    ) {
        self.font = font
        self.fontScale = fontScale
        self.lineHeight = lineHeight
        self.pageMargins = pageMargins
        self.theme = theme
        self.spreadPolicy = spreadPolicy
    }

    public enum FontChoice: Codable, Hashable, Sendable {
        /// Keep the publisher's `font-family`.
        case publisher
        /// A font installed on the system, referenced by family name.
        case system(name: String)
        /// A font file supplied by the app, served through `epub://<id>/_reader/fonts/<name>`.
        case custom(FontResource)
    }

    public enum SpreadPolicy: String, Codable, Hashable, Sendable {
        case auto, never, always
    }

    /// Settings that change pagination (everything except the theme colors). Used as part of the layout cache key.
    var layoutKey: LayoutKey {
        LayoutKey(font: font, fontScale: fontScale, lineHeight: lineHeight, pageMargins: pageMargins, spreadPolicy: spreadPolicy)
    }

    struct LayoutKey: Hashable, Sendable {
        var font: FontChoice
        var fontScale: Double
        var lineHeight: Double
        var pageMargins: PageMargins
        var spreadPolicy: SpreadPolicy
    }
}

public struct PageMargins: Codable, Hashable, Sendable {
    /// Points on each of the left and right sides of a page.
    public var horizontal: Double
    /// Points on each of the top and bottom sides of a page.
    public var vertical: Double

    public init(horizontal: Double, vertical: Double) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

public struct FontResource: Codable, Hashable, Sendable {
    public var familyName: String
    /// A font file in the app bundle or in the app's documents.
    public var fileURL: URL

    public init(familyName: String, fileURL: URL) {
        self.familyName = familyName
        self.fileURL = fileURL
    }
}

public struct ReaderTheme: Codable, Hashable, Sendable {
    public var foreground: ReaderColor
    public var background: ReaderColor
    public var link: ReaderColor
    /// Dims images and sets `color-scheme: dark`.
    public var isDark: Bool

    public init(foreground: ReaderColor, background: ReaderColor, link: ReaderColor, isDark: Bool) {
        self.foreground = foreground
        self.background = background
        self.link = link
        self.isDark = isDark
    }

    public static let light = ReaderTheme(
        foreground: ReaderColor(hex: 0x1C1C1E),
        background: ReaderColor(hex: 0xFFFFFF),
        link: ReaderColor(hex: 0x0A5BD6),
        isDark: false
    )

    public static let sepia = ReaderTheme(
        foreground: ReaderColor(hex: 0x5B4636),
        background: ReaderColor(hex: 0xF4ECD8),
        link: ReaderColor(hex: 0x8A5A2B),
        isDark: false
    )

    public static let dark = ReaderTheme(
        foreground: ReaderColor(hex: 0xE6E6E6),
        background: ReaderColor(hex: 0x121212),
        link: ReaderColor(hex: 0x7FB2FF),
        isDark: true
    )
}
