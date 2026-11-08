import Foundation
import EPUBCore

/// Everything that changes how a document paginates: page size, spread, and the layout-affecting settings
/// (font, size, line height, margins). Theme colors are not part of it (docs/design/02-rendering.md §5.2).
struct LayoutKey: Hashable, Sendable {
    /// Page size in whole points (sub-point jitter from SwiftUI layout must not invalidate the cache).
    var pageWidth: Int
    var pageHeight: Int
    var settings: ReaderSettings.LayoutKey

    init(pageSize: CGSize, settings: ReaderSettings) {
        pageWidth = Int(pageSize.width.rounded())
        pageHeight = Int(pageSize.height.rounded())
        self.settings = settings.layoutKey
    }
}

/// Measured chapter page counts per `(publicationID, layoutKey)` (docs/design/02-rendering.md §5.2, §8.2).
///
/// One layout key is *selected* at a time; selecting a different key bumps the generation so that results
/// from loads that started under the previous key are ignored. Counts for other keys are kept, so switching the
/// settings back restores the measured values at once. `dropOtherLayouts` is the memory-warning response (§8.4).
@MainActor
final class PaginationCache {
    let publicationID: PublicationID
    private(set) var generation = 0
    private(set) var selectedKey: LayoutKey?
    private var entries: [LayoutKey: [Int: Int]] = [:]

    init(publicationID: PublicationID) {
        self.publicationID = publicationID
    }

    /// Makes `key` current. Returns `true` when it differs from the previous key (the generation was bumped).
    @discardableResult
    func select(_ key: LayoutKey) -> Bool {
        guard key != selectedKey else { return false }
        selectedKey = key
        generation += 1
        return true
    }

    /// Measured page counts (`spineIndex → pageCount`) for the selected key.
    var measured: [Int: Int] {
        selectedKey.flatMap { entries[$0] } ?? [:]
    }

    func pageCount(ofSpineIndex index: Int) -> Int? {
        selectedKey.flatMap { entries[$0]?[index] }
    }

    /// Records a measurement taken under `generation`. Stale generations are ignored. Returns whether the stored
    /// value changed.
    @discardableResult
    func store(spineIndex: Int, pageCount: Int, generation: Int) -> Bool {
        guard generation == self.generation, let key = selectedKey, pageCount > 0 else { return false }
        if entries[key]?[spineIndex] == pageCount { return false }
        entries[key, default: [:]][spineIndex] = pageCount
        return true
    }

    /// Forgets the measurements of every layout except the selected one.
    func dropOtherLayouts() {
        guard let key = selectedKey else { entries = [:]; return }
        entries = entries.filter { $0.key == key }
    }

    /// Number of layouts with stored measurements (tests, diagnostics).
    var layoutCount: Int { entries.count }
}
