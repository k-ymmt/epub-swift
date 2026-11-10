import Foundation

/// How importing a set would change the app's annotations (06-annotations §8). Nothing is changed until the app
/// applies the plan; the specification asks Reading Systems not to duplicate ids and to let the reader decide on
/// updates.
public struct AnnotationMergePlan: Sendable {
    /// Annotations with ids the app does not have.
    public var added: [Annotation]
    /// Incoming annotations newer than the app's (by `modified`, else `created`).
    public var updated: [Annotation]
    /// Same content as the app's.
    public var unchanged: [Annotation.ID]
    /// The app's annotation is newer.
    public var outdated: [Annotation.ID]
    /// Different content and no date to decide by (equal or missing). The app decides.
    public var conflicts: [(existing: Annotation, incoming: Annotation)]

    /// Compares `incoming` (normally the resolved items of an imported set) with `existing`. Incoming annotations
    /// get the origin `.imported(setID:importedAt:)` (also when they replace one made here).
    public init(existing: [Annotation], incoming: AnnotationSet, importedAt: Date = Annotation.now()) {
        added = []
        updated = []
        unchanged = []
        outdated = []
        conflicts = []
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in incoming.items {
            var annotation = item
            if case .imported = annotation.origin {} else {
                annotation.origin = .imported(setID: incoming.id, importedAt: importedAt)
            }
            guard let current = byID[annotation.id] else {
                added.append(annotation)
                continue
            }
            if Self.sameContent(current, annotation) {
                unchanged.append(annotation.id)
                continue
            }
            let currentDate = current.modified ?? current.created
            let incomingDate = annotation.modified ?? annotation.created
            if incomingDate > currentDate {
                updated.append(annotation)
            } else if incomingDate < currentDate {
                outdated.append(annotation.id)
            } else {
                conflicts.append((current, annotation))
            }
        }
    }

    /// `existing` with `updated` replacing the annotations with their ids, each conflict replaced by what
    /// `resolvingConflicts(existing, incoming)` returns, and `added` appended in the incoming order.
    public func applying(to existing: [Annotation], resolvingConflicts: (Annotation, Annotation) -> Annotation) -> [Annotation] {
        var replacements = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for conflict in conflicts {
            replacements[conflict.existing.id] = resolvingConflicts(conflict.existing, conflict.incoming)
        }
        var out = existing.map { replacements[$0.id] ?? $0 }
        let ids = Set(out.map(\.id))
        out.append(contentsOf: added.filter { !ids.contains($0.id) })
        return out
    }

    /// `applying(to:resolvingConflicts:)` keeping the app's annotation for every conflict.
    public func applying(to existing: [Annotation]) -> [Annotation] {
        applying(to: existing) { current, _ in current }
    }

    /// Same motivation, place and body. Dates, creator and origin are not compared: an export rounds dates and
    /// leaves the creator out by default, so re-importing one's own export compares equal.
    static func sameContent(_ a: Annotation, _ b: Annotation) -> Bool {
        guard a.motivation == b.motivation, samePosition(a.target, b.target) else { return false }
        return normalizedBody(a) == normalizedBody(b)
    }

    private static func samePosition(_ a: Target, _ b: Target) -> Bool {
        switch (a.position, b.position) {
        case (.range(let x), .range(let y)):
            return x.start.withoutAssertions == y.start.withoutAssertions && x.end.withoutAssertions == y.end.withoutAssertions
        case (.point(let x), .point(let y)):
            return x.withoutAssertions == y.withoutAssertions
        case (.resource, .resource):
            return ContainerPath.normalize(a.source) == ContainerPath.normalize(b.source)
        case (.unresolved, .unresolved):
            return a.source == b.source && a.originalSelectors == b.originalSelectors
        default:
            return false
        }
    }

    /// A missing body equals the default one (no note, yellow, solid).
    private static func normalizedBody(_ annotation: Annotation) -> Body {
        annotation.body ?? Body()
    }
}
