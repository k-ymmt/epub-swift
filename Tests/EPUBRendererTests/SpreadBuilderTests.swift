import Foundation
import Testing
import EPUBCore
@testable import EPUBRenderer

@Suite struct SpreadBuilderTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let landscape = CGSize(width: 1024, height: 700)
    static let portrait = CGSize(width: 700, height: 1024)

    static func publication(
        items: [(layout: RenditionLayout, side: SpreadPosition?, linear: Bool, spread: RenditionSpread?)],
        layout: RenditionLayout = .prePaginated,
        spread: RenditionSpread = .auto,
        progression: PageProgression = .default
    ) -> Publication {
        let readingOrder = items.enumerated().map { index, item in
            SpineItem(id: "p\(index)", index: index, path: "p\(index).xhtml", mediaType: "application/xhtml+xml", isLinear: item.linear,
                      layout: item.layout, spreadPosition: item.side, spread: item.spread)
        }
        return Publication(
            id: PublicationID(), metadata: Metadata(title: "t"), manifest: [], readingOrder: readingOrder, toc: [], pageList: [], landmarks: [],
            layout: layout, spread: spread, pageProgression: progression, coverImagePath: nil, packageDocumentPath: "p.opf",
            navigationDocumentPath: nil, warnings: []
        )
    }

    typealias Page = SpreadPlan.FixedPage

    @Test func harukoPairsRightToLeftPagesAndLeavesCoverAndLastPageAlone() async throws {
        let container = try await EPUBContainer(url: Self.fixtures.appendingPathComponent("haruko-html-jpeg.epub"))
        let plan = SpreadBuilder.plan(for: container.publication, policy: .auto, viewportSize: Self.landscape)
        #expect(plan.units.count == 8)
        #expect(plan.units[0] == .fixed(pages: [Page(spineIndex: 0, placement: .left)]))
        #expect(plan.units[1] == .fixed(pages: [Page(spineIndex: 1, placement: .right), Page(spineIndex: 2, placement: .left)]))
        #expect(plan.units[5] == .fixed(pages: [Page(spineIndex: 9, placement: .right), Page(spineIndex: 10, placement: .left)]))
        #expect(plan.units[6] == .fixed(pages: [Page(spineIndex: 11, placement: .right)]))
        #expect(plan.units[7] == .reflowable(spineIndex: 12, twoPages: true))
        #expect(plan.unitIndex(containing: 10) == 5)
        #expect(plan.units[1].leadingSpineIndex == 1)
        #expect(plan.units[1].isTwoPageLayout)

        // rendition:spread is landscape: a portrait viewport shows single pages.
        let single = SpreadBuilder.plan(for: container.publication, policy: .auto, viewportSize: Self.portrait)
        #expect(single.units.count == 13)
        #expect(single.units.allSatisfy { !$0.isTwoPageLayout })
        #expect(single.units[1] == .fixed(pages: [Page(spineIndex: 1, placement: .full)]))
        // `always` pairs even in portrait.
        let forced = SpreadBuilder.plan(for: container.publication, policy: .always, viewportSize: Self.portrait)
        #expect(forced.units == plan.units)
        // `never` never pairs.
        let never = SpreadBuilder.plan(for: container.publication, policy: .never, viewportSize: Self.landscape)
        #expect(never.units == single.units)
    }

    @Test func pageBlancheStartsWithTheCoverOnTheRight() async throws {
        let container = try await EPUBContainer(url: Self.fixtures.appendingPathComponent("page-blanche.epub"))
        let plan = SpreadBuilder.plan(for: container.publication, policy: .auto, viewportSize: Self.landscape)
        #expect(plan.units.count == 6)
        #expect(plan.units[0] == .fixed(pages: [Page(spineIndex: 0, placement: .right)]))
        #expect(plan.units[1] == .fixed(pages: [Page(spineIndex: 1, placement: .left), Page(spineIndex: 2, placement: .right)]))
        #expect(plan.units[4] == .fixed(pages: [Page(spineIndex: 7, placement: .left), Page(spineIndex: 8, placement: .right)]))
        #expect(plan.units[5] == .fixed(pages: [Page(spineIndex: 9, placement: .left)]))
    }

    @Test func coleKeepsSpreadNonePaintingsSingleBetweenReflowableText() async throws {
        let container = try await EPUBContainer(url: Self.fixtures.appendingPathComponent("cole-voyage-of-life.epub"))
        let plan = SpreadBuilder.plan(for: container.publication, policy: .auto, viewportSize: Self.landscape)
        #expect(plan.units.count == container.publication.readingOrder.count)
        for (index, item) in container.publication.readingOrder.enumerated() {
            if item.isFixedLayout {
                #expect(plan.units[index] == .fixed(pages: [Page(spineIndex: index, placement: .full)]))
            } else {
                #expect(plan.units[index] == .reflowable(spineIndex: index, twoPages: true))
            }
        }
        let portrait = SpreadBuilder.plan(for: container.publication, policy: .auto, viewportSize: Self.portrait)
        #expect(portrait.units.allSatisfy { !$0.isTwoPageLayout })
    }

    @Test func alternatesSidesWhenNoneAreDeclared() {
        let pub = Self.publication(items: Array(repeating: (layout: .prePaginated, side: nil, linear: true, spread: nil), count: 5))
        let plan = SpreadBuilder.plan(for: pub, policy: .auto, viewportSize: Self.landscape)
        // ltr: first page alone on the right, then (left, right) pairs, last page alone on the left.
        #expect(plan.units == [
            .fixed(pages: [Page(spineIndex: 0, placement: .right)]),
            .fixed(pages: [Page(spineIndex: 1, placement: .left), Page(spineIndex: 2, placement: .right)]),
            .fixed(pages: [Page(spineIndex: 3, placement: .left), Page(spineIndex: 4, placement: .right)]),
        ])
        let rtl = SpreadBuilder.plan(for: Self.publication(items: Array(repeating: (layout: .prePaginated, side: nil, linear: true, spread: nil), count: 4), progression: .rtl), policy: .auto, viewportSize: Self.landscape)
        #expect(rtl.units == [
            .fixed(pages: [Page(spineIndex: 0, placement: .left)]),
            .fixed(pages: [Page(spineIndex: 1, placement: .right), Page(spineIndex: 2, placement: .left)]),
            .fixed(pages: [Page(spineIndex: 3, placement: .right)]),
        ])
    }

    @Test func explicitSidesResetAlternationAndCenterStandsAlone() {
        let pub = Self.publication(items: [
            (layout: .prePaginated, side: .right, linear: true, spread: nil),
            (layout: .prePaginated, side: .right, linear: true, spread: nil),   // two rights in a row: both alone
            (layout: .prePaginated, side: nil, linear: true, spread: nil),      // continues as left …
            (layout: .prePaginated, side: nil, linear: true, spread: nil),      // … paired with right
            (layout: .prePaginated, side: .center, linear: true, spread: nil),
            (layout: .prePaginated, side: nil, linear: false, spread: nil),     // non-linear: alone, does not shift sides
            (layout: .prePaginated, side: nil, linear: true, spread: RenditionSpread.none), // spread none: full page (`.none` alone would be Optional.none)
            (layout: .reflowable, side: nil, linear: true, spread: nil),
            (layout: .prePaginated, side: nil, linear: true, spread: nil),      // after reflowable: lone first side again
        ])
        let plan = SpreadBuilder.plan(for: pub, policy: .auto, viewportSize: Self.landscape)
        #expect(plan.units == [
            .fixed(pages: [Page(spineIndex: 0, placement: .right)]),
            .fixed(pages: [Page(spineIndex: 1, placement: .right)]),
            .fixed(pages: [Page(spineIndex: 2, placement: .left), Page(spineIndex: 3, placement: .right)]),
            .fixed(pages: [Page(spineIndex: 4, placement: .full)]),
            .fixed(pages: [Page(spineIndex: 5, placement: .full)]),
            .fixed(pages: [Page(spineIndex: 6, placement: .full)]),
            .reflowable(spineIndex: 7, twoPages: true),
            .fixed(pages: [Page(spineIndex: 8, placement: .right)]),
        ])
    }

    @Test func bothSpreadsInPortraitAndItemOverridesWin() {
        let pub = Self.publication(items: [
            (layout: .prePaginated, side: .left, linear: true, spread: nil),
            (layout: .prePaginated, side: .right, linear: true, spread: nil),
            (layout: .prePaginated, side: .left, linear: true, spread: .landscape),
            (layout: .prePaginated, side: .right, linear: true, spread: nil),
        ], spread: .both)
        let plan = SpreadBuilder.plan(for: pub, policy: .auto, viewportSize: Self.portrait)
        #expect(plan.units == [
            .fixed(pages: [Page(spineIndex: 0, placement: .left), Page(spineIndex: 1, placement: .right)]),
            .fixed(pages: [Page(spineIndex: 2, placement: .full)]),
            .fixed(pages: [Page(spineIndex: 3, placement: .right)]),
        ])
        let reflow = Self.publication(items: [(layout: .reflowable, side: nil, linear: true, spread: nil)], layout: .reflowable, spread: .none)
        #expect(SpreadBuilder.plan(for: reflow, policy: .always, viewportSize: Self.landscape).units == [.reflowable(spineIndex: 0, twoPages: false)])
    }
}
