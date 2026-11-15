import SwiftUI
import EPUB
@_spi(Diagnostics) import EPUBRenderer

/// Compares what the hidden web view measured with what the display lays out (docs/design/08-continuous-scroll.md
/// §6.2, milestone S3): waits until every chapter of the scrolled layout is measured, shows every chapter once, and
/// writes both heights of each chapter and how often the page numbers moved meanwhile. They should not move at all.
///
/// Start it from the Debug menu, or with `READERDEMO_HEIGHTS=1` in the environment (with `READERDEMO_BOOK` and
/// `READERDEMO_LAYOUT=scrolled`). The file is `scroll-heights-ios.json` / `scroll-heights-macos.json`, next to the
/// recordings (`READERDEMO_RECORD_DIR`, or the app's Documents).
@MainActor
enum HeightCheck {
    struct Result {
        var url: URL
        var chapters: Int
        /// Chapters with both heights.
        var compared: Int
        var differing: Int
        var largestDifference: Double
        /// `paginationUpdated` events after the measurement was complete.
        var paginationUpdates: Int
        var totalPages: Int
        var seconds: Double

        var summary: String {
            "Heights: \(compared) of \(chapters) chapters compared, \(differing) differ (largest \(largestDifference.formatted(.number.precision(.fractionLength(0...2)))) px), "
                + "page numbers moved \(paginationUpdates) times, \(totalPages) pages, \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case notScrolled
        case notMeasured(estimated: Int)

        var description: String {
            switch self {
            case .notScrolled: "the book is not in the scrolled layout"
            case .notMeasured(let estimated): "\(estimated) chapters were still estimated after two minutes"
            }
        }
    }

    static func run(_ session: ReaderSession, name: String) async throws -> Result {
        guard session.layout == .scrolled else { throw Failure.notScrolled }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<1200 where session.pagination.isEstimated { try? await Task.sleep(for: .milliseconds(100)) }
        guard !session.pagination.isEstimated else { throw Failure.notMeasured(estimated: session.pagination.estimatedChapterCount) }
        let measuredAfter = clock.now - start
        let before = session.pagination

        var updates = 0
        let stream = session.events
        let collector = Task { @MainActor in
            for await event in stream { if case .paginationUpdated = event { updates += 1 } }
        }
        defer { collector.cancel() }

        let origin = session.position
        let indices = session.publication.linearReadingOrder.map(\.index)
        for index in indices {
            await session.go(toSpineIndex: index)
            // The chapter's height reaches the session with the layout; a little longer for its fonts and images.
            for _ in 0..<60 where session.scrollChapterHeights.first(where: { $0.spineIndex == index })?.displayed == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let origin { await session.go(to: origin.cfi) }
        try? await Task.sleep(for: .milliseconds(500))

        let heights = session.scrollChapterHeights.filter { indices.contains($0.spineIndex) }
        let differences = heights.compactMap { height -> Double? in
            guard let measured = height.measured, let displayed = height.displayed else { return nil }
            return abs(measured - displayed)
        }
        let seconds = Double((clock.now - start).components.seconds) + Double((clock.now - start).components.attoseconds) / 1e18
        #if os(iOS)
        let platform = "ios"
        #else
        let platform = "macos"
        #endif
        let report: [String: Any] = [
            "book": name,
            "platform": platform,
            "viewport": ["width": Double(session.viewportSize.width), "height": Double(session.viewportSize.height)],
            "pageHeight": session.scrollPageHeightForDiagnostics,
            "secondsUntilMeasured": Double(measuredAfter.components.seconds) + Double(measuredAfter.components.attoseconds) / 1e18,
            "paginationUpdatesAfterMeasurement": updates,
            "totalPagesBefore": before.totalPages,
            "totalPagesAfter": session.pagination.totalPages,
            "chapters": heights.map { height -> [String: Any] in
                var row: [String: Any] = ["spineIndex": height.spineIndex]
                if let measured = height.measured { row["measured"] = measured }
                if let displayed = height.displayed { row["displayed"] = displayed }
                return row
            },
        ]
        let url = ScrollRecorder.outputDirectory().appendingPathComponent("scroll-heights-\(platform).json")
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: url)
        let result = Result(
            url: url, chapters: indices.count, compared: differences.count, differing: differences.filter { $0 > 0 }.count,
            largestDifference: differences.max() ?? 0, paginationUpdates: updates, totalPages: session.pagination.totalPages, seconds: seconds
        )
        print("HEIGHTS WRITTEN \(url.path) \(result.summary)")
        return result
    }
}
