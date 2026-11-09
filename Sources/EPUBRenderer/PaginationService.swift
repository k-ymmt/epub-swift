import Foundation
import os
import EPUBCore

/// Pre-pagination with a hidden web view (docs/design/02-rendering.md §8).
///
/// Loads the linear spine items one by one into a second `WebViewSpineRenderer` configured like the display one
/// (same scheme handler, page size and settings), measures each chapter's page count into the `PaginationCache`,
/// and keeps snapshots of the first page of the next chapter and the last page of the previous chapter for the
/// page-turn effect across chapter boundaries (§8.3). Order: next → previous → from the start; the current chapter
/// is measured by the display web view. One chapter per `await`, so display navigation gets in between.
@MainActor
final class PaginationService {
    /// Snapshots of a chapter's first and last page, for the chapters adjacent to the current one.
    struct ChapterSnapshots {
        var first: PageSnapshot?
        var last: PageSnapshot?
    }

    let renderer: WebViewSpineRenderer
    private let publication: Publication
    private let container: EPUBContainer
    private let cache: PaginationCache
    private let logger = Logger(subsystem: "EPUB", category: "PaginationService")

    private var pageSize: CGSize = .zero
    private var settings = ReaderSettings()
    /// The faces of the current layout (M4): a fixed-layout spread is measured as one wrapper document; its pages
    /// are one book page each. Spine indices in the queue and the snapshots are the faces' leading indices.
    private var plan = SpreadPlan(units: [])
    private var generation = -1
    private var currentSpineIndex: Int?
    private var queue: [Int] = []
    private var failed: Set<Int> = []
    private var worker: Task<Void, Never>?
    /// Identifies the current worker. `withTimeout` runs the chapter in an unstructured task that cancelling the
    /// worker does not reach, so every step re-checks this token and stops when a newer worker has taken over.
    private var workerToken = 0
    private var readyContinuation: CheckedContinuation<WritingMode, any Error>?
    private var pendingLoadURL: URL?
    private(set) var isPaused = false
    /// Snapshots per spine index for the current generation; only the neighbours of the current chapter are kept.
    private(set) var snapshots: [Int: ChapterSnapshots] = [:]

    /// Called after each chapter is measured (spine index, page count).
    var onChapterMeasured: (@MainActor (Int, Int) -> Void)?
    /// Called when the neighbour snapshots change.
    var onSnapshotsChanged: (@MainActor () -> Void)?
    /// Called when a chapter could not be laid out (spine index, error). It is not retried for this layout.
    var onChapterFailed: (@MainActor (Int, any Error) -> Void)?
    /// Spine indices that failed for the current layout (tests, diagnostics).
    var failedSpineIndices: Set<Int> { failed }
    /// `true` while a chapter is being laid out or more chapters are queued (tests).
    var isWorking: Bool { worker != nil && !(worker?.isCancelled ?? true) }

    static let loadTimeout: Duration = .seconds(10)

    init(container: EPUBContainer, schemeHandler: EPUBSchemeHandler, cache: PaginationCache) {
        self.container = container
        self.publication = container.publication
        self.cache = cache
        renderer = WebViewSpineRenderer(schemeHandler: schemeHandler)
        renderer.onMessage = { [weak self] message in
            guard let self, case .ready(let mode, let href) = message else { return }
            guard let pending = self.pendingLoadURL, BridgeMessage.readyMatches(href: href, url: pending) else { return }
            self.readyContinuation?.resume(returning: mode)
            self.readyContinuation = nil
        }
        renderer.onNavigationFailed = { [weak self] error in
            self?.readyContinuation?.resume(throwing: error)
            self?.readyContinuation = nil
        }
        renderer.onProcessTerminated = { [weak self] in
            self?.readyContinuation?.resume(throwing: ReaderError.webContentTerminated)
            self?.readyContinuation = nil
        }
    }

    // MARK: - Control

    /// (Re)starts for a layout. Results of loads that started under an earlier generation are dropped by the cache;
    /// the running load is cancelled here. Snapshots belong to one layout, so they are cleared.
    func configure(pageSize: CGSize, settings: ReaderSettings, plan: SpreadPlan, generation: Int, currentSpineIndex: Int?) {
        self.pageSize = pageSize
        self.settings = settings
        self.plan = plan
        self.generation = generation
        self.currentSpineIndex = currentSpineIndex
        renderer.setPageSize(pageSize)
        renderer.setBackgroundColor(settings.theme.background)
        failed = []
        clearSnapshots()
        restart()
    }

    /// Reorders the queue around the chapter now on screen and makes sure its neighbours get snapshots. The chapter
    /// being laid out right now is left to finish: cancelling it and reloading the same chapter would let the first
    /// document's `ready` answer the second load.
    func setCurrentSpineIndex(_ index: Int) {
        guard index != currentSpineIndex else { return }
        currentSpineIndex = index
        // Keep only the new neighbours' snapshots.
        let keep = Set(neighbours(of: index))
        let before = snapshots.keys.count
        snapshots = snapshots.filter { keep.contains($0.key) }
        if snapshots.count != before { onSnapshotsChanged?() }
        if isPaused { isPaused = false }
        queue = buildQueue()
        startWorkerIfNeeded()
    }

    /// Stops after the current chapter and drops the snapshots (memory warning, 02-rendering §8.4). Work resumes with
    /// the next `setCurrentSpineIndex` / `configure` / `resume`.
    func pause() {
        isPaused = true
        worker?.cancel()
        worker = nil
        clearSnapshots()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        restart()
    }

    func cancel() {
        worker?.cancel()
        worker = nil
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
    }

    // MARK: - Snapshots for the UI

    func snapshot(firstPageOf spineIndex: Int) -> PageSnapshot? { snapshots[spineIndex]?.first }
    func snapshot(lastPageOf spineIndex: Int) -> PageSnapshot? { snapshots[spineIndex]?.last }

    private func clearSnapshots() {
        guard !snapshots.isEmpty else { return }
        snapshots = [:]
        onSnapshotsChanged?()
    }

    // MARK: - Queue

    private func unit(containing index: Int) -> SpreadPlan.Unit {
        plan.unit(containing: index) ?? .reflowable(spineIndex: index, twoPages: false)
    }

    /// Leading spine indices of the faces after and before the face that holds `index`.
    private func neighbours(of index: Int) -> [Int] {
        let order = publication.readingOrder
        let unit = unit(containing: index)
        var out: [Int] = []
        if let last = unit.spineIndices.max(), let next = order.dropFirst(last + 1).first(where: \.isLinear)?.index { out.append(next) }
        if let first = unit.spineIndices.min(), let previous = order.prefix(first).last(where: \.isLinear)?.index { out.append(previous) }
        return out
    }

    private func buildQueue() -> [Int] {
        var out: [Int] = []
        if let current = currentSpineIndex { out = neighbours(of: current) }
        for unit in plan.units where publication.readingOrder[unit.leadingSpineIndex].isLinear && !out.contains(unit.leadingSpineIndex) {
            out.append(unit.leadingSpineIndex)
        }
        if plan.units.isEmpty {
            for item in publication.linearReadingOrder where !out.contains(item.index) { out.append(item.index) }
        }
        return out
    }

    private func needsWork(_ index: Int) -> Bool {
        guard !failed.contains(index) else { return false }
        if unit(containing: index).spineIndices.contains(where: { cache.pageCount(ofSpineIndex: $0) == nil }) { return true }
        if let current = currentSpineIndex, neighbours(of: current).contains(index), snapshots[index] == nil { return true }
        return false
    }

    /// Cancels in-flight work and starts over with a fresh queue (layout change, resume).
    private func restart() {
        cancel()
        queue = buildQueue()
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, pageSize.width > 0, pageSize.height > 0, generation >= 0, !isPaused else { return }
        workerToken += 1
        let token = workerToken
        worker = Task { @MainActor [weak self] in
            await self?.drain(token: token)
        }
    }

    private func drain(token: Int) async {
        let generation = self.generation
        while !Task.isCancelled, token == workerToken, generation == self.generation, !queue.isEmpty {
            let index = queue.removeFirst()
            guard needsWork(index) else { continue }
            await measure(spineIndex: index, generation: generation, token: token)
            // One chapter per await: let display navigation and UI work run before the next load.
            await Task.yield()
        }
        if token == workerToken, !Task.isCancelled { worker = nil }
    }

    // MARK: - Measuring one chapter

    private func measure(spineIndex: Int, generation: Int, token: Int) async {
        guard publication.readingOrder.indices.contains(spineIndex) else { return }
        do {
            // The whole chapter (load, layout, snapshots) is bounded: a bridge call on a document that is being
            // replaced must not stall the queue.
            try await withTimeout(Self.loadTimeout * 2) { [self] in
                try await layOut(spineIndex: spineIndex, generation: generation, token: token)
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation, token == workerToken else { return }
            logger.debug("pre-pagination of spine \(spineIndex) failed: \(error.localizedDescription)")
            failed.insert(spineIndex)
            onChapterFailed?(spineIndex, error)
        }
    }

    private func layOut(spineIndex: Int, generation: Int, token: Int) async throws {
        func stillCurrent() -> Bool { token == workerToken && generation == self.generation && !Task.isCancelled }
        guard stillCurrent() else { throw CancellationError() }
        let unit = unit(containing: spineIndex)
        let leading = unit.leadingSpineIndex
        let url = SpreadDocument.url(publicationID: container.id, unit: unit)
            ?? EPUBSchemeHandler.url(publicationID: container.id, path: publication.readingOrder[leading].path)
        let mode = try await withReady { renderer.load(url) }
        guard stillCurrent() else { throw CancellationError() }
        renderer.setWritingMode(mode)
        _ = try await renderer.layout(LayoutParameters(pageSize: pageSize, settings: settings, spineSteps: publication.cfiSpineSteps(forSpineIndex: leading)))
        guard stillCurrent() else { throw CancellationError() }
        // goToPage re-measures and positions page 0 (slot 0), whose snapshot the UI wants for a forward turn.
        let first = try await renderer.goToPage(0)
        var pageCount = first.pageCount
        let wantsSnapshots = currentSpineIndex.map { neighbours(of: $0).contains(spineIndex) } ?? false
        var chapterSnapshots = ChapterSnapshots()
        if wantsSnapshots {
            chapterSnapshots.first = try await pageSnapshot(slot: first.slot, spineIndex: leading, pageIndex: 0)
            guard stillCurrent() else { throw CancellationError() }
            let last = try await renderer.goToPage(pageCount - 1)
            pageCount = last.pageCount
            chapterSnapshots.last = try await pageSnapshot(slot: last.slot, spineIndex: leading, pageIndex: last.pageIndex)
        }
        guard stillCurrent() else { throw CancellationError() }
        for index in unit.spineIndices {
            cache.store(spineIndex: index, pageCount: unit.isFixedLayout ? 1 : pageCount, generation: generation)
        }
        if wantsSnapshots {
            snapshots[leading] = chapterSnapshots
            onSnapshotsChanged?()
        }
        onChapterMeasured?(leading, pageCount)
    }

    /// Runs `operation` and throws `ReaderError.loadTimeout` if it has not finished after `duration`. The operation
    /// is then abandoned (a bridge call that never answers would otherwise stall the queue forever).
    private func withTimeout(_ duration: Duration, _ operation: @escaping @MainActor () async throws -> Void) async throws {
        let gate = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            gate.continuation = continuation
            let work = Task { @MainActor in
                do {
                    try await operation()
                    gate.resume(.success(()))
                } catch {
                    gate.resume(.failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: duration)
                guard gate.continuation != nil else { return }
                work.cancel()
                gate.resume(.failure(ReaderError.loadTimeout(spineIndex: -1)))
            }
        }
    }

    private func pageSnapshot(slot: Int, spineIndex: Int, pageIndex: Int) async throws -> PageSnapshot? {
        guard let result = try await renderer.snapshot(slot: slot) else { return nil }
        return PageSnapshot(image: result.image, scale: result.scale, size: pageSize, spineIndex: spineIndex, pageIndex: pageIndex)
    }

    @MainActor
    private final class ResumeOnce {
        var continuation: CheckedContinuation<Void, any Error>?
        func resume(_ result: Result<Void, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    private func withReady(_ start: () -> URL) async throws -> WritingMode {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loadTimeout)
            guard !Task.isCancelled, let self else { return }
            self.readyContinuation?.resume(throwing: ReaderError.loadTimeout(spineIndex: -1))
            self.readyContinuation = nil
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WritingMode, any Error>) in
            self.readyContinuation = continuation
            self.pendingLoadURL = start()
        }
    }
}
