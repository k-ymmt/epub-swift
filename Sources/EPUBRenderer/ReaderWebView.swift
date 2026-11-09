import Foundation
import WebKit

/// The web view that shows the document. Adds the app's `SelectionAction`s to the platform selection menu
/// (docs/design/03-api.md §4.4): iOS edit menu via `buildMenu(with:)`, macOS context menu via `willOpenMenu`.
///
/// The selection the actions receive is the one last reported by `reader.js` (`selectionChanged`, debounced), so
/// the menu is extended only when a selection is known; the standard items are never removed.
@MainActor
final class ReaderWebView: WKWebView {
    /// Supplies the current actions and selection when the menu is about to be shown.
    var selectionMenuSource: SelectionMenuSource?

    #if canImport(AppKit)
    /// Called whenever `magnification` changes, by a pinch (`magnify(with:)`), a smart magnify or a programmatic set
    /// (M4, 02-rendering §6.3). `WKWebView.magnification` is not KVO-compliant.
    var onMagnificationChanged: (@MainActor (CGFloat) -> Void)?

    override var magnification: CGFloat {
        didSet { if magnification != oldValue { onMagnificationChanged?(magnification) } }
    }

    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        super.setMagnification(magnification, centeredAt: point)
        onMagnificationChanged?(self.magnification)
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnificationChanged?(magnification)
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
        onMagnificationChanged?(magnification)
    }
    #endif

    private func menuEntries() -> (actions: [SelectionAction], selection: SelectedText)? {
        guard let source = selectionMenuSource else { return nil }
        let actions = source.actions()
        guard !actions.isEmpty, let selection = source.selection() else { return nil }
        return (actions, selection)
    }

    #if canImport(UIKit)
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let entries = menuEntries() else { return }
        let children = entries.actions.map { action in
            UIAction(title: action.title, image: action.systemImage.map { UIImage(systemName: $0) } ?? nil) { _ in
                MainActor.assumeIsolated { action.handler(entries.selection) }
            }
        }
        let menu = UIMenu(title: "", identifier: UIMenu.Identifier("EPUB.selectionActions"), options: .displayInline, children: children)
        builder.insertSibling(menu, afterMenu: .standardEdit)
    }
    #elseif canImport(AppKit)
    private var pendingSelection: SelectedText?
    private var pendingActions: [String: SelectionAction] = [:]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        appendSelectionActions(to: menu)
    }

    /// Inserts the app's actions at the top of `menu` when a selection is known. Separated from `willOpenMenu` so
    /// tests can drive it without a real right-click.
    func appendSelectionActions(to menu: NSMenu) {
        guard let entries = menuEntries() else { return }
        pendingSelection = entries.selection
        pendingActions = Dictionary(entries.actions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var index = 0
        for action in entries.actions {
            let item = NSMenuItem(title: action.title, action: #selector(performSelectionAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.id
            if let name = action.systemImage {
                item.image = NSImage(systemSymbolName: name, accessibilityDescription: action.title)
            }
            menu.insertItem(item, at: index)
            index += 1
        }
        if index > 0, menu.items.count > index {
            menu.insertItem(.separator(), at: index)
        }
    }

    @objc private func performSelectionAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let action = pendingActions[id], let selection = pendingSelection else { return }
        action.handler(selection)
    }
    #endif
}

/// Closures the session installs so the web view can build the selection menu without holding the session.
struct SelectionMenuSource {
    var actions: @MainActor () -> [SelectionAction]
    var selection: @MainActor () -> SelectedText?
}
