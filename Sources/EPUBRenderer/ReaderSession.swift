import Foundation
import Observation
import os
import EPUBCore
#if canImport(UIKit)
import UIKit
#endif

/// The reading state of one publication (docs/design/03-api.md §3.2).
///
/// Loads a spine item into the web view, pages within it, crosses chapter boundaries, applies `ReaderSettings`
/// with position restoration, provides page snapshots for the UI layer's page-turn effects (M1 / M2), and keeps
/// the reading position as a CFI (`position`), the selection, the highlights and the search (M3).
@MainActor
@Observable
public final class ReaderSession {
    public let publication: Publication
    public let container: EPUBContainer

    /// Changing a value re-layouts the current chapter and restores the position.
    public var settings: ReaderSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsDidChange(from: oldValue)
        }
    }

    public private(set) var currentSpineIndex: Int = 0
    /// Page index within the current chapter.
    public private(set) var currentPageIndex: Int = 0
    /// Number of pages in the current chapter (1 until the first layout completes).
    public private(set) var chapterPageCount: Int = 1
    /// `true` while a chapter is loading or being re-laid out.
    public private(set) var isLoading: Bool = false
    /// `true` once the first chapter is visible.
    public private(set) var hasLoaded: Bool = false
    /// Writing mode of the current document as reported by the bridge (M2: typed; was the raw CSS string in M1).
    public private(set) var writingMode: WritingMode = .horizontalTB

    /// The face being shown (M4): one reflowable item, or one or two fixed-layout pages. nil until the first load.
    private(set) var currentUnit: SpreadPlan.Unit?
    /// Whether the visible face is a spread wrapper document (fixed layout, or a vertical-writing chapter shown as
    /// two frames) rather than the chapter itself (M4). The wrapper has no neighbour page slots.
    @ObservationIgnored private var loadedAsWrapper = false
    /// How the reading order is cut into faces for the current viewport and `settings.spreadPolicy` (M4).
    private(set) var spreadPlan = SpreadPlan(units: [])

    /// Whether the visible face is laid out as two pages (a fixed-layout spread, or a reflowable chapter shown as
    /// two facing pages; docs/design/03-api.md §3.2, M4). `false` for a single page.
    public var isShowingSpread: Bool { currentUnit?.isTwoPageLayout ?? false }

    /// Spine indices of the documents on the visible face, in reading order: one item, or the two pages of a
    /// fixed-layout spread (M4). `currentSpineIndex` is the first of them.
    public var visibleSpineIndices: [Int] { currentUnit?.spineIndices ?? (hasLoaded ? [currentSpineIndex] : []) }

    /// `true` while a fixed-layout face is pinch-zoomed in (M4, docs/design/02-rendering.md §6.3). EPUBUI turns its
    /// page-turn gestures off meanwhile; loading another face resets the zoom.
    public private(set) var isZoomed = false

    /// Whether pages progress right-to-left: `page-progression-direction="rtl"`, or a vertical-rl document when the
    /// package does not say otherwise. EPUBUI flips tap zones, swipes and the transition direction on this
    /// (docs/design/03-api.md §4.3).
    public var isRightToLeft: Bool {
        switch publication.pageProgression {
        case .rtl: return true
        case .ltr: return false
        case .default: return writingMode.isRightToLeftByDefault
        }
    }

    /// Page numbering across the book: measured chapters plus estimates for the rest (docs/design/03-api.md §3.3).
    /// Updated as the pre-pagination service measures chapters; `ReaderEvent.paginationUpdated` mirrors it.
    public private(set) var pagination: BookPagination = .empty

    /// Book page index (0-based) of the visible page, or nil while nothing is loaded / for a non-linear item.
    public var currentPage: Int? {
        guard hasLoaded else { return nil }
        return pagination.pageIndex(spineIndex: currentSpineIndex, pageIndex: currentPageIndex)
    }

    /// The page as it looked before the relayout in progress (settings change, resize), until the position has been
    /// restored in the new layout; nil otherwise. `EPUBReaderView` shows it over the web view and cross-fades it
    /// away (docs/design/03-api.md §4.5).
    public private(set) var relayoutSnapshot: PageSnapshot?

    /// The reading position: the CFI of the first text on the visible page, refreshed after every page change and
    /// relayout (docs/design/02-rendering.md §5.3). nil until the first chapter is shown, or for a page without
    /// text (an image-only page keeps the previous value). `ReaderEvent.positionChanged` mirrors it.
    public private(set) var position: ReadingPosition?

    /// The text selection as last reported by the document (debounced); nil when there is none. Mirrors
    /// `ReaderEvent.selectionChanged` (docs/design/03-api.md §3.2).
    public private(set) var currentSelection: SelectedText?

    /// Entries the platform selection menu offers in addition to the system ones (03-api §4.4). EPUBUI's
    /// `.selectionActions(_:)` modifier sets this; apps hosting the session without SwiftUI set it directly. Read when
    /// the menu opens; not observed (EPUBUI assigns it on every view update, since handlers cannot be compared).
    @ObservationIgnored public var selectionActions: [SelectionAction] = []

    /// Highlights to draw (03-api §2.5). The app owns and persists them; the session draws the ones in the current
    /// chapter whenever the set changes and after every chapter load. Ranges that no longer resolve are skipped.
    public var highlights: [Highlight] = [] {
        didSet {
            guard highlights != oldValue else { return }
            enqueue { [weak self] in await self?.applyHighlights() }
        }
    }

    /// Size of one visible page. Set by `EPUBReaderView`; changing it re-layouts and restores the position.
    public var viewportSize: CGSize = .zero {
        didSet {
            guard viewportSize != oldValue, viewportSize.width > 0, viewportSize.height > 0 else { return }
            viewportSizeDidChange()
        }
    }

    /// Fraction of the current chapter read (0...1), from the page index.
    public var chapterProgression: Double {
        chapterPageCount > 1 ? Double(currentPageIndex) / Double(chapterPageCount - 1) : 0
    }

    /// Fraction of the book read (0...1) from `pagination` (an estimate while `pagination.isEstimated`). Falls back
    /// to a spine-position approximation for non-linear items.
    public var totalProgression: Double {
        if hasLoaded, let progression = pagination.progression(spineIndex: currentSpineIndex, pageIndex: currentPageIndex) {
            return progression
        }
        let linear = publication.linearReadingOrder
        guard !linear.isEmpty else { return 0 }
        guard let position = linear.firstIndex(where: { $0.index == currentSpineIndex }) else { return 0 }
        let perChapter = 1.0 / Double(linear.count)
        return min(1, perChapter * (Double(position) + (chapterPageCount > 0 ? Double(currentPageIndex + 1) / Double(chapterPageCount) : 0)))
    }

    /// Whether the current chapter is the last page of the linear reading order (nothing further forward).
    public var isAtEnd: Bool {
        currentPageIndex >= chapterPageCount - 1 && nextLinearSpineIndex(after: currentSpineIndex) == nil
    }

    public var isAtStart: Bool {
        currentPageIndex == 0 && previousLinearSpineIndex(before: currentSpineIndex) == nil
    }

    /// Events for the app. Each access returns a new stream; all of them receive every event.
    public var events: AsyncStream<ReaderEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.eventContinuations[id] = nil }
            }
        }
    }

    @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<ReaderEvent>.Continuation] = [:]
    @ObservationIgnored let renderer: any SpineRenderer
    @ObservationIgnored private let schemeHandler: EPUBSchemeHandler
    @ObservationIgnored let paginationCache: PaginationCache
    @ObservationIgnored let paginationService: PaginationService
    @ObservationIgnored private var memoryWarningObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var readyContinuation: CheckedContinuation<WritingMode, any Error>?
    @ObservationIgnored private var pendingLoadURL: URL?
    /// The load in progress (spine index and target), so a WebContent crash during it can be retried (§9).
    @ObservationIgnored private var loadInProgress: (spineIndex: Int, target: LoadTarget)?
    /// Times of recent WebContent crashes; automatic reloads stop after a few in a short time (a document that
    /// crashes the process every time would otherwise loop).
    @ObservationIgnored private var recentTerminations: [ContinuousClock.Instant] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var relayoutTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: Task<Void, Never>?
    @ObservationIgnored private var relayoutSnapshotTask: Task<Void, Never>?
    /// Page size the display web view is laid out for (lags `viewportSize` until the resize relayout runs).
    @ObservationIgnored private var laidOutPageSize: CGSize = .zero
    @ObservationIgnored private var operationQueue: [() async -> Void] = []
    @ObservationIgnored private var searchService: SearchService?
    /// The search result highlight currently drawn; removed by the next navigation.
    @ObservationIgnored private var transientHighlight: CFIRange?
    @ObservationIgnored private var keepTransientHighlight = false
    @ObservationIgnored private var isRunningOperation = false
    @ObservationIgnored private let logger = Logger(subsystem: "EPUB", category: "ReaderSession")

    static let loadTimeout: Duration = .seconds(10)
    /// Window resizes on macOS come as a stream of sizes; the relayout waits for them to settle (03-api §4.5).
    /// On iOS a size change (rotation, split view) is a single event and is applied at once.
    static let resizeDebounce: Duration = {
        #if os(macOS)
        return .milliseconds(150)
        #else
        return .zero
        #endif
    }()

    public init(container: EPUBContainer, settings: ReaderSettings = ReaderSettings()) {
        self.container = container
        self.publication = container.publication
        self.settings = settings
        self.spreadPlan = SpreadBuilder.plan(for: container.publication, policy: settings.spreadPolicy, viewportSize: .zero)
        let handler = EPUBSchemeHandler()
        self.schemeHandler = handler
        self.renderer = WebViewSpineRenderer(schemeHandler: handler)
        self.paginationCache = PaginationCache(publicationID: container.id)
        self.paginationService = PaginationService(container: container, schemeHandler: handler, cache: paginationCache)
        PublicationRegistry.shared.register(container)
        if case .custom(let resource) = settings.font {
            PublicationRegistry.shared.registerFont(resource, for: container.id)
        }
        handler.onWarning = { [weak self] warning in self?.emit(.warning(warning)) }
        renderer.onMessage = { [weak self] message in self?.handle(message) }
        renderer.onNavigationFailed = { [weak self] error in
            guard let self else { return }
            self.failPendingLoad(ReaderError.loadFailed(spineIndex: self.currentSpineIndex, underlying: error.localizedDescription))
        }
        renderer.onProcessTerminated = { [weak self] in self?.webContentProcessDidTerminate() }
        renderer.selectionMenuSource = SelectionMenuSource(
            actions: { [weak self] in self?.selectionActions ?? [] },
            selection: { [weak self] in self?.currentSelection }
        )
        renderer.onZoomChanged = { [weak self] zoomed in
            guard let self, self.isZoomed != zoomed else { return }
            self.isZoomed = zoomed
            self.emit(.zoomChanged(zoomed))
        }
        renderer.setBackgroundColor(settings.theme.background)
        renderer.setContentHidden(true)
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: .zero, publicationID: container.id)
        currentSpineIndex = publication.linearReadingOrder.first?.index ?? 0
        paginationService.onChapterMeasured = { [weak self] _, _ in self?.rebuildPagination() }
        rebuildPagination()
        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReceiveMemoryWarning() }
        }
        #endif
    }

    isolated deinit {
        let id = container.id
        paginationService.cancel()
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        Task { @MainActor in PublicationRegistry.shared.unregister(id) }
    }

    /// The platform view that shows the current page. Used by EPUBUI's representable; not part of the public API.
    @_spi(EPUBUI) public var platformView: PlatformView { renderer.view }

    // MARK: - Navigation

    /// Next page, or the first page of the next linear spine item.
    public func goForward() async {
        await run { [self] in
            // Ask the document for page `current + 1` even when it looks like the last page: the page count can grow
            // after late image loads, and `goToPage` re-measures before clamping. Only when the document cannot move
            // forward is the next chapter loaded.
            let before = currentPageIndex
            let moved = await goToPageInChapter(currentPageIndex + 1, clampToKnownCount: false)
            if moved, currentPageIndex == before, let next = nextLinearSpineIndex(after: currentSpineIndex) {
                await loadChapter(next, target: .first)
            }
        }
    }

    /// Previous page, or the last page of the previous linear spine item.
    public func goBackward() async {
        await run { [self] in
            if currentPageIndex > 0 {
                await goToPageInChapter(currentPageIndex - 1)
            } else if let previous = previousLinearSpineIndex(before: currentSpineIndex) {
                await loadChapter(previous, target: .last)
            }
        }
    }

    public func go(toSpineIndex index: Int) async {
        guard publication.readingOrder.indices.contains(index) else { return }
        await run { [self] in
            // The other page of the visible fixed-layout spread is already on screen.
            if hasLoaded, isShowing(spineIndex: index), isShowingWrapper, currentUnit?.isFixedLayout == true { return }
            await loadChapter(index, target: .first)
        }
    }

    /// Jumps to a table-of-contents entry (spine item plus optional fragment).
    public func go(to entry: TOCEntry) async {
        guard let spineIndex = entry.spineIndex ?? entry.href.flatMap({ publication.spineIndex(ofPath: $0) }) else { return }
        // The nav keeps the href's fragment as written; the document is asked for the decoded id.
        let fragment = entry.fragment.flatMap { $0.isEmpty ? nil : ($0.removingPercentEncoding ?? $0) }
        await run { [self] in
            if isShowing(spineIndex: spineIndex), hasLoaded, let fragment {
                if let page = try? await renderer.pageForFragment(fragment) { await goToPageInChapter(page) }
                return
            }
            if hasLoaded, isShowing(spineIndex: spineIndex), isShowingWrapper, currentUnit?.isFixedLayout == true { return }
            await loadChapter(spineIndex, target: fragment.map { .fragment($0) } ?? .first)
        }
    }

    /// Page `index` within the current chapter.
    public func go(toPageInChapter index: Int) async {
        await run { [self] in await goToPageInChapter(index) }
    }

    /// Book page `index` (0-based, `BookPagination` numbering). For a chapter whose count is still an estimate the
    /// in-chapter page is approximate and clamped once the chapter is laid out.
    public func go(toPage index: Int) async {
        guard let location = pagination.location(ofPageIndex: index) else { return }
        await run { [self] in
            if isShowing(spineIndex: location.spineIndex), hasLoaded {
                await goToPageInChapter(location.pageIndex)
            } else {
                await loadChapter(location.spineIndex, target: .page(location.pageIndex))
            }
        }
    }

    /// Moves to the page that holds `cfi` (loading its chapter when needed). An unresolvable CFI in a known
    /// chapter lands on the chapter's first page.
    public func go(to cfi: CFI) async {
        guard let spineIndex = publication.spineIndex(of: cfi) else { return }
        await run { [self] in await goToCFI(cfi, spineIndex: spineIndex) }
    }

    /// The body of `go(to:)`, for use inside an operation.
    private func goToCFI(_ cfi: CFI, spineIndex: Int) async {
        if isShowing(spineIndex: spineIndex), hasLoaded {
            let page = (try? await renderer.pageFor(cfi)) ?? nil
            await goToPageInChapter(page ?? currentPageIndex)
        } else {
            await loadChapter(spineIndex, target: .cfi(cfi))
        }
    }

    /// Restores a position recorded earlier (`position`), for example at the next launch.
    public func go(to position: ReadingPosition) async {
        await go(to: position.cfi)
    }

    /// Book page index of a recorded position, from the chapter's current page count and the position's
    /// in-chapter progression. Approximate for chapters that are still estimates; nil for non-linear items.
    public func pageIndex(for position: ReadingPosition) -> Int? {
        guard let chapter = pagination.chapter(spineIndex: position.spineIndex) else { return nil }
        let inChapter = Int((position.progressionInChapter * Double(max(0, chapter.pageCount - 1))).rounded())
        return pagination.pageIndex(spineIndex: position.spineIndex, pageIndex: inChapter)
    }

    /// Snapshot of the current, next or previous page for the UI's page-turn effect. At a chapter boundary the
    /// neighbouring chapter's first / last page comes from the pre-pagination web view (02-rendering §8.3); nil when
    /// it has not been captured yet (the UI substitutes the background color).
    public func pageSnapshot(_ target: PageSnapshotTarget) async -> PageSnapshot? {
        guard hasLoaded, !isLoading else { return nil }
        let visibleSlot = renderer.visibleSlot
        let pageIndex: Int
        let slot: Int
        switch target {
        case .current:
            pageIndex = currentPageIndex
            slot = visibleSlot
        case .next:
            if currentPageIndex + 1 >= chapterPageCount {
                guard let next = nextLinearSpineIndex(after: currentSpineIndex) else { return nil }
                return paginationService.snapshot(firstPageOf: leadingSpineIndex(ofFaceContaining: next))
            }
            // A spread wrapper draws the whole face in slot 0 and has no neighbour slots (M4): the UI turns without
            // a destination picture and shows the arrived page instead.
            guard !isShowingWrapper, visibleSlot + 1 < WebViewSpineRenderer.slotCount else { return nil }
            pageIndex = currentPageIndex + 1
            slot = visibleSlot + 1
        case .previous:
            if currentPageIndex == 0 {
                guard let previous = previousLinearSpineIndex(before: currentSpineIndex) else { return nil }
                // Snapshots are stored under a face's leading index; the item before a spread is its last page (M4).
                return paginationService.snapshot(lastPageOf: leadingSpineIndex(ofFaceContaining: previous))
            }
            guard !isShowingWrapper, visibleSlot - 1 >= 0 else { return nil }
            pageIndex = currentPageIndex - 1
            slot = visibleSlot - 1
        }
        do {
            guard let result = try await renderer.snapshot(slot: slot) else { return nil }
            return PageSnapshot(image: result.image, scale: result.scale, size: viewportSize, spineIndex: currentSpineIndex, pageIndex: pageIndex)
        } catch {
            logger.debug("snapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Back to scale 1 after a pinch zoom on a fixed-layout face (M4).
    public func resetZoom() {
        renderer.resetZoom()
    }

    /// Opens the first linear spine item if nothing has been loaded yet. `EPUBReaderView` calls this once it
    /// knows its size; apps that drive the session themselves can call it after setting `viewportSize`.
    public func loadIfNeeded() async {
        guard !hasLoaded, !isLoading, viewportSize.width > 0 else { return }
        await run { [self] in
            guard !hasLoaded else { return }
            await loadChapter(currentSpineIndex, target: .first)
        }
    }

    // MARK: - Chapter loading

    enum LoadTarget {
        case first
        case last
        case page(Int)
        case fragment(String)
        case cfi(CFI)
    }

    func loadChapter(_ spineIndex: Int, target: LoadTarget) async {
        guard publication.readingOrder.indices.contains(spineIndex), viewportSize.width > 0 else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadInProgress = (spineIndex, target)
        defer { if generation == loadGeneration { loadInProgress = nil } }
        renderer.setContentHidden(true)
        // The document is replaced: its selection and temporary highlight go with it.
        transientHighlight = nil
        if currentSelection != nil {
            currentSelection = nil
            emit(.selectionChanged(nil))
        }
        applyPageSize()
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
        selectLayout()
        // The size the layout key and the spread plan were chosen for. Before the first load completes a resize only
        // updates the page size (`viewportSizeDidChange`), so a mismatch at the end re-selects the layout.
        let layoutSize = viewportSize
        // The face that holds the item: a fixed-layout page loads through the spread wrapper, with its partner (M4).
        let unit = spreadPlan.unit(containing: spineIndex) ?? .reflowable(spineIndex: spineIndex, twoPages: false)
        let leading = unit.leadingSpineIndex
        logger.debug("load spine \(spineIndex) unit \(unit.spineIndices)")
        do {
            // A two-page reflowable face is two columns in horizontal writing and the vertical wrapper in vertical
            // writing; the document's mode is known only after loading, so the current chapter's mode is the guess
            // and a wrong guess reloads the other way (02-rendering §6.2).
            var realization = Self.realization(of: unit, publicationID: container.id, publication: publication, writingModeHint: writingMode)
            var layout = try await load(realization, generation: generation, spineSteps: publication.cfiSpineSteps(forSpineIndex: leading))
            guard generation == loadGeneration else { return }
            if case .reflowable(let index, true) = unit, Self.realizationMismatches(realization, writingMode: layout.writingMode, publication: publication) {
                realization = Self.realization(of: .reflowable(spineIndex: index, twoPages: true), publicationID: container.id, publication: publication, writingModeHint: layout.writingMode)
                layout = try await load(realization, generation: generation, spineSteps: publication.cfiSpineSteps(forSpineIndex: leading))
                guard generation == loadGeneration else { return }
            }
            loadedAsWrapper = realization.isWrapper
            // Pinch zoom is for fixed-layout pages only; a new face starts at scale 1.
            renderer.setZoomEnabled(unit.isFixedLayout)
            renderer.resetZoom()
            writingMode = layout.writingMode
            renderer.setWritingMode(layout.writingMode)
            let pageCount = layout.pageCount
            let targetPage: Int
            switch target {
            case .first: targetPage = 0
            case .last: targetPage = pageCount - 1
            case .page(let p): targetPage = min(max(0, p), pageCount - 1)
            case .fragment(let fragment): targetPage = (try? await renderer.pageForFragment(fragment)) ?? 0
            case .cfi(let cfi): targetPage = ((try? await renderer.pageFor(cfi)) ?? nil) ?? 0
            }
            let result = try await renderer.goToPage(targetPage)
            guard generation == loadGeneration else { return }
            await applyHighlights(for: unit)
            guard generation == loadGeneration else { return }
            currentUnit = unit
            currentSpineIndex = leading
            chapterPageCount = result.pageCount
            currentPageIndex = result.pageIndex
            // A resize waiting for its debounce re-lays out right after this load: stay "loading" until then. So does a
            // resize that arrived during the first load, before there was anything to re-lay out.
            let sizeChangedDuringLoad = viewportSize != layoutSize && pendingResize == nil
            isLoading = pendingResize != nil || sizeChangedDuringLoad
            hasLoaded = true
            renderer.setContentHidden(false)
            if !sizeChangedDuringLoad { recordChapterMeasurement(unit: unit, pageCount: result.pageCount) }
            paginationService.setCurrentSpineIndex(leading)
            await refreshPosition()
            if sizeChangedDuringLoad {
                // Re-selects the layout key and the spread plan for the new size; a face that changes is reloaded.
                enqueue { [weak self] in await self?.relayoutPreservingPosition() }
            }
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            if hasLoaded { renderer.setContentHidden(false) }
            // A crash during the load was reported by `webContentProcessDidTerminate`, which also retries it.
            if case .webContentTerminated? = error as? ReaderError { return }
            if let readerError = error as? ReaderError {
                emit(.error(readerError))
            } else {
                emit(.error(.loadFailed(spineIndex: spineIndex, underlying: error.localizedDescription)))
            }
        }
    }

    /// How a face is loaded: which URL, and how many columns per page the document is asked for.
    struct Realization {
        var url: URL
        var columnsPerPage: Int
        var isWrapper: Bool
        /// The writing mode a reflowable two-frame wrapper was built for (which frame holds the first page).
        var wrapperWritingMode: WritingMode? = nil
    }

    /// Whether a two-page reflowable face was realized for the wrong writing mode and must be loaded again: columns
    /// where the wrapper is needed (or the reverse), or a wrapper whose first page is on the wrong side
    /// (`vertical-rl` hint, `vertical-lr` document).
    static func realizationMismatches(_ realization: Realization, writingMode: WritingMode, publication: Publication) -> Bool {
        if realization.isWrapper != spreadNeedsWrapper(writingMode: writingMode, publication: publication) { return true }
        guard realization.isWrapper, let built = realization.wrapperWritingMode else { return false }
        return (built == .verticalLR) != (writingMode == .verticalLR)
    }

    static func realization(of unit: SpreadPlan.Unit, publicationID: PublicationID, publication: Publication, writingModeHint: WritingMode) -> Realization {
        switch unit {
        case .fixed:
            return Realization(url: SpreadDocument.url(publicationID: publicationID, unit: unit)!, columnsPerPage: 1, isWrapper: true)
        case .reflowable(let index, let twoPages):
            if twoPages, spreadNeedsWrapper(writingMode: writingModeHint, publication: publication) {
                return Realization(url: SpreadDocument.verticalURL(publicationID: publicationID, spineIndex: index, writingMode: writingModeHint), columnsPerPage: 1, isWrapper: true, wrapperWritingMode: writingModeHint)
            }
            let url = EPUBSchemeHandler.url(publicationID: publicationID, path: publication.readingOrder[index].path)
            return Realization(url: url, columnsPerPage: twoPages ? 2 : 1, isWrapper: false)
        }
    }

    /// Whether a reflowable chapter shown as two facing pages needs the two-frame wrapper rather than two columns:
    /// vertical writing (columns stack along y), and any chapter of a right-bound book, whose first page of the pair
    /// belongs on the right while columns always fill from the left (M5: Arabic and Hebrew books; 02-rendering §6.2).
    static func spreadNeedsWrapper(writingMode: WritingMode, publication: Publication) -> Bool {
        writingMode.isVertical || publication.pageProgression == .rtl
    }

    /// Loads a realization and lays it out.
    private func load(_ realization: Realization, generation: Int, spineSteps: [CFI.Step]) async throws -> LayoutResult {
        let mode = try await withReady(generation: generation) { renderer.load(realization.url) }
        // The frame's slot axis must match the document before it is measured (three pages tall for vertical writing).
        renderer.setWritingMode(mode)
        var parameters = LayoutParameters(pageSize: viewportSize, settings: settings, spineSteps: spineSteps)
        parameters.columnsPerPage = realization.columnsPerPage
        return try await renderer.layout(parameters)
    }

    /// Returns false when the document could not be asked (not loaded, or the script call failed); the page state
    /// is then unchanged and callers must not treat it as "already at the chapter end".
    @discardableResult
    private func goToPageInChapter(_ index: Int, clampToKnownCount: Bool = true) async -> Bool {
        guard hasLoaded else { return false }
        let clamped = clampToKnownCount ? min(max(0, index), chapterPageCount - 1) : max(0, index)
        await clearTransientHighlightIfNeeded()
        do {
            let result = try await renderer.goToPage(clamped)
            currentPageIndex = result.pageIndex
            chapterPageCount = result.pageCount
            recordChapterMeasurement(unit: currentUnit, pageCount: result.pageCount)
            await refreshPosition()
            return true
        } catch {
            emit(.error(.scriptFailed(error.localizedDescription)))
            return false
        }
    }

    /// Runs `start` and waits for the `ready` message (or a navigation failure / timeout).
    private func withReady(generation: Int, _ start: () -> URL) async throws -> WritingMode {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        let spineIndex = currentSpineIndex
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            self.failPendingLoad(.loadTimeout(spineIndex: spineIndex))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WritingMode, any Error>) in
            self.readyContinuation = continuation
            self.pendingLoadURL = start()
        }
    }

    private func failPendingLoad(_ error: ReaderError) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    // MARK: - Recovery (02-rendering §9)

    /// The display web view's WebContent process died (memory pressure, a WebKit crash). The web view is blank
    /// until it loads again: report it, then reload the face that was on screen (or the load that was in progress)
    /// at the position held as a CFI.
    func webContentProcessDidTerminate() {
        logger.error("WebContent process terminated (spine \(self.currentSpineIndex))")
        emit(.error(.webContentTerminated))
        let now = ContinuousClock.now
        recentTerminations = recentTerminations.filter { now - $0 < .seconds(30) } + [now]
        let retry = loadInProgress
        // Unblock a load that waits for `ready` from the dead document; its error is not reported twice.
        failPendingLoad(.webContentTerminated)
        guard recentTerminations.count <= Self.maximumAutomaticReloads else {
            logger.error("WebContent keeps terminating; not reloading again")
            // The web view is blank: the next navigation must load its chapter instead of scripting the dead page.
            // Reloads queued by the earlier crashes are dropped too (they check the generation). A load that was
            // waiting for `ready` now returns early on the generation check, so its state is reset here.
            loadGeneration += 1
            loadInProgress = nil
            isLoading = false
            if hasLoaded {
                hasLoaded = false
                loadedAsWrapper = false
                renderer.setContentHidden(true)
            }
            return
        }
        let spineIndex: Int
        let target: LoadTarget
        if let retry {
            (spineIndex, target) = retry
            // The crash can come after the load's `ready` (it was already in flight when the process died): the load
            // is then in a script call to the dead document, which fails with WKError 5 ("unsupported type") rather
            // than with `webContentTerminated`. A new generation stops that load at its next check so the failure is
            // not reported as `loadFailed`; the reload below takes over.
            loadGeneration += 1
        } else if hasLoaded {
            spineIndex = position.flatMap { isShowing(spineIndex: $0.spineIndex) ? $0.spineIndex : nil } ?? currentSpineIndex
            target = position.map { .cfi($0.cfi) } ?? .page(currentPageIndex)
        } else {
            return
        }
        isZoomed = false
        // A navigation that starts a load before this reload runs (one queued behind the crashed load) replaces the
        // dead page anyway; reloading the old target afterwards would undo it.
        let generation = loadGeneration
        enqueue { [weak self] in
            guard let self, self.loadGeneration == generation else { return }
            await self.loadChapter(spineIndex, target: target)
        }
    }

    /// Automatic reloads allowed within 30 seconds after WebContent crashes.
    static let maximumAutomaticReloads = 3

    // MARK: - Settings and resize

    private func settingsDidChange(from oldValue: ReaderSettings) {
        if case .custom(let resource) = settings.font {
            PublicationRegistry.shared.registerFont(resource, for: container.id)
        }
        renderer.setBackgroundColor(settings.theme.background)
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
        // The theme is not part of the layout key, so `selectLayout` does not reconfigure pre-pagination for it: its
        // background and the neighbour snapshots (drawn in the old colours) are refreshed here.
        if settings.theme != oldValue.theme, settings.layoutKey == oldValue.layoutKey {
            paginationService.updateTheme(settings: settings)
        }
        guard hasLoaded else { return }
        isLoading = true
        enqueue { [weak self] in await self?.relayoutPreservingPosition() }
    }

    private func viewportSizeDidChange() {
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
        guard hasLoaded else { applyPageSize(); return }
        // The web view keeps its old size (and layout) under the snapshot until the relayout runs, so the reader
        // never sees the document reflow at the wrong page size.
        let wasIdle = !isLoading
        isLoading = true
        if wasIdle { captureRelayoutSnapshotIfNeeded() }
        pendingResize?.cancel()
        pendingResize = Task { @MainActor [weak self] in
            if Self.resizeDebounce > .zero { try? await Task.sleep(for: Self.resizeDebounce) }
            guard !Task.isCancelled, let self else { return }
            self.pendingResize = nil
            await self.run { [weak self] in await self?.relayoutPreservingPosition() }
        }
    }

    /// Gives the display web view the current viewport size.
    private func applyPageSize() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        renderer.setPageSize(viewportSize)
        laidOutPageSize = viewportSize
    }

    /// Takes the picture of the visible page that covers the web view while it is re-laid out. Only one is kept per
    /// relayout (a stream of resizes keeps the first).
    private func captureRelayoutSnapshotIfNeeded() {
        guard hasLoaded, relayoutSnapshot == nil, relayoutSnapshotTask == nil else { return }
        let slot = renderer.visibleSlot
        let spineIndex = currentSpineIndex
        let pageIndex = currentPageIndex
        let size = laidOutPageSize
        relayoutSnapshotTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { relayoutSnapshotTask = nil }
            guard let result = try? await renderer.snapshot(slot: slot), relayoutSnapshot == nil, isLoading else { return }
            relayoutSnapshot = PageSnapshot(image: result.image, scale: result.scale, size: size, spineIndex: spineIndex, pageIndex: pageIndex)
        }
    }

    /// Re-applies the CSS variables, then returns to the page that holds the text that was at the top of the
    /// page before: the CFI of the page start is taken before the relayout and resolved after it
    /// (02-rendering §5.3). Falls back to the in-chapter ratio when the page has no text.
    private func relayoutPreservingPosition() async {
        guard hasLoaded else { isLoading = false; return }
        isLoading = true
        captureRelayoutSnapshotIfNeeded()
        await relayoutSnapshotTask?.value
        defer {
            // A resize that arrived meanwhile re-lays out again right away; stay "loading" and keep covering the web
            // view until then (otherwise `isLoading` would flip to false for a moment between the two relayouts).
            if pendingResize == nil {
                isLoading = false
                relayoutSnapshot = nil
            }
        }
        selectLayout()
        do {
            let anchor = (try? await renderer.cfiForPage(currentPageIndex, margins: settings.pageMargins)) ?? position?.cfi
            let ratio = chapterPageCount > 1 ? Double(currentPageIndex) / Double(chapterPageCount - 1) : 0
            // The new viewport or policy may cut the reading order differently (single page ↔ spread, M4). A
            // horizontal chapter switches between one and two columns in place; anything else (a fixed-layout face,
            // the vertical wrapper) is reloaded at the same position.
            var columns = 1
            if let unit = currentUnit, let replacement = spreadPlan.unit(containing: currentSpineIndex) {
                let inPlace: Bool
                switch (unit, replacement) {
                case (.reflowable(let a, _), .reflowable(let b, let twoPages)) where a == b && !loadedAsWrapper && !Self.spreadNeedsWrapper(writingMode: writingMode, publication: publication):
                    inPlace = true
                    columns = twoPages ? 2 : 1
                default:
                    inPlace = replacement == unit
                    if case .reflowable(_, let twoPages) = unit, !loadedAsWrapper { columns = twoPages ? 2 : 1 }
                }
                if !inPlace {
                    // The anchor may sit on the second page of the spread (the first one blank): keep that page.
                    let anchorIndex = anchor.flatMap { publication.spineIndex(of: $0) }.flatMap { isShowing(spineIndex: $0) ? $0 : nil } ?? currentSpineIndex
                    await loadChapter(anchorIndex, target: anchor.map { .cfi($0) } ?? .page(currentPageIndex))
                    return
                }
                currentUnit = replacement
            }
            applyPageSize()
            var parameters = LayoutParameters(pageSize: viewportSize, settings: settings, rootStyle: schemeHandler.rootStyle, spineSteps: publication.cfiSpineSteps(forSpineIndex: currentSpineIndex))
            parameters.columnsPerPage = columns
            let layout = try await renderer.applySettings(parameters)
            chapterPageCount = layout.pageCount
            var targetPage = min(currentPageIndex, layout.pageCount - 1)
            if let anchor, let page = try await renderer.pageFor(anchor) {
                targetPage = page
            } else if layout.pageCount > 1 {
                targetPage = Int((ratio * Double(layout.pageCount - 1)).rounded())
            }
            let result = try await renderer.goToPage(targetPage)
            currentPageIndex = result.pageIndex
            chapterPageCount = result.pageCount
            recordChapterMeasurement(unit: currentUnit, pageCount: result.pageCount)
            await refreshPosition()
        } catch {
            emit(.error(.scriptFailed(error.localizedDescription)))
        }
    }

    // MARK: - Selection

    /// Clears the document's text selection (`currentSelection` becomes nil at once).
    public func clearSelection() {
        if currentSelection != nil {
            currentSelection = nil
            emit(.selectionChanged(nil))
        }
        Task { @MainActor [weak self] in
            do { try await self?.renderer.clearSelection() } catch { self?.logger.debug("clearSelection failed: \(error.localizedDescription)") }
        }
    }

    /// Rectangles of a CFI range in the visible page's coordinate space: empty when the range is in another
    /// chapter or does not resolve. Rects on other pages of the chapter are outside the visible page's bounds.
    public func rects(for range: CFIRange) async -> [CGRect] {
        guard hasLoaded, let spineIndex = publication.spineIndex(of: range.start), isShowing(spineIndex: spineIndex) else { return [] }
        do {
            return pageRects(fromViewport: try await renderer.rects(for: range))
        } catch {
            logger.debug("rects failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Highlights

    /// Draws the highlights of the documents on `unit` (default: the visible face), replacing the previous set.
    private func applyHighlights(for unit: SpreadPlan.Unit? = nil) async {
        if unit == nil { guard hasLoaded else { return } }
        let indices = Set(unit?.spineIndices ?? currentUnit?.spineIndices ?? [currentSpineIndex])
        let visible = highlights.filter { publication.spineIndex(of: $0.range.start).map(indices.contains) ?? false }
        do {
            _ = try await renderer.setHighlights(visible)
        } catch {
            logger.debug("setHighlights failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Search

    /// Full-text search over the linear reading order (docs/design/01-core.md §6). Results arrive chapter by
    /// chapter in reading order; the stream ends when every chapter has been searched.
    public func search(_ query: String, options: SearchOptions = .default) -> AsyncThrowingStream<SearchResult, any Error> {
        sharedSearchService().search(query, options: options)
    }

    private func sharedSearchService() -> SearchService {
        if let searchService { return searchService }
        let service = SearchService(container: container)
        searchService = service
        return service
    }

    /// Moves to the page that holds `result` and marks the match with a temporary highlight that the next page
    /// move or chapter load removes.
    ///
    /// The move and the highlight are one operation, so no other navigation can replace the document in between
    /// (the range would then be resolved against another chapter).
    public func show(_ result: SearchResult) async {
        guard let spineIndex = publication.spineIndex(of: result.range.start) else { return }
        await run { [self] in
            keepTransientHighlight = true
            await goToCFI(result.range.start, spineIndex: spineIndex)
            keepTransientHighlight = false
            guard hasLoaded, isShowing(spineIndex: spineIndex) else { return }
            do {
                try await renderer.setTransientHighlight(result.range)
                transientHighlight = result.range
            } catch {
                logger.debug("setTransientHighlight failed: \(error.localizedDescription)")
            }
        }
    }

    private func clearTransientHighlightIfNeeded() async {
        guard transientHighlight != nil, !keepTransientHighlight else { return }
        transientHighlight = nil
        try? await renderer.setTransientHighlight(nil)
    }

    // MARK: - Position

    /// Reads the CFI of the visible page's first text and publishes it as `position` / `positionChanged`.
    private func refreshPosition() async {
        guard hasLoaded else { return }
        let spineIndex = currentSpineIndex
        let pageIndex = currentPageIndex
        let cfi: CFI?
        do {
            cfi = try await renderer.cfiForPage(pageIndex, margins: settings.pageMargins)
        } catch {
            logger.debug("cfiForPage failed: \(error.localizedDescription)")
            cfi = nil
        }
        // The page may have moved on while the script ran; only publish a position for the page still shown.
        guard spineIndex == currentSpineIndex, pageIndex == currentPageIndex else { return }
        // A page with nothing addressable (an empty page) keeps the chapter's last position, or falls back to the
        // chapter's body element so `position` is never nil once a chapter has loaded.
        let fallback = position.flatMap { isShowing(spineIndex: $0.spineIndex) ? $0.cfi : nil }
        let cfiToPublish = cfi ?? fallback ?? CFI(spineSteps: publication.cfiSpineSteps(forSpineIndex: spineIndex), steps: [CFI.Step(index: 4)])
        // On a fixed-layout spread the first text may be on the second page (M4); the position names that document.
        let positionSpineIndex = publication.spineIndex(of: cfiToPublish).flatMap { isShowing(spineIndex: $0) ? $0 : nil } ?? spineIndex
        let updated = ReadingPosition(
            cfi: cfiToPublish,
            spineIndex: positionSpineIndex,
            chapterTitle: chapterTitle(forSpineIndex: positionSpineIndex),
            progressionInChapter: chapterProgression,
            totalProgression: totalProgression
        )
        position = updated
        emit(.positionChanged(updated))
    }

    /// Label of the last table-of-contents entry (document order) that points at the spine item.
    private func chapterTitle(forSpineIndex index: Int) -> String? {
        func search(_ entries: [TOCEntry]) -> String? {
            var found: String?
            for entry in entries {
                if entry.spineIndex == index { found = entry.label }
                if let nested = search(entry.children) { found = nested }
            }
            return found
        }
        return search(publication.toc)
    }

    /// Viewport (three-slot frame) point → visible page coordinates: the slot offset is along the paging axis.
    func pagePoint(x: Double, y: Double) -> CGPoint {
        let pageX = writingMode.isVertical ? x : x - Double(renderer.visibleSlot) * viewportSize.width
        let pageY = writingMode.isVertical ? y - Double(renderer.visibleSlot) * viewportSize.height : y
        return CGPoint(x: pageX, y: pageY)
    }

    /// Viewport (three-slot frame) rectangles → visible page coordinates.
    func pageRects(fromViewport rects: [CGRect]) -> [CGRect] {
        let dx = writingMode.isVertical ? 0 : CGFloat(renderer.visibleSlot) * viewportSize.width
        let dy = writingMode.isVertical ? CGFloat(renderer.visibleSlot) * viewportSize.height : 0
        return rects.map { $0.offsetBy(dx: -dx, dy: -dy) }
    }

    // MARK: - Pagination

    /// Key of the layout the display web view is (about to be) using. Selecting a new key bumps the cache generation
    /// and restarts pre-pagination for it; selecting a key seen before restores its measured counts at once.
    private func selectLayout() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        spreadPlan = SpreadBuilder.plan(for: publication, policy: settings.spreadPolicy, viewportSize: viewportSize)
        let key = LayoutKey(pageSize: viewportSize, settings: settings, isSpread: spreadPlan.hasTwoPageReflow)
        if paginationCache.select(key) {
            paginationService.configure(pageSize: viewportSize, settings: settings, plan: spreadPlan, generation: paginationCache.generation, currentSpineIndex: hasLoaded ? currentSpineIndex : nil)
            rebuildPagination()
        }
    }

    /// The display web view's own measurement of a face counts as a measured value for the current layout. Each
    /// page of a fixed-layout face is one book page (M4).
    private func recordChapterMeasurement(unit: SpreadPlan.Unit?, pageCount: Int) {
        let unit = unit ?? .reflowable(spineIndex: currentSpineIndex, twoPages: false)
        var changed = false
        for index in unit.spineIndices {
            let count = unit.isFixedLayout ? 1 : pageCount
            if paginationCache.store(spineIndex: index, pageCount: count, generation: paginationCache.generation) { changed = true }
        }
        if changed { rebuildPagination() }
    }

    private func rebuildPagination() {
        // A two-page face holds twice the text of a single page (M4).
        let perPage = BookPagination.defaultCharactersPerPage(writingMode: writingMode) * (spreadPlan.hasTwoPageReflow ? 2 : 1)
        let updated = BookPagination.make(
            publication: publication,
            measured: paginationCache.measured,
            defaultCharactersPerPage: perPage
        )
        guard updated != pagination else { return }
        pagination = updated
        emit(.paginationUpdated(updated))
    }

    /// iOS memory warning (02-rendering §8.4): stop pre-pagination for now (its neighbour snapshots go too), keep only
    /// the current layout's counts and drop the search index (rebuilt by the next search). Pre-pagination resumes
    /// with the next chapter change, settings change or resize.
    func didReceiveMemoryWarning() {
        paginationService.pause()
        paginationCache.dropOtherLayouts()
        searchService = nil
    }

    // MARK: - Bridge messages

    private func handle(_ message: BridgeMessage) {
        switch message {
        case .ready(let writingMode, let href):
            // A document that was replaced by a newer load can still send its `ready`; only the pending load counts.
            guard let pendingLoadURL, BridgeMessage.readyMatches(href: href, url: pendingLoadURL) else { return }
            readyContinuation?.resume(returning: writingMode)
            readyContinuation = nil
        case .pageCountChanged(let count):
            guard hasLoaded, !isLoading, count != chapterPageCount else { return }
            chapterPageCount = max(1, count)
            recordChapterMeasurement(unit: currentUnit, pageCount: chapterPageCount)
            if currentPageIndex >= chapterPageCount {
                enqueue { [weak self] in await self?.goToPageInChapter((self?.chapterPageCount ?? 1) - 1) }
            } else {
                // The text at the page start is unchanged but the progressions moved.
                enqueue { [weak self] in await self?.refreshPosition() }
            }
        case .link(let href, _):
            handleLink(href: href)
        case .noteref(let note):
            handleNoteref(note)
        case .imageTap(let src, let alt, let rect, let x, let y):
            handleImageTap(src: src, alt: alt, rect: rect, x: x, y: y)
        case .tap(let x, let y):
            let point = pagePoint(x: x, y: y)
            let zone: TapZone = viewportSize.width > 0
                ? (point.x < viewportSize.width * 0.25 ? .leading : (point.x >= viewportSize.width * 0.75 ? .trailing : .center))
                : .center
            emit(.tapped(point, zone: zone))
        case .highlightTap(let id, let rects):
            if let uuid = UUID(uuidString: id) {
                emit(.highlightTapped(uuid, rects: pageRects(fromViewport: rects)))
            }
        case .selectionChanged(let selection):
            let selected = selection.map { SelectedText(range: $0.range, text: $0.text, rects: pageRects(fromViewport: $0.rects)) }
            guard selected != currentSelection else { return }
            currentSelection = selected
            emit(.selectionChanged(selected))
        }
    }

    // MARK: - Links, notes, images (M5)

    /// A tap on a link: external URLs go to the app, links inside the publication are followed here and reported as
    /// `internalLink` once the target is on screen (02-rendering §4.2).
    private func handleLink(href: String) {
        switch LinkDestination.resolve(href, publicationID: container.id, publication: publication, contains: container.contains(path:)) {
        case .external(let url):
            emit(.externalLink(url))
        case .spineItem(let index, let path, let fragment):
            enqueue { [weak self] in await self?.followInternalLink(spineIndex: index, path: path, fragment: fragment) }
        case .resource(let path, _):
            logger.debug("link to a non-spine resource ignored: \(path)")
        case .missing(let path):
            emit(.warning(.missingResource(path: path, referencedFrom: publication.readingOrder[currentSpineIndex].path)))
        case .ignored:
            logger.debug("link ignored: \(href)")
        }
    }

    /// Moves to a spine item (and the element its fragment names), then emits `internalLink`.
    private func followInternalLink(spineIndex: Int, path: String, fragment: String?) async {
        if isShowing(spineIndex: spineIndex), hasLoaded {
            // The same document (or the other page of the visible fixed-layout spread): only the page may change. A link
            // without a fragment goes to the document's start, like a link into another document.
            if let fragment {
                if let page = try? await renderer.pageForFragment(fragment) { await goToPageInChapter(page) }
            } else {
                await goToPageInChapter(0)
            }
        } else {
            await loadChapter(spineIndex, target: fragment.map { .fragment($0) } ?? .first)
        }
        guard hasLoaded, isShowing(spineIndex: spineIndex) else { return }
        let cfi = await FragmentLookup.cfi(path: path, fragment: fragment, spineIndex: spineIndex, in: container)
            ?? (fragment == nil ? nil : position.flatMap { publication.spineIndex(of: $0.cfi) == spineIndex ? $0.cfi : nil })
            ?? CFI(spineSteps: publication.cfiSpineSteps(forSpineIndex: spineIndex), steps: [CFI.Step(index: 4)])
        emit(.internalLink(cfi))
    }

    private func handleNoteref(_ note: BridgeNoteref) {
        let rect = pageRects(fromViewport: [note.rect]).first ?? .zero
        let destination = LinkDestination.resolve(note.href, publicationID: container.id, publication: publication, contains: container.contains(path:))
        let path: String
        let fragment: String?
        let spineIndex: Int?
        switch destination {
        case .spineItem(let index, let p, let f):
            path = p; fragment = f; spineIndex = index
        case .resource(let p, let f):
            path = p; fragment = f; spineIndex = nil
        case .external, .missing, .ignored:
            // A noteref that leaves the publication is an ordinary link.
            handleLink(href: note.href)
            return
        }
        if note.isSameDocument {
            emit(.noteref(NoteContent(path: path, fragment: fragment, spineIndex: spineIndex, cfi: note.cfi, html: note.html, text: note.text, isInSameDocument: true, sourceRect: rect)))
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found = if let fragment { await FragmentLookup.note(path: path, fragment: fragment, spineIndex: spineIndex, in: self.container) } else { nil as (cfi: CFI?, text: String)? }
            self.emit(.noteref(NoteContent(path: path, fragment: fragment, spineIndex: spineIndex, cfi: found?.cfi, html: nil, text: found?.text, isInSameDocument: false, sourceRect: rect)))
        }
    }

    private func handleImageTap(src: String, alt: String?, rect: CGRect, x: Double, y: Double) {
        guard let url = URL(string: src) else { return }
        let path: String?
        switch LinkDestination.resolve(src, publicationID: container.id, publication: publication, contains: container.contains(path:)) {
        case .resource(let p, _), .missing(let p): path = p
        case .spineItem(_, let p, _): path = p
        case .external, .ignored: path = nil
        }
        let container = self.container
        let data: @Sendable () async throws -> Data = {
            if let path { return try await container.data(at: path) }
            if url.scheme?.lowercased() == "data" { return try Data(contentsOf: url) }
            throw ReaderError.loadFailed(spineIndex: -1, underlying: "not a publication resource: \(src)")
        }
        let image = TappedImage(
            url: url,
            path: path,
            alt: alt.flatMap { $0.isEmpty ? nil : $0 },
            rect: pageRects(fromViewport: [rect]).first ?? .zero,
            point: pagePoint(x: x, y: y),
            data: data
        )
        emit(.imageTapped(image))
    }

    // MARK: - Helpers

    /// The first spine index of the face that holds `index` in the current plan.
    private func leadingSpineIndex(ofFaceContaining index: Int) -> Int {
        spreadPlan.unit(containing: index)?.leadingSpineIndex ?? index
    }

    /// Whether `spineIndex` is one of the documents on the visible face.
    private func isShowing(spineIndex: Int) -> Bool {
        currentUnit?.contains(spineIndex: spineIndex) ?? (spineIndex == currentSpineIndex)
    }

    /// The visible face is a spread wrapper document (fixed layout or vertical two-page), not the chapter itself (M4).
    private var isShowingWrapper: Bool { loadedAsWrapper }

    /// First linear spine item after the face that holds `index` (M4: the partner page of a spread is skipped).
    private func nextLinearSpineIndex(after index: Int) -> Int? {
        let last = spreadPlan.unit(containing: index)?.spineIndices.max() ?? index
        return publication.readingOrder.dropFirst(last + 1).first(where: \.isLinear)?.index
    }

    private func previousLinearSpineIndex(before index: Int) -> Int? {
        let first = spreadPlan.unit(containing: index)?.spineIndices.min() ?? index
        return publication.readingOrder.prefix(first).last(where: \.isLinear)?.index
    }

    private func emit(_ event: ReaderEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Serializes navigation and relayout so that two operations never drive the web view at the same time.
    private func run(_ operation: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue {
                await operation()
                continuation.resume()
            }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        operationQueue.append(operation)
        drainQueue()
    }

    private func drainQueue() {
        guard !isRunningOperation, !operationQueue.isEmpty else { return }
        isRunningOperation = true
        let next = operationQueue.removeFirst()
        Task { @MainActor [weak self] in
            await next()
            self?.isRunningOperation = false
            self?.drainQueue()
        }
    }
}
