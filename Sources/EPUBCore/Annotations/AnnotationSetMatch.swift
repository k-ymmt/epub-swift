import Foundation

/// How well an annotation set's description matches a book (06-annotations §7). The specification has no unique
/// book identifier, so the library only gathers the evidence; whether to import is the app's (the reader's) call.
/// `dc:identifier` alone does not prove a match: different books sometimes share one.
public struct AnnotationSetMatch: Hashable, Sendable {
    public enum MatchResult: Hashable, Sendable {
        case match
        case mismatch
        /// The set or the book does not say.
        case absent
    }

    /// `dc:identifier` against the package's unique identifier.
    public var identifier: MatchResult
    /// Compared after Unicode normalization (NFKC), case folding and whitespace collapsing.
    public var title: MatchResult
    /// Every creator of the set appears among the book's authors (same normalization).
    public var creators: MatchResult
    public var publisher: MatchResult
    /// Fraction of annotations whose `source` is a spine item of the book.
    public var resolvedSourceRatio: Double
    /// Fraction of annotations whose position was found (as a CFI, or the whole document).
    public var resolvedPositionRatio: Double

    public init(identifier: MatchResult, title: MatchResult, creators: MatchResult, publisher: MatchResult, resolvedSourceRatio: Double, resolvedPositionRatio: Double) {
        self.identifier = identifier
        self.title = title
        self.creators = creators
        self.publisher = publisher
        self.resolvedSourceRatio = resolvedSourceRatio
        self.resolvedPositionRatio = resolvedPositionRatio
    }

    init(about: AnnotationSet.About, publication: Publication, resolvedSourceRatio: Double, resolvedPositionRatio: Double) {
        let metadata = publication.metadata
        func compare(_ a: String?, _ b: String?) -> MatchResult {
            guard let a = a.map(Self.normalized), !a.isEmpty, let b = b.map(Self.normalized), !b.isEmpty else { return .absent }
            return a == b ? .match : .mismatch
        }
        identifier = {
            guard let a = about.identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty,
                  let b = metadata.identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return .absent }
            return a == b ? .match : .mismatch
        }()
        title = compare(about.title?.text, metadata.title)
        if about.creators.isEmpty || metadata.authors.isEmpty {
            creators = .absent
        } else {
            let authors = Set(metadata.authors.map(Self.normalized))
            creators = about.creators.allSatisfy { authors.contains(Self.normalized($0.text)) } ? .match : .mismatch
        }
        publisher = compare(about.publisher?.text, metadata.publisher)
        self.resolvedSourceRatio = resolvedSourceRatio
        self.resolvedPositionRatio = resolvedPositionRatio
    }

    static func normalized(_ string: String) -> String {
        string.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
