import Foundation
import EPUBCore

/// How the reading order is cut into "faces" (what the reader shows at one time) for a given viewport and spread
/// policy (docs/design/02-rendering.md §6.2, M4). Pure Swift, no WebKit.
public struct SpreadPlan: Sendable, Hashable {
    /// Where a fixed-layout page sits inside the visible area.
    public enum Placement: Sendable, Hashable {
        /// The left half of a two-page face.
        case left
        /// The right half of a two-page face.
        case right
        /// The whole face (single page, or `rendition:page-spread-center`).
        case full
    }

    public struct FixedPage: Sendable, Hashable {
        public var spineIndex: Int
        public var placement: Placement

        public init(spineIndex: Int, placement: Placement) {
            self.spineIndex = spineIndex
            self.placement = placement
        }
    }

    public enum Unit: Sendable, Hashable {
        /// One reflowable spine item. `twoPages` means its pages are shown as two facing pages (two columns per face in
        /// horizontal writing, two stacked scroll positions in vertical writing).
        case reflowable(spineIndex: Int, twoPages: Bool)
        /// One or two fixed-layout pages, in reading order. Two pages always have placements `left` and `right`.
        case fixed(pages: [FixedPage])

        /// Spine indices in reading order.
        public var spineIndices: [Int] {
            switch self {
            case .reflowable(let index, _): [index]
            case .fixed(let pages): pages.map(\.spineIndex)
            }
        }

        /// The spine index the face is identified by (its first page in reading order).
        public var leadingSpineIndex: Int { spineIndices[0] }

        public var isFixedLayout: Bool {
            if case .fixed = self { return true } else { return false }
        }

        /// Whether the face is laid out as two facing pages (even when only one of them is filled).
        public var isTwoPageLayout: Bool {
            switch self {
            case .reflowable(_, let twoPages): twoPages
            case .fixed(let pages): pages.contains { $0.placement != .full }
            }
        }

        public func contains(spineIndex: Int) -> Bool { spineIndices.contains(spineIndex) }
    }

    public var units: [Unit]

    public init(units: [Unit]) {
        self.units = units
    }

    public func unitIndex(containing spineIndex: Int) -> Int? {
        units.firstIndex { $0.contains(spineIndex: spineIndex) }
    }

    public func unit(containing spineIndex: Int) -> Unit? {
        unitIndex(containing: spineIndex).map { units[$0] }
    }
}

/// Builds a `SpreadPlan` from the publication's rendition properties, the reader's spread policy and the viewport.
///
/// - Single page when the policy is `never`, when the effective `rendition:spread` is `none`, or (policy `auto`) when the
///   viewport is portrait and the spread value is `auto` / `landscape`. `both` spreads in any orientation.
/// - Fixed-layout pages take their side from `page-spread-left/right`; without one they alternate from the first
///   linear page, which stands alone on the side the progression direction puts first pages on (right for ltr,
///   left for rtl). Two consecutive linear fixed-layout pages whose sides complete one spread are paired.
///   `page-spread-center` pages stand alone and fill the face.
/// - Non-linear items and reflowable items are faces of their own.
public enum SpreadBuilder {
    public static func plan(for publication: Publication, policy: ReaderSettings.SpreadPolicy, viewportSize: CGSize) -> SpreadPlan {
        let landscape = viewportSize.width > viewportSize.height
        let isRTL = publication.pageProgression == .rtl
        // The side a lone first page sits on, and the side of the first page of a two-page face in reading order.
        let loneSide: SpreadPosition = isRTL ? .left : .right
        let firstSlot: SpreadPosition = isRTL ? .right : .left
        let items = publication.readingOrder

        func wantsTwoPages(_ item: SpineItem) -> Bool {
            let spread = item.spread ?? publication.spread
            if spread == RenditionSpread.none { return false }
            switch policy {
            case .never: return false
            case .always: return true
            case .auto:
                switch spread {
                case .both: return true
                case .auto, .landscape: return landscape
                case .none: return false
                }
            }
        }
        func opposite(_ side: SpreadPosition) -> SpreadPosition { side == .left ? .right : .left }
        func placement(_ side: SpreadPosition) -> SpreadPlan.Placement { side == .left ? .left : .right }

        var units: [SpreadPlan.Unit] = []
        var expectedSide = loneSide
        var i = 0
        while i < items.count {
            let item = items[i]
            defer { i += 1 }
            guard item.isLinear else {
                units.append(item.isFixedLayout
                    ? .fixed(pages: [.init(spineIndex: i, placement: .full)])
                    : .reflowable(spineIndex: i, twoPages: wantsTwoPages(item)))
                continue
            }
            guard item.isFixedLayout else {
                units.append(.reflowable(spineIndex: i, twoPages: wantsTwoPages(item)))
                expectedSide = loneSide
                continue
            }
            let side = item.spreadPosition ?? expectedSide
            guard wantsTwoPages(item), side != .center else {
                units.append(.fixed(pages: [.init(spineIndex: i, placement: .full)]))
                expectedSide = side == .center ? loneSide : opposite(side)
                continue
            }
            if side == firstSlot, i + 1 < items.count {
                let next = items[i + 1]
                if next.isLinear, next.isFixedLayout, wantsTwoPages(next), (next.spreadPosition ?? opposite(side)) == opposite(side) {
                    let pages = side == .left
                        ? [SpreadPlan.FixedPage(spineIndex: i, placement: .left), .init(spineIndex: i + 1, placement: .right)]
                        : [SpreadPlan.FixedPage(spineIndex: i, placement: .right), .init(spineIndex: i + 1, placement: .left)]
                    units.append(.fixed(pages: pages))
                    expectedSide = firstSlot
                    i += 1
                    continue
                }
            }
            units.append(.fixed(pages: [.init(spineIndex: i, placement: placement(side))]))
            expectedSide = opposite(side)
        }
        return SpreadPlan(units: units)
    }
}
