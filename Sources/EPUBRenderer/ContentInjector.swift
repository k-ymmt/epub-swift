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
        let head: String
        var tail: String
        if let fixed = injection.fixedStylesheetURL {
            head = ""
            tail = "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escapeAttribute(fixed))\"/>"
        } else {
            head = "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escapeAttribute(injection.beforeStylesheetURL))\"/>"
                + ((injection.injectViewport && !hadViewport) ? viewportMeta : "")
            tail = "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(escapeAttribute(injection.afterStylesheetURL))\"/>"
            if !injection.rootStyle.isEmpty {
                tail += "<style id=\"__reader_settings\">\(injection.rootStyle)</style>"
            }
        }

        if let headOpen = range(ofTag: "head", in: text) {
            text.insert(contentsOf: head, at: headOpen.upperBound)
            if let headClose = text.range(of: "</head", options: .caseInsensitive, range: headOpen.upperBound..<text.endIndex) {
                text.insert(contentsOf: tail, at: headClose.lowerBound)
            } else {
                // Unterminated head: put everything at the head start.
                text.insert(contentsOf: tail, at: text.index(headOpen.upperBound, offsetBy: head.count))
            }
        } else if let htmlOpen = range(ofTag: "html", in: text) {
            text.insert(contentsOf: "<head>" + head + tail + "</head>", at: htmlOpen.upperBound)
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

    /// Range of the start tag `<name ...>` (the whole tag including `>`), skipping the XML declaration, doctype
    /// and comments. Case-insensitive.
    static func range(ofTag name: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while let open = text.range(of: "<\(name)", options: .caseInsensitive, range: searchStart..<text.endIndex) {
            // Must be followed by whitespace, '>' or '/' to be this tag (not <header>, <html5>...).
            let afterName = open.upperBound
            if afterName < text.endIndex {
                let c = text[afterName]
                if !(c.isWhitespace || c == ">" || c == "/") {
                    searchStart = afterName
                    continue
                }
            }
            guard let close = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
            return open.lowerBound..<close.upperBound
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
            let url = "epub://\(publicationID)/_reader/fonts/\(ContainerPath.percentEncoded(resource.familyName))"
            css += " @font-face { font-family: \"\(resource.familyName)\"; src: url(\"\(url)\"); }"
        }
        // The attributes reader.js sets after load, pre-applied through the selector-less fallback so that the
        // first paint already uses the theme/font flags.
        var rootAttrs: [String] = []
        if settings.theme.isDark { rootAttrs.append("html { color-scheme: dark; }") }
        if settings.font != .publisher {
            rootAttrs.append("html body, html body * { font-family: var(--reader-font-family) !important; }")
        }
        if settings.theme.isDark {
            rootAttrs.append("html body *:not(a) { color: var(--reader-fg) !important; } html img, html svg { filter: brightness(0.85); }")
        }
        return css + (rootAttrs.isEmpty ? "" : " " + rootAttrs.joined(separator: " "))
    }

    static func fontFamilyCSS(_ font: ReaderSettings.FontChoice) -> String? {
        switch font {
        case .publisher: return nil
        case .system(let name): return "\"\(name.replacingOccurrences(of: "\"", with: ""))\", -apple-system, system-ui, sans-serif"
        case .custom(let resource): return "\"\(resource.familyName.replacingOccurrences(of: "\"", with: ""))\", -apple-system, system-ui, sans-serif"
        }
    }

    static func cssLength(_ value: Double) -> String {
        if value == value.rounded() { return "\(Int(value))px" }
        return String(format: "%.2fpx", value)
    }
}
