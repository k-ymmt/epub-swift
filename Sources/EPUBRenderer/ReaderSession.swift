import Foundation
import Observation
import os
import EPUBCore

/// The reading state of one publication (docs/design/03-api.md §3.2).
///
/// M1 scope: load a spine item into the web view, page within it, cross chapter boundaries, apply
/// `ReaderSettings` with position restoration, and provide page snapshots for the UI layer's page-turn effects.
/// CFI-based positions, highlights, selection and search arrive with M3.
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

    /// Fraction of the book read, from spine position and page within the chapter (rough until M2 pagination).
    public var totalProgression: Double {
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
    @ObservationIgnored private var readyContinuation: CheckedContinuation<WritingMode, any Error>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var relayoutTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: Task<Void, Never>?
    @ObservationIgnored private var operationQueue: [() async -> Void] = []
    @ObservationIgnored private var isRunningOperation = false
    @ObservationIgnored private let logger = Logger(subsystem: "EPUB", category: "ReaderSession")

    static let loadTimeout: Duration = .seconds(10)

    public init(container: EPUBContainer, settings: ReaderSettings = ReaderSettings()) {
        self.container = container
        self.publication = container.publication
        self.settings = settings
        let handler = EPUBSchemeHandler()
        self.schemeHandler = handler
        self.renderer = WebViewSpineRenderer(schemeHandler: handler)
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
            let page = self.currentPageIndex
            self.enqueue { [weak self] in await self?.loadChapter(self?.currentSpineIndex ?? 0, target: .page(page)) }
        }
        renderer.setBackgroundColor(settings.theme.background)
        renderer.setContentHidden(true)
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: .zero, publicationID: container.id)
        currentSpineIndex = publication.linearReadingOrder.first?.index ?? 0
    }

    deinit {
        let id = container.id
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

    /// Snapshot of the current, next or previous page of the current chapter for the UI's page-turn effect.
    /// Returns nil when the target page is in another chapter (the UI substitutes the background color).
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
            guard currentPageIndex + 1 < chapterPageCount, visibleSlot + 1 < WebViewSpineRenderer.slotCount else { return nil }
            pageIndex = currentPageIndex + 1
            slot = visibleSlot + 1
        case .previous:
            guard currentPageIndex > 0, visibleSlot - 1 >= 0 else { return nil }
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
    }

    func loadChapter(_ spineIndex: Int, target: LoadTarget) async {
        guard publication.readingOrder.indices.contains(spineIndex), viewportSize.width > 0 else { return }
        let item = publication.readingOrder[spineIndex]
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        renderer.setContentHidden(true)
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
        let url = EPUBSchemeHandler.url(publicationID: container.id, path: item.path)
        logger.debug("load spine \(spineIndex) \(item.path)")
        do {
            let mode = try await withReady(generation: generation) { renderer.load(url) }
            // The frame's slot axis must match the document before it is measured (three pages tall for vertical writing).
            renderer.setWritingMode(mode)
            let layout = try await renderer.layout(LayoutParameters(pageSize: viewportSize, settings: settings))
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
            }
            let result = try await renderer.goToPage(targetPage)
            guard generation == loadGeneration else { return }
            currentSpineIndex = spineIndex
            chapterPageCount = result.pageCount
            currentPageIndex = result.pageIndex
            isLoading = false
            hasLoaded = true
            renderer.setContentHidden(false)
            emit(.pageChanged(spineIndex: spineIndex, pageIndex: result.pageIndex, pageCount: result.pageCount))
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
            emit(.pageChanged(spineIndex: currentSpineIndex, pageIndex: result.pageIndex, pageCount: result.pageCount))
            return true
        } catch {
            emit(.error(.scriptFailed(error.localizedDescription)))
            return false
        }
    }

    /// Runs `start` and waits for the `ready` message (or a navigation failure / timeout).
    private func withReady(generation: Int, _ start: () -> Void) async throws -> WritingMode {
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
            start()
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
        renderer.setPageSize(viewportSize)
        schemeHandler.rootStyle = ContentInjector.rootStyle(settings: settings, pageSize: viewportSize, publicationID: container.id)
        guard hasLoaded else { return }
        // Debounce window resizes (03-api §4.5).
        pendingResize?.cancel()
        isLoading = true
        pendingResize = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.run { [weak self] in await self?.relayoutPreservingPosition() }
        }
    }

    /// Re-applies the CSS variables, then returns to the page that holds the text that was at the top of the
    /// page before (02-rendering §5.3; an in-document DOM anchor until CFI arrives with M3).
    private func relayoutPreservingPosition() async {
        guard hasLoaded else { isLoading = false; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let anchored = try await renderer.captureAnchor(slot: renderer.visibleSlot, margins: settings.pageMargins)
            let ratio = chapterPageCount > 1 ? Double(currentPageIndex) / Double(chapterPageCount - 1) : 0
            let layout = try await renderer.applySettings(LayoutParameters(pageSize: viewportSize, settings: settings, rootStyle: schemeHandler.rootStyle))
            chapterPageCount = layout.pageCount
            var targetPage = min(currentPageIndex, layout.pageCount - 1)
            if anchored, let page = try await renderer.pageForAnchor() {
                targetPage = page
            } else if layout.pageCount > 1 {
                targetPage = Int((ratio * Double(layout.pageCount - 1)).rounded())
            }
            let result = try await renderer.goToPage(targetPage)
            currentPageIndex = result.pageIndex
            chapterPageCount = result.pageCount
            emit(.pageChanged(spineIndex: currentSpineIndex, pageIndex: result.pageIndex, pageCount: result.pageCount))
        } catch {
            emit(.error(.scriptFailed(error.localizedDescription)))
        }
    }

    // MARK: - Bridge messages

    private func handle(_ message: BridgeMessage) {
        switch message {
        case .ready(let writingMode):
            readyContinuation?.resume(returning: writingMode)
            readyContinuation = nil
        case .pageCountChanged(let count):
            guard hasLoaded, !isLoading, count != chapterPageCount else { return }
            chapterPageCount = max(1, count)
            if currentPageIndex >= chapterPageCount {
                enqueue { [weak self] in await self?.goToPageInChapter((self?.chapterPageCount ?? 1) - 1) }
            } else {
                emit(.pageChanged(spineIndex: currentSpineIndex, pageIndex: currentPageIndex, pageCount: chapterPageCount))
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
