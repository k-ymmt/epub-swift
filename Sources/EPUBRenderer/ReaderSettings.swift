import Foundation
import EPUBCore

/// Reader-side display settings (docs/design/03-api.md §3.1). Changing a value on `ReaderSession.settings`
/// re-layouts the current document through CSS variables (02-rendering §3.5) and restores the reading position.
/// How a book is shown (docs/design/08-continuous-scroll.md §3.1).
public enum ReaderLayout: String, Codable, Hashable, Sendable {
    /// One page at a time, turned (the default).
    case paged
    /// One vertical scroll through the whole book. Books it does not apply to (fixed layout, right-to-left page
    /// progression, vertical writing) are shown paged all the same: `ReaderSession.layout` says which one is in use.
    case scrolled
}

public struct ReaderSettings: Codable, Hashable, Sendable {
    public var font: FontChoice = .publisher
    /// 1.0 = the publisher's font size. Applied as `html { font-size: calc(100% * scale) }` so `rem`/`em` ratios survive.
    public var fontScale: Double = 1.0
    public var lineHeight: Double = 1.6
    /// Paged: the margins of a page. Scrolled: `horizontal` is the margin on each side of the text, and twice
    /// `vertical` is left above and below every chapter.
    public var pageMargins: PageMargins = PageMargins(horizontal: 24, vertical: 20)
    public var theme: ReaderTheme = .light
    /// Not used by the scrolled layout (always one column).
    public var spreadPolicy: SpreadPolicy = .auto
    public var layout: ReaderLayout = .paged
    /// Scrolled layout: the widest the text gets, in multiples of the base font size (after `fontScale`). 36 is about
    /// 70 Latin characters or 36 Japanese ones. A narrower view uses its width minus the horizontal margins.
    public var scrolledTextWidth: Double = 36

    public var respectsPublisherFonts: Bool { font == .publisher }

    public init(
        font: FontChoice = .publisher,
        fontScale: Double = 1.0,
        lineHeight: Double = 1.6,
        pageMargins: PageMargins = PageMargins(horizontal: 24, vertical: 20),
        theme: ReaderTheme = .light,
        spreadPolicy: SpreadPolicy = .auto,
        layout: ReaderLayout = .paged,
        scrolledTextWidth: Double = 36
    ) {
        self.font = font
        self.fontScale = fontScale
        self.lineHeight = lineHeight
        self.pageMargins = pageMargins
        self.theme = theme
        self.spreadPolicy = spreadPolicy
        self.layout = layout
        self.scrolledTextWidth = scrolledTextWidth
    }

    /// Settings saved before the scrolled layout existed have no `layout` / `scrolledTextWidth`: they read as paged,
    /// with the default width. Every other key is required, as it was.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = try c.decode(FontChoice.self, forKey: .font)
        fontScale = try c.decode(Double.self, forKey: .fontScale)
        lineHeight = try c.decode(Double.self, forKey: .lineHeight)
        pageMargins = try c.decode(PageMargins.self, forKey: .pageMargins)
        theme = try c.decode(ReaderTheme.self, forKey: .theme)
        spreadPolicy = try c.decode(SpreadPolicy.self, forKey: .spreadPolicy)
        layout = try c.decodeIfPresent(ReaderLayout.self, forKey: .layout) ?? .paged
        scrolledTextWidth = try c.decodeIfPresent(Double.self, forKey: .scrolledTextWidth) ?? 36
    }

    public enum FontChoice: Codable, Hashable, Sendable {
        /// Keep the publisher's `font-family`.
        case publisher
        /// A font installed on the system, referenced by family name.
        case system(name: String)
        /// The platform's standard text font (San Francisco, with Hiragino Sans for Japanese). It has no family name
        /// a page can write, so it is its own choice (CSS `-apple-system`).
        case systemUI
        /// A font file supplied by the app, served through `epub://<id>/_reader/fonts/<name>`.
        case custom(FontResource)
    }

    public enum SpreadPolicy: String, Codable, Hashable, Sendable {
        case auto, never, always
    }

    /// Settings that change pagination (everything except the theme colors). Used as part of the layout cache key.
    /// Only what the layout in use reads is in it: the text width counts for the scrolled layout alone, the spread
    /// policy for the paged one alone, so changing a value the visible layout ignores keeps the measurements.
    var layoutKey: LayoutKey {
        LayoutKey(
            font: font, fontScale: fontScale, lineHeight: lineHeight, pageMargins: pageMargins,
            spreadPolicy: layout == .paged ? spreadPolicy : .auto,
            layout: layout,
            scrolledTextWidth: layout == .scrolled ? scrolledTextWidth : 0
        )
    }

    struct LayoutKey: Hashable, Sendable {
        var font: FontChoice
        var fontScale: Double
        var lineHeight: Double
        var pageMargins: PageMargins
        var spreadPolicy: SpreadPolicy
        var layout: ReaderLayout = .paged
        var scrolledTextWidth: Double = 0
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
    /// The colors of the highlight labels (docs/design/06-annotations.md §10.2). Line styles (underline,
    /// strikethrough, outline) use the color as it is; `solid` draws it behind the text at `solidHighlightOpacity`
    /// times its alpha.
    public var annotationPalette: [HighlightColor: ReaderColor]
    /// The color of labels outside the specification (`.other`) and of labels missing from the palette.
    public var annotationFallbackColor: ReaderColor

    /// Alpha factor of `solid` highlights.
    static let solidHighlightOpacity = 0.4

    public init(
        foreground: ReaderColor,
        background: ReaderColor,
        link: ReaderColor,
        isDark: Bool,
        annotationPalette: [HighlightColor: ReaderColor]? = nil,
        annotationFallbackColor: ReaderColor? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.link = link
        self.isDark = isDark
        self.annotationPalette = annotationPalette ?? (isDark ? Self.darkPalette : Self.lightPalette)
        self.annotationFallbackColor = annotationFallbackColor ?? (isDark ? Self.darkFallback : Self.lightFallback)
    }

    /// The color a highlight label is drawn in.
    public func color(for label: HighlightColor) -> ReaderColor {
        annotationPalette[label] ?? annotationFallbackColor
    }

    public static let lightPalette: [HighlightColor: ReaderColor] = [
        .pink: ReaderColor(hex: 0xFF4F8B),
        .orange: ReaderColor(hex: 0xFF9500),
        .yellow: ReaderColor(hex: 0xFFCC00),
        .green: ReaderColor(hex: 0x34C759),
        .blue: ReaderColor(hex: 0x1E88FF),
        .purple: ReaderColor(hex: 0xAF52DE),
    ]

    /// Darker colors, so that solid highlights do not glare on a dark page.
    public static let darkPalette: [HighlightColor: ReaderColor] = [
        .pink: ReaderColor(hex: 0xC2406E),
        .orange: ReaderColor(hex: 0xC07418),
        .yellow: ReaderColor(hex: 0xB89A12),
        .green: ReaderColor(hex: 0x2E9E50),
        .blue: ReaderColor(hex: 0x2F78C8),
        .purple: ReaderColor(hex: 0x8E4CB8),
    ]

    static let lightFallback = ReaderColor(hex: 0x8E8E93)
    static let darkFallback = ReaderColor(hex: 0x6E6E73)

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

    private enum CodingKeys: String, CodingKey {
        case foreground, background, link, isDark, annotationPalette, annotationFallbackColor
    }

    /// Themes saved before M6 have no palette; they get the default one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            foreground: try c.decode(ReaderColor.self, forKey: .foreground),
            background: try c.decode(ReaderColor.self, forKey: .background),
            link: try c.decode(ReaderColor.self, forKey: .link),
            isDark: try c.decode(Bool.self, forKey: .isDark),
            annotationPalette: try c.decodeIfPresent([HighlightColor: ReaderColor].self, forKey: .annotationPalette),
            annotationFallbackColor: try c.decodeIfPresent(ReaderColor.self, forKey: .annotationFallbackColor)
        )
    }
}
