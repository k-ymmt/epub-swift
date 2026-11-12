import Foundation
import EPUBCore

#if canImport(AppKit)
import AppKit
public typealias PlatformView = NSView
#else
import UIKit
public typealias PlatformView = UIView
#endif

/// Result of `reader.js` `layout` / `applySettings`.
struct LayoutResult: Sendable {
    var pageCount: Int
    var writingMode: WritingMode
    /// Columns per page in effect (2 for a horizontal reflowable spread; 1 otherwise, M4).
    var columnsPerPage: Int = 1
}

/// Result of `reader.js` `goToPage`.
struct GoToPageResult: Sendable {
    var pageIndex: Int
    /// Which of the frame's page slots the page landed in (0 = leftmost). Swift offsets the web view so that
    /// this slot sits in the visible area (02-rendering §1.2).
    var slot: Int
    var pageCount: Int
    /// Document scroll position after the move (CSS px), as read back from the document.
    var scrollOffset: CGPoint = .zero
}

/// Layout parameters passed to `reader.js`.
struct LayoutParameters: Sendable {
    var pageSize: CGSize
    var settings: ReaderSettings
    /// Replacement for the `<style id="__reader_settings">` the scheme handler injected at load time
    /// (`ContentInjector.rootStyle`), so that settings changes undo earlier overrides and add `@font-face` rules.
    var rootStyle: String? = nil
    /// Spine steps of the document being laid out (`/6/14[xchapter_001]`), prefixed to the CFIs the script generates.
    var spineSteps: [CFI.Step] = []
    /// 2 shows a horizontal reflowable chapter as two facing pages (two columns per page stride; M4, 02-rendering
    /// §6.2). Vertical writing ignores it (the renderer uses the vertical wrapper instead).
    var columnsPerPage: Int = 1

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "pageWidth": Double(pageSize.width),
            "pageHeight": Double(pageSize.height),
            "margins": ["horizontal": settings.pageMargins.horizontal, "vertical": settings.pageMargins.vertical],
            "fontScale": settings.fontScale,
            "lineHeight": settings.lineHeight,
            "theme": [
                "foreground": settings.theme.foreground.cssString,
                "background": settings.theme.background.cssString,
                "link": settings.theme.link.cssString,
                "isDark": settings.theme.isDark,
            ],
        ]
        dict["fontFamily"] = ContentInjector.fontFamilyCSS(settings.font) ?? ""
        if let rootStyle { dict["rootStyle"] = rootStyle }
        dict["spineSteps"] = CFI.render(steps: spineSteps)
        dict["columnsPerPage"] = columnsPerPage
        return dict
    }
}

/// Messages `reader.js` posts to Swift.
enum BridgeMessage: Sendable {
    /// Whether a `ready` message's `href` is the document `load(_:)` returned for the pending load. Every load carries
    /// a unique query, so two loads of the same chapter are told apart. A missing href is accepted.
    static func readyMatches(href: String?, url: URL) -> Bool {
        guard let href, let readyURL = URL(string: href) else { return true }
        return readyURL.absoluteString == url.absoluteString
    }

    /// `href` is the document's URL, so that a late `ready` from a document replaced by a newer load can be ignored.
    case ready(writingMode: WritingMode, href: String?)
    case pageCountChanged(Int)
    case link(href: String, isExternal: Bool)
    case tap(x: Double, y: Double)
    /// A tap inside a drawn highlight. Rects are in the web view's viewport coordinates.
    case highlightTap(id: String, rects: [CGRect])
    /// The document selection changed; nil when it was cleared or collapsed.
    case selectionChanged(BridgeSelection?)
    /// A noteref was tapped (M5). `rect` is in viewport coordinates.
    case noteref(BridgeNoteref)
    /// An image was tapped (M5). `rect` and the point are in viewport coordinates.
    case imageTap(src: String, alt: String?, rect: CGRect, x: Double, y: Double)

    init?(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        let payload = dict["payload"] as? [String: Any] ?? [:]
        switch type {
        case "ready":
            self = .ready(writingMode: WritingMode(cssValue: payload["writingMode"] as? String ?? "horizontal-tb"), href: payload["href"] as? String)
        case "pageCountChanged":
            guard let count = payload["pageCount"] as? Int else { return nil }
            self = .pageCountChanged(count)
        case "link":
            guard let href = payload["href"] as? String else { return nil }
            self = .link(href: href, isExternal: payload["isExternal"] as? Bool ?? false)
        case "tap":
            self = .tap(x: payload["x"] as? Double ?? 0, y: payload["y"] as? Double ?? 0)
        case "highlightTap":
            guard let id = payload["id"] as? String else { return nil }
            self = .highlightTap(id: id, rects: BridgeMessage.rects(from: payload["rects"]))
        case "selectionChanged":
            self = .selectionChanged(BridgeSelection(payload["selection"]))
        case "noteref":
            guard let href = payload["href"] as? String else { return nil }
            self = .noteref(BridgeNoteref(
                href: href,
                rect: BridgeMessage.rects(from: [payload["rect"]].compactMap { $0 }).first ?? .zero,
                isSameDocument: payload["sameDocument"] as? Bool ?? false,
                html: payload["html"] as? String,
                text: payload["text"] as? String,
                cfi: (payload["cfi"] as? String).flatMap(CFI.init),
                isHidden: payload["hidden"] as? Bool ?? false
            ))
        case "imageTap":
            guard let src = payload["src"] as? String else { return nil }
            self = .imageTap(
                src: src,
                alt: payload["alt"] as? String,
                rect: BridgeMessage.rects(from: [payload["rect"]].compactMap { $0 }).first ?? .zero,
                x: payload["x"] as? Double ?? 0,
                y: payload["y"] as? Double ?? 0
            )
        default:
            return nil
        }
    }

    /// `[{x, y, width, height}]` → rects.
    static func rects(from value: Any?) -> [CGRect] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let x = dict["x"] as? Double, let y = dict["y"] as? Double,
                  let width = dict["width"] as? Double, let height = dict["height"] as? Double else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// `{href, rect, sameDocument, html?, text?, cfi?, hidden?}` from a `noteref` message (M5).
struct BridgeNoteref: Sendable {
    var href: String
    var rect: CGRect
    var isSameDocument: Bool
    var html: String?
    var text: String?
    var cfi: CFI?
    /// The note element is not laid out on the page (same-document notes only).
    var isHidden = false
}

/// `{cfiRange, text, rects}` from `currentSelection` / `selectionChanged`. Rects are viewport coordinates.
struct BridgeSelection: Sendable {
    var range: CFIRange
    var text: String
    var rects: [CGRect]

    init?(_ value: Any?) {
        guard let dict = value as? [String: Any], let cfi = dict["cfiRange"] as? String, let range = CFIRange(cfi),
              let text = dict["text"] as? String else { return nil }
        self.range = range
        self.text = text
        self.rects = BridgeMessage.rects(from: dict["rects"])
    }
}

/// The boundary `ReaderSession` talks to. The WKWebView implementation is the only one today; a native
/// renderer could replace it later (docs/design/03-api.md §5).
@MainActor
protocol SpineRenderer: AnyObject {
    /// The view that shows the current page (already clipped to one page).
    var view: PlatformView { get }
    /// Messages from the document.
    var onMessage: (@MainActor (BridgeMessage) -> Void)? { get set }
    var onNavigationFailed: (@MainActor (Error) -> Void)? { get set }
    var onProcessTerminated: (@MainActor () -> Void)? { get set }
    /// Supplies the app's `SelectionAction`s and the current selection to the platform selection menu.
    var selectionMenuSource: SelectionMenuSource? { get set }

    /// Size of the visible page. Changing it resizes the frame; the document is re-laid out by `layout`.
    func setPageSize(_ size: CGSize)
    /// Axis of the three page slots: horizontal writing puts them side by side (frame three pages wide), vertical
    /// writing stacks them (frame three pages tall, one page wide; 02-rendering §1.2).
    func setWritingMode(_ mode: WritingMode)
    func setBackgroundColor(_ color: ReaderColor)
    /// Hides the document (shown again after the first page of a load is positioned).
    func setContentHidden(_ hidden: Bool)
    /// Allows pinch zoom (iOS: the scroll view's pinch; macOS: `allowsMagnification`). Fixed-layout faces only
    /// (02-rendering §6.3, M4). Disabling also resets the zoom.
    func setZoomEnabled(_ enabled: Bool)
    /// Back to scale 1.
    func resetZoom()
    /// Reports zoom scale changes (`true` while the scale is above 1).
    var onZoomChanged: (@MainActor (Bool) -> Void)? { get set }

    /// Starts loading `url`. Returns the URL actually requested: `url` plus a unique query that identifies this
    /// load in the document's `location.href` (the `ready` message carries it back).
    @discardableResult
    func load(_ url: URL) -> URL
    func layout(_ parameters: LayoutParameters) async throws -> LayoutResult
    func applySettings(_ parameters: LayoutParameters) async throws -> LayoutResult
    func goToPage(_ index: Int) async throws -> GoToPageResult
    func pageForFragment(_ fragment: String) async throws -> Int?
    /// CFI of the first text on page `index` (nil for a page without content).
    func cfiForPage(_ index: Int, margins: PageMargins) async throws -> CFI?
    /// Page that contains the position of `cfi` (a point, or the start of a range); nil when it does not resolve.
    func pageFor(_ cfi: CFI) async throws -> Int?
    /// Client rects (viewport coordinates of the three-slot frame) of a CFI range.
    func rects(for range: CFIRange) async throws -> [CGRect]
    /// Draws the highlights (replacing the previous set), later ones above earlier ones. Returns the ids that
    /// resolved.
    func setHighlights(_ highlights: [HighlightDrawing]) async throws -> [String]
    /// Draws (or with nil, removes) the single temporary highlight.
    func setTransientHighlight(_ range: CFIRange?) async throws
    func currentSelection() async throws -> BridgeSelection?
    func clearSelection() async throws
    /// Snapshot of the page in `slot` (0, 1 or 2 within the frame).
    func snapshot(slot: Int) async throws -> (image: CGImage, scale: CGFloat)?
    /// The slot currently aligned with the visible area.
    var visibleSlot: Int { get }
}

/// One highlight as `reader.js` draws it (06-annotations §10.2). `id` is the bridge id (layer prefix plus the
/// annotation id).
struct HighlightDrawing: Hashable, Sendable {
    enum Style: String, Sendable {
        case solid, underline, strikethrough, outline
    }

    var id: String
    var range: CFIRange
    var color: ReaderColor
    var style: Style

    /// How `annotation` is drawn with `theme`: `.other` styles draw solid, colors outside the palette in the
    /// fallback color.
    init(id: String, annotation: Annotation, range: CFIRange, theme: ReaderTheme) {
        self.id = id
        self.range = range
        var color = theme.color(for: annotation.color)
        switch annotation.style {
        case .underline: style = .underline
        case .strikethrough: style = .strikethrough
        case .outline: style = .outline
        case .solid, .other:
            style = .solid
            color.alpha *= ReaderTheme.solidHighlightOpacity
        }
        self.color = color
    }
}
