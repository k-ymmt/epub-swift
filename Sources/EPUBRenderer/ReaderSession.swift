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
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var relayoutTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: Task<Void, Never>?
    @ObservationIgnored private var relayoutSnapshotTask: Task<Void, Never>?
    /// Page size the display web view is laid out for (lags `viewportSize` until the resize relayout runs).
    @ObservationIgnored private var laidOutPageSize: CGSize = .zero
    @ObservationIgnored private var operationQueue: [() async -> Void] = []
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
        renderer.onProcessTerminated = { [weak self] in
            guard let self else { return }
            self.emit(.error(.webContentTerminated))
            let target: LoadTarget = self.position.map { .cfi($0.cfi) } ?? .page(self.currentPageIndex)
            self.enqueue { [weak self] in await self?.loadChapter(self?.currentSpineIndex ?? 0, target: target) }
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
        await run { [self] in await loadChapter(index, target: .first) }
    }

    /// Jumps to a table-of-contents entry (spine item plus optional fragment).
    public func go(to entry: TOCEntry) async {
        guard let spineIndex = entry.spineIndex ?? entry.href.flatMap({ publication.spineIndex(ofPath: $0) }) else { return }
        await run { [self] in await loadChapter(spineIndex, target: entry.fragment.map { .fragment($0) } ?? .first) }
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
            if location.spineIndex == currentSpineIndex, hasLoaded {
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
        await run { [self] in
            if spineIndex == currentSpineIndex, hasLoaded {
                let page = (try? await renderer.pageFor(cfi)) ?? nil
                await goToPageInChapter(page ?? currentPageIndex)
            } else {
                await loadChapter(spineIndex, target: .cfi(cfi))
            }
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
                return paginationService.snapshot(firstPageOf: next)
            }
            guard visibleSlot + 1 < WebViewSpineRenderer.slotCount else { return nil }
            pageIndex = currentPageIndex + 1
            slot = visibleSlot + 1
        case .previous:
            if currentPageIndex == 0 {
                guard let previous = previousLinearSpineIndex(before: currentSpineIndex) else { return nil }
                return paginationService.snapshot(lastPageOf: previous)
            }
            guard visibleSlot - 1 >= 0 else { return nil }
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
        let item = publication.readingOrder[spineIndex]
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        renderer.setContentHidden(true)
        applyPageSize()
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
        selectLayout()
        let url = EPUBSchemeHandler.url(publicationID: container.id, path: item.path)
        logger.debug("load spine \(spineIndex) \(item.path)")
        do {
            let mode = try await withReady(generation: generation) { renderer.load(url) }
            // The frame's slot axis must match the document before it is measured (three pages tall for vertical writing).
            renderer.setWritingMode(mode)
            let layout = try await renderer.layout(LayoutParameters(pageSize: viewportSize, settings: settings, spineSteps: publication.cfiSpineSteps(forSpineIndex: spineIndex)))
            guard generation == loadGeneration else { return }
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
            currentSpineIndex = spineIndex
            chapterPageCount = result.pageCount
            currentPageIndex = result.pageIndex
            isLoading = false
            hasLoaded = true
            renderer.setContentHidden(false)
            recordChapterMeasurement(spineIndex: spineIndex, pageCount: result.pageCount)
            paginationService.setCurrentSpineIndex(spineIndex)
            await refreshPosition()
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            if hasLoaded { renderer.setContentHidden(false) }
            if let readerError = error as? ReaderError {
                emit(.error(readerError))
            } else {
                emit(.error(.loadFailed(spineIndex: spineIndex, underlying: error.localizedDescription)))
            }
        }
    }

    /// Returns false when the document could not be asked (not loaded, or the script call failed); the page state
    /// is then unchanged and callers must not treat it as "already at the chapter end".
    @discardableResult
    private func goToPageInChapter(_ index: Int, clampToKnownCount: Bool = true) async -> Bool {
        guard hasLoaded else { return false }
        let clamped = clampToKnownCount ? min(max(0, index), chapterPageCount - 1) : max(0, index)
        do {
            let result = try await renderer.goToPage(clamped)
            currentPageIndex = result.pageIndex
            chapterPageCount = result.pageCount
            recordChapterMeasurement(spineIndex: currentSpineIndex, pageCount: result.pageCount)
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

    // MARK: - Settings and resize

    private func settingsDidChange(from oldValue: ReaderSettings) {
        if case .custom(let resource) = settings.font {
            PublicationRegistry.shared.registerFont(resource, for: container.id)
        }
        renderer.setBackgroundColor(settings.theme.background)
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
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
            isLoading = false
            // A resize that arrived meanwhile re-lays out again right away; keep covering the web view until then.
            if pendingResize == nil { relayoutSnapshot = nil }
        }
        selectLayout()
        do {
            let anchor = (try? await renderer.cfiForPage(currentPageIndex, margins: settings.pageMargins)) ?? position?.cfi
            let ratio = chapterPageCount > 1 ? Double(currentPageIndex) / Double(chapterPageCount - 1) : 0
            applyPageSize()
            let layout = try await renderer.applySettings(LayoutParameters(pageSize: viewportSize, settings: settings, rootStyle: schemeHandler.rootStyle, spineSteps: publication.cfiSpineSteps(forSpineIndex: currentSpineIndex)))
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
            recordChapterMeasurement(spineIndex: currentSpineIndex, pageCount: result.pageCount)
            await refreshPosition()
        } catch {
            emit(.error(.scriptFailed(error.localizedDescription)))
        }
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
        let fallback = position?.spineIndex == spineIndex ? position?.cfi : nil
        let cfiToPublish = cfi ?? fallback ?? CFI(spineSteps: publication.cfiSpineSteps(forSpineIndex: spineIndex), steps: [CFI.Step(index: 4)])
        let updated = ReadingPosition(
            cfi: cfiToPublish,
            spineIndex: spineIndex,
            chapterTitle: chapterTitle(forSpineIndex: spineIndex),
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
        let key = LayoutKey(pageSize: viewportSize, settings: settings)
        if paginationCache.select(key) {
            paginationService.configure(pageSize: viewportSize, settings: settings, generation: paginationCache.generation, currentSpineIndex: hasLoaded ? currentSpineIndex : nil)
            rebuildPagination()
        }
    }

    /// The display web view's own measurement of a chapter counts as a measured value for the current layout.
    private func recordChapterMeasurement(spineIndex: Int, pageCount: Int) {
        if paginationCache.store(spineIndex: spineIndex, pageCount: pageCount, generation: paginationCache.generation) {
            rebuildPagination()
        }
    }

    private func rebuildPagination() {
        let updated = BookPagination.make(
            publication: publication,
            measured: paginationCache.measured,
            defaultCharactersPerPage: BookPagination.defaultCharactersPerPage(writingMode: writingMode)
        )
        guard updated != pagination else { return }
        pagination = updated
        emit(.paginationUpdated(updated))
    }

    /// iOS memory warning (02-rendering §8.4): stop pre-pagination for now and keep only the current layout's counts.
    func didReceiveMemoryWarning() {
        paginationService.pause()
        paginationCache.dropOtherLayouts()
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
            recordChapterMeasurement(spineIndex: currentSpineIndex, pageCount: chapterPageCount)
            if currentPageIndex >= chapterPageCount {
                enqueue { [weak self] in await self?.goToPageInChapter((self?.chapterPageCount ?? 1) - 1) }
            } else {
                // The text at the page start is unchanged but the progressions moved.
                enqueue { [weak self] in await self?.refreshPosition() }
            }
        case .link(let href, let isExternal):
            handleLink(href: href, isExternal: isExternal)
        case .tap(let x, let y):
            // Viewport coordinates → visible page coordinates: the slot offset is along the paging axis.
            let pageX = writingMode.isVertical ? x : x - Double(renderer.visibleSlot) * viewportSize.width
            let pageY = writingMode.isVertical ? y - Double(renderer.visibleSlot) * viewportSize.height : y
            let point = CGPoint(x: pageX, y: pageY)
            let zone: TapZone = viewportSize.width > 0
                ? (pageX < viewportSize.width * 0.25 ? .leading : (pageX >= viewportSize.width * 0.75 ? .trailing : .center))
                : .center
            emit(.tapped(point, zone: zone))
        case .highlightTap(let id, let rects):
            if let uuid = UUID(uuidString: id) {
                emit(.highlightTapped(uuid, rects: pageRects(fromViewport: rects)))
            }
        case .selectionChanged(let selection):
            let selected = selection.map { SelectedText(range: $0.range, text: $0.text, rects: pageRects(fromViewport: $0.rects)) }
            emit(.selectionChanged(selected))
        }
    }

    private func handleLink(href: String, isExternal: Bool) {
        guard let url = URL(string: href) else { return }
        if isExternal || url.scheme != EPUBSchemeHandler.scheme {
            emit(.externalLink(url))
            return
        }
        guard url.host == container.id.description else {
            emit(.externalLink(url))
            return
        }
        let path = ContainerPath.normalize(url.path.removingPercentEncoding ?? url.path)
        let fragment = url.fragment
        if let spineIndex = publication.spineIndex(ofPath: path) {
            if spineIndex == currentSpineIndex, let fragment {
                enqueue { [weak self] in
                    guard let self else { return }
                    if let page = try? await self.renderer.pageForFragment(fragment) {
                        await self.goToPageInChapter(page)
                    }
                }
            } else {
                enqueue { [weak self] in await self?.loadChapter(spineIndex, target: fragment.map { .fragment($0) } ?? .first) }
            }
        } else {
            emit(.warning(.missingResource(path: path, referencedFrom: publication.readingOrder[currentSpineIndex].path)))
        }
    }

    // MARK: - Helpers

    private func nextLinearSpineIndex(after index: Int) -> Int? {
        publication.readingOrder.dropFirst(index + 1).first(where: \.isLinear)?.index
    }

    private func previousLinearSpineIndex(before index: Int) -> Int? {
        publication.readingOrder.prefix(index).last(where: \.isLinear)?.index
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
