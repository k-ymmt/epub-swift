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
        return dict
    }
}

/// Messages `reader.js` posts to Swift.
enum BridgeMessage: Sendable {
    case ready(writingMode: WritingMode)
    case pageCountChanged(Int)
    case link(href: String, isExternal: Bool)
    case tap(x: Double, y: Double)

    init?(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        let payload = dict["payload"] as? [String: Any] ?? [:]
        switch type {
        case "ready":
            self = .ready(writingMode: WritingMode(cssValue: payload["writingMode"] as? String ?? "horizontal-tb"))
        case "pageCountChanged":
            guard let count = payload["pageCount"] as? Int else { return nil }
            self = .pageCountChanged(count)
        case "link":
            guard let href = payload["href"] as? String else { return nil }
            self = .link(href: href, isExternal: payload["isExternal"] as? Bool ?? false)
        case "tap":
            self = .tap(x: payload["x"] as? Double ?? 0, y: payload["y"] as? Double ?? 0)
        default:
            return nil
        }
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

    /// Size of the visible page. Changing it resizes the frame; the document is re-laid out by `layout`.
    func setPageSize(_ size: CGSize)
    /// Axis of the three page slots: horizontal writing puts them side by side (frame three pages wide), vertical
    /// writing stacks them (frame three pages tall, one page wide; 02-rendering §1.2).
    func setWritingMode(_ mode: WritingMode)
    func setBackgroundColor(_ color: ReaderColor)
    /// Hides the document (shown again after the first page of a load is positioned).
    func setContentHidden(_ hidden: Bool)

    func load(_ url: URL)
    func layout(_ parameters: LayoutParameters) async throws -> LayoutResult
    func applySettings(_ parameters: LayoutParameters) async throws -> LayoutResult
    func goToPage(_ index: Int) async throws -> GoToPageResult
    func captureAnchor(slot: Int, margins: PageMargins) async throws -> Bool
    func pageForAnchor() async throws -> Int?
    func pageForFragment(_ fragment: String) async throws -> Int?
    /// Snapshot of the page in `slot` (0, 1 or 2 within the frame).
    func snapshot(slot: Int) async throws -> (image: CGImage, scale: CGFloat)?
    /// The slot currently aligned with the visible area.
    var visibleSlot: Int { get }
}
