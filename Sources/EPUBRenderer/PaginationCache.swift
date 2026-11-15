import Foundation
import EPUBCore

/// Everything that changes how a document paginates: page size, spread, and the layout-affecting settings
/// (font, size, line height, margins). Theme colors are not part of it (docs/design/02-rendering.md §5.2).
///
/// The scrolled layout has its own keys (docs/design/08-continuous-scroll.md §6.3): the width of the frame, the page
/// height P and the settings. P is the frame's height inside the insets, and the height limit of a chapter's
/// pictures, so a chapter's height depends on it; the frame's height and the insets count through P alone.
struct LayoutKey: Hashable, Sendable {
    /// Page size in whole points (sub-point jitter from SwiftUI layout must not invalidate the cache). Scrolled
    /// layout: the frame's width and the page height P.
    var pageWidth: Int
    var pageHeight: Int
    var settings: ReaderSettings.LayoutKey
    /// Whether reflowable chapters are shown as two facing pages in this layout (M4). Follows from the page size
    /// and the spread policy for a given book, but is recorded so the key says it outright.
    var isSpread: Bool
    /// The key of a scrolled layout: what is measured under it is a chapter's height, not its page count.
    var isScrolled = false

    init(pageSize: CGSize, settings: ReaderSettings, isSpread: Bool = false) {
        pageWidth = Int(pageSize.width.rounded())
        pageHeight = Int(pageSize.height.rounded())
        self.settings = settings.layoutKey
        self.isSpread = isSpread
    }

    /// The key of the scrolled layout in a frame `scrolledWidth` wide whose page is `pageHeight` tall.
    init(scrolledWidth: Double, pageHeight: Double, settings: ReaderSettings) {
        pageWidth = Int(scrolledWidth.rounded())
        self.pageHeight = Int(pageHeight.rounded())
        var scrolled = settings
        scrolled.layout = .scrolled
        self.settings = scrolled.layoutKey
        isSpread = false
        isScrolled = true
    }
}

/// Measured chapter page counts per `(publicationID, layoutKey)` (docs/design/02-rendering.md §5.2, §8.2), and for
/// the keys of the scrolled layout measured chapter heights (08-continuous-scroll §6.3: the page count is the height
/// over the page height when it is read).
///
/// One layout key is *selected* at a time; selecting a different key bumps the generation so that results
/// from loads that started under the previous key are ignored. Counts for other keys are kept, so switching the
/// settings back restores the measured values at once. `dropOtherLayouts` is the memory-warning response (§8.4).
@MainActor
final class PaginationCache {
    /// Who laid a chapter of the scrolled layout out.
    enum HeightSource: Sendable {
        /// The hidden web view that measures every chapter (`PaginationService`).
        case measurement
        /// The display web view: a chapter of its window.
        case display
    }

    /// The height of a chapter in a scrolled layout, by who measured it. What the reader sees is what counts: the
    /// display's value is used when there is one (08-continuous-scroll §6.2).
    struct ChapterHeight: Equatable, Sendable {
        var measured: Double?
        var displayed: Double?

        var value: Double? { displayed ?? measured }
    }

    let publicationID: PublicationID
    private(set) var generation = 0
    private(set) var selectedKey: LayoutKey?
    private var entries: [LayoutKey: [Int: Int]] = [:]
    private var heightEntries: [LayoutKey: [Int: ChapterHeight]] = [:]

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

    // MARK: Heights (the scrolled layout)

    /// Chapter heights (`spineIndex → height`) for the selected key.
    var heights: [Int: Double] {
        (selectedKey.flatMap { heightEntries[$0] } ?? [:]).compactMapValues(\.value)
    }

    func height(ofSpineIndex index: Int) -> Double? {
        chapterHeight(ofSpineIndex: index)?.value
    }

    /// Both values of a chapter (diagnostics: how far the measurement is from what the display shows).
    func chapterHeight(ofSpineIndex index: Int) -> ChapterHeight? {
        selectedKey.flatMap { heightEntries[$0]?[index] }
    }

    /// Both values of every chapter that has one, for the selected key.
    var chapterHeights: [Int: ChapterHeight] {
        selectedKey.flatMap { heightEntries[$0] } ?? [:]
    }

    /// Records a chapter's height taken under `generation`. Stale generations are ignored. Returns whether the
    /// height in use (`height(ofSpineIndex:)`) changed.
    @discardableResult
    func storeHeight(spineIndex: Int, height: Double, source: HeightSource, generation: Int) -> Bool {
        guard generation == self.generation, let key = selectedKey, height.isFinite, height > 0 else { return false }
        var entry = heightEntries[key]?[spineIndex] ?? ChapterHeight()
        let before = entry.value
        switch source {
        case .measurement: entry.measured = height
        case .display: entry.displayed = height
        }
        heightEntries[key, default: [:]][spineIndex] = entry
        return entry.value != before
    }

    /// Forgets the measurements of every layout except the selected one.
    func dropOtherLayouts() {
        guard let key = selectedKey else { entries = [:]; heightEntries = [:]; return }
        entries = entries.filter { $0.key == key }
        heightEntries = heightEntries.filter { $0.key == key }
    }

    /// Number of layouts with stored measurements (tests, diagnostics).
    var layoutCount: Int { Set(entries.keys).union(heightEntries.keys).count }
}
