import Foundation
import EPUBCore

/// String insertion of the viewport meta, the reader stylesheets and the per-session root style into a spine
/// document (docs/design/02-rendering.md §3.2). Works on the serialized text so the cascade order is fixed before
/// the first paint; no JavaScript is involved.
enum ContentInjector {
    struct Injection {
        /// `epub://<id>/_reader/css/reader-before.css`
        var beforeStylesheetURL: String
        /// `epub://<id>/_reader/css/reader-after.css`
        var afterStylesheetURL: String
        /// CSS text for the current settings (`:root { --reader-...: ...; }` plus any `@font-face`). May be empty.
        var rootStyle: String
        /// Whether to add `<meta name="viewport">` when the document has none (reflowable documents).
        var injectViewport: Bool
        /// Fixed-layout document (M4): only `fixedStylesheetURL` is injected (no pagination CSS, no viewport, no
        /// settings style), so the publisher's page design is left alone.
        var fixedStylesheetURL: String? = nil
    }

    /// `user-scalable=no` (M4): pinch zoom is for fixed-layout faces only; WebKit honours this at the viewport level,
    /// which is more reliable than the scroll view's zoom range (WebKit resets that from the viewport on each layout).
    static let viewportMeta = #"<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no"/>"#

    /// Returns the injected document and whether it already had a viewport meta.
    static func inject(_ data: Data, isXML: Bool, injection: Injection) -> (data: Data, hadViewport: Bool) {
        guard var text = String(data: data, encoding: .utf8) else {
            return (data, false)
        }
        let hadViewport = hasViewportMeta(text)
        // A prefixed root (`<x:html xmlns:x="…xhtml">`) has no default namespace: the inserted elements take the same
        // prefix so that they are XHTML elements.
        let headTag = startTag(named: "head", in: text)
        let htmlTag = startTag(named: "html", in: text)
        let prefix = (headTag ?? htmlTag)?.prefix
        func name(_ local: String) -> String { prefix.map { "\($0):\(local)" } ?? local }
        func stylesheet(_ url: String) -> String {
            "<\(name("link")) rel=\"stylesheet\" type=\"text/css\" href=\"\(escapeAttribute(url))\"/>"
        }

        let head: String
        var tail: String
        if let fixed = injection.fixedStylesheetURL {
            head = ""
            tail = stylesheet(fixed)
        } else {
            let viewport = (injection.injectViewport && !hadViewport)
                ? viewportMeta.replacingOccurrences(of: "<meta ", with: "<\(name("meta")) ") : ""
            head = stylesheet(injection.beforeStylesheetURL) + viewport
            tail = stylesheet(injection.afterStylesheetURL)
            if !injection.rootStyle.isEmpty {
                tail += "<\(name("style")) id=\"__reader_settings\">\(injection.rootStyle)</\(name("style"))>"
            }
        }

        if let headOpen = headTag {
            text.insert(contentsOf: head, at: headOpen.range.upperBound)
            let afterHead = text.index(headOpen.range.upperBound, offsetBy: head.count)
            if let headClose = text.range(of: "</\(headOpen.qualifiedName)", options: .caseInsensitive, range: afterHead..<text.endIndex) {
                text.insert(contentsOf: tail, at: headClose.lowerBound)
            } else {
                // Unterminated head: put everything at the head start.
                text.insert(contentsOf: tail, at: afterHead)
            }
        } else if let htmlOpen = htmlTag {
            text.insert(contentsOf: "<\(name("head"))>" + head + tail + "</\(name("head"))>", at: htmlOpen.range.upperBound)
        } else {
            // No <html> start tag at all (text/html fallback of a fragment). Prepend; the parser will cope.
            text = "<head>" + head + tail + "</head>" + text
        }
        _ = isXML
        return (Data(text.utf8), hadViewport)
    }

    static func hasViewportMeta(_ text: String) -> Bool {
        text.range(of: #"<meta\s+[^>]*name\s*=\s*["']viewport["']"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    struct StartTag {
        /// The whole tag including `>`.
        var range: Range<String.Index>
        /// The name as written (`head`, `x:head`).
        var qualifiedName: String
        var prefix: String? {
            qualifiedName.firstIndex(of: ":").map { String(qualifiedName[..<$0]) }
        }
    }

    /// Range of the start tag `<name ...>` (the whole tag including `>`). Case-insensitive.
    static func range(ofTag name: String, in text: String) -> Range<String.Index>? {
        startTag(named: name, in: text)?.range
    }

    /// The first start tag whose local name is `name`, with or without a namespace prefix (`<head>`, `<x:head>`),
    /// skipping the XML declaration, doctype, comments, end tags and longer names (`<header>`). Case-insensitive.
    static func startTag(named name: String, in text: String) -> StartTag? {
        var searchStart = text.startIndex
        while let open = text.range(of: "<", range: searchStart..<text.endIndex) {
            searchStart = open.upperBound
            guard open.upperBound < text.endIndex else { return nil }
            if text[open.upperBound...].hasPrefix("!--") {
                // Skip the whole comment: it may contain markup.
                guard let end = text.range(of: "-->", range: open.upperBound..<text.endIndex) else { return nil }
                searchStart = end.upperBound
                continue
            }
            let nameEnd = text[open.upperBound...].firstIndex { $0.isWhitespace || $0 == ">" || $0 == "/" } ?? text.endIndex
            let qualified = text[open.upperBound..<nameEnd]
            guard let first = qualified.first, first.isLetter || first == "_" else { continue }
            let local = qualified.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last ?? qualified
            guard local.caseInsensitiveCompare(name) == .orderedSame else { continue }
            guard let close = text.range(of: ">", range: nameEnd..<text.endIndex) else { return nil }
            return StartTag(range: open.lowerBound..<close.upperBound, qualifiedName: String(qualified))
        }
        return nil
    }

    static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// `:root { ... }` for the given settings and page size, so that the first paint already uses them.
    static func rootStyle(settings: ReaderSettings, pageSize: CGSize, publicationID: PublicationID) -> String {
        var declarations: [String] = []
        if pageSize.width > 0, pageSize.height > 0 {
            declarations.append("--reader-page-width: \(cssLength(pageSize.width))")
            declarations.append("--reader-page-height: \(cssLength(pageSize.height))")
        }
        declarations.append("--reader-margin-h: \(cssLength(settings.pageMargins.horizontal))")
        declarations.append("--reader-margin-v: \(cssLength(settings.pageMargins.vertical))")
        declarations.append("--reader-font-size: \(settings.fontScale)")
        declarations.append("--reader-line-height: \(settings.lineHeight)")
        declarations.append("--reader-fg: \(settings.theme.foreground.cssString)")
        declarations.append("--reader-bg: \(settings.theme.background.cssString)")
        declarations.append("--reader-link: \(settings.theme.link.cssString)")
        if let family = fontFamilyCSS(settings.font) {
            declarations.append("--reader-font-family: \(family)")
        }
        var css = ":root { " + declarations.joined(separator: "; ") + "; }"
        if case .custom(let resource) = settings.font {
            let url = "epub://\(publicationID)/_reader/fonts/\(fontURLSegment(resource.familyName))"
            css += " @font-face { font-family: \(cssString(resource.familyName)); src: url(\"\(url)\"); }"
        }
        // The attributes reader.js sets after load, pre-applied through the selector-less fallback so that the
        // first paint already uses the theme/font flags.
        var rootAttrs: [String] = []
        if settings.theme.isDark { rootAttrs.append("html { color-scheme: dark; }") }
        if settings.font != .publisher {
            rootAttrs.append("\(fontOverrideSelector) { font-family: var(--reader-font-family) !important; }")
        }
        if settings.theme.isDark {
            rootAttrs.append("html body *:not(a) { color: var(--reader-fg) !important; } html img, html svg { filter: brightness(0.85); }")
        }
        return css + (rootAttrs.isEmpty ? "" : " " + rootAttrs.joined(separator: " "))
    }

    /// What a font override applies to: everything in the body except code (`pre`, `code`, `kbd`, `samp`, `tt`), MathML
    /// and SVG, and what is inside them. Code keeps the publisher's font, or the browser's `monospace`, because it is
    /// aligned by column; math needs its math font and the text of a figure the font it was laid out with.
    /// `reader-after.css` has the same selector behind `html[data-reader-font="override"]`
    /// (`readerAfterStylesheetHasTheSameFontOverrideSelector`).
    static let fontOverrideSelector = "html body, html body *:not(\(fontOverrideExclusions), \(fontOverrideExclusions) *)"
    private static let fontOverrideExclusions = ":is(pre, code, kbd, samp, tt, math, svg)"

    /// The fonts behind every override: the platform's standard text font.
    private static let systemFontFamilyCSS = "-apple-system, system-ui, sans-serif"

    static func fontFamilyCSS(_ font: ReaderSettings.FontChoice) -> String? {
        switch font {
        case .publisher: return nil
        case .systemUI: return systemFontFamilyCSS
        case .system(let name): return "\(cssString(name)), \(systemFontFamilyCSS)"
        case .custom(let resource): return "\(cssString(resource.familyName)), \(systemFontFamilyCSS)"
        }
    }

    /// A family name as a CSS string. Every character that could end the string (a quote, a backslash, a line break or
    /// another control character) or that means something to the document the style is embedded in (`&`, `<`, `>`: the
    /// `<style>` of an XHTML document is parsed as XML) is written as a CSS escape (`\26 `), so the name stays the same
    /// name and the text needs no second escaping for XHTML or HTML.
    static func cssString(_ name: String) -> String {
        var result = "\""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\"", "\\", "'", "&", "<", ">", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}":
                result += "\\" + String(scalar.value, radix: 16) + " "
            case _ where scalar.value < 0x20:
                result += "\\" + String(scalar.value, radix: 16) + " "
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// A family name as one path segment of the `epub://<id>/_reader/fonts/<name>` URL: everything but unreserved
    /// characters is percent-encoded, so the URL can stand in a CSS `url("…")` inside XHTML as it is.
    static func fontURLSegment(_ name: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Never traps: values outside `Int` (a fixed-layout viewport of `width=1e30`) are formatted without conversion.
    static func cssLength(_ value: Double) -> String {
        guard value.isFinite else { return "0px" }
        if value == value.rounded() {
            if let integer = Int(exactly: value) { return "\(integer)px" }
            return String(format: "%.0fpx", value)
        }
        return String(format: "%.2fpx", value)
    }
}
