import Foundation
import Testing
@testable import EPUBCore

/// Import merge planning (docs/design/06-annotations.md §8).
struct AnnotationMergePlanTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func highlight(_ id: String, offset: Int = 0, color: HighlightColor = .yellow, created: Date = t0, modified: Date? = nil) -> Annotation {
        Annotation(
            id: id,
            motivation: .highlighting,
            created: created,
            modified: modified,
            target: Target(source: "OPS/c1.xhtml", position: .range(CFIRange("epubcfi(/6/2[c1]!/4/4,/1:\(offset),/1:\(offset + 3))")!)),
            body: Body(color: color)
        )
    }

    @Test func classifies() {
        let existing = [
            Self.highlight("same"),
            Self.highlight("newer-incoming"),
            Self.highlight("older-incoming", modified: Self.t0.addingTimeInterval(100)),
            Self.highlight("conflict"),
            Self.highlight("local-only"),
        ]
        var incoming = AnnotationSet(id: "urn:x:set")
        incoming.items = [
            // Same place and look; the export rounded the date and dropped the creator.
            Self.highlight("same", created: Self.t0.addingTimeInterval(-3600)),
            Self.highlight("newer-incoming", color: .pink, modified: Self.t0.addingTimeInterval(60)),
            Self.highlight("older-incoming", color: .green, modified: Self.t0.addingTimeInterval(50)),
            Self.highlight("conflict", offset: 5),
            Self.highlight("new"),
        ]
        let importedAt = Self.t0.addingTimeInterval(999)
        let plan = AnnotationMergePlan(existing: existing, incoming: incoming, importedAt: importedAt)
        #expect(plan.added.map(\.id) == ["new"])
        #expect(plan.updated.map(\.id) == ["newer-incoming"])
        #expect(plan.unchanged == ["same"])
        #expect(plan.outdated == ["older-incoming"])
        #expect(plan.conflicts.map(\.existing.id) == ["conflict"])
        #expect(plan.added[0].origin == .imported(setID: "urn:x:set", importedAt: importedAt))
        #expect(plan.updated[0].origin == .imported(setID: "urn:x:set", importedAt: importedAt))

        let kept = plan.applying(to: existing)
        #expect(kept.map(\.id) == ["same", "newer-incoming", "older-incoming", "conflict", "local-only", "new"])
        #expect(kept[1].color == .pink)
        #expect(kept[3] == existing[3])

        let takeIncoming = plan.applying(to: existing) { _, incoming in incoming }
        #expect(takeIncoming[3].range == incoming.items[3].range)
    }

    @Test func missingBodyEqualsTheDefaultLook() {
        var a = Self.highlight("a")
        a.body = nil
        var b = Self.highlight("a")
        b.body = Body()
        #expect(AnnotationMergePlan.sameContent(a, b))
        b.body?.tags = ["x"]
        #expect(!AnnotationMergePlan.sameContent(a, b))
    }
}
