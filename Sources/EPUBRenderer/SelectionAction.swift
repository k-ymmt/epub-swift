import Foundation

/// An app-defined entry in the text selection menu (docs/design/03-api.md §4.4).
///
/// Lives in EPUBRenderer (M3 で変更: the design placed it in EPUBUI) because the platform web view builds the menu;
/// EPUBUI's `.selectionActions(_:)` modifier forwards the actions to `ReaderSession.selectionActions`, and apps
/// that host the session without SwiftUI set that property directly.
public struct SelectionAction: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var systemImage: String?
    /// Called on the main actor with the selection the menu was shown for.
    public var handler: @MainActor (SelectedText) -> Void

    public init(id: String? = nil, title: String, systemImage: String? = nil, handler: @escaping @MainActor (SelectedText) -> Void) {
        self.id = id ?? title
        self.title = title
        self.systemImage = systemImage
        self.handler = handler
    }
}
