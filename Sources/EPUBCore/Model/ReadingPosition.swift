import Foundation

/// Where the reader is in a publication (docs/design/03-api.md §2.4). The CFI is the position; the rest is
/// derived at the time it was recorded and is for display.
public struct ReadingPosition: Codable, Hashable, Sendable {
    public var cfi: CFI
    public var spineIndex: Int
    /// Label of the deepest table-of-contents entry that points at this spine item, if any.
    public var chapterTitle: String?
    /// 0...1 within the chapter.
    public var progressionInChapter: Double
    /// 0...1 within the book (an estimate while pagination is still being measured).
    public var totalProgression: Double

    public init(cfi: CFI, spineIndex: Int, chapterTitle: String? = nil, progressionInChapter: Double = 0, totalProgression: Double = 0) {
        self.cfi = cfi
        self.spineIndex = spineIndex
        self.chapterTitle = chapterTitle
        self.progressionInChapter = progressionInChapter
        self.totalProgression = totalProgression
    }
}

/// A highlighted range (docs/design/03-api.md §2.5). The app persists these; the library draws them.
public struct Highlight: Identifiable, Codable, Hashable, Sendable {
    public enum Style: Codable, Hashable, Sendable {
        case background(ReaderColor)
        case underline(ReaderColor)

        public var color: ReaderColor {
            switch self {
            case .background(let c), .underline(let c): return c
            }
        }
    }

    public var id: UUID
    public var range: CFIRange
    public var style: Style
    public var note: String?

    public init(id: UUID = UUID(), range: CFIRange, style: Style = .background(ReaderColor(hex: 0xFFE066, alpha: 0.6)), note: String? = nil) {
        self.id = id
        self.range = range
        self.style = style
        self.note = note
    }

    public var spineIndex: Int { range.spineIndex }
}

public struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var position: ReadingPosition
    public var createdAt: Date

    public init(id: UUID = UUID(), position: ReadingPosition, createdAt: Date = Date()) {
        self.id = id
        self.position = position
        self.createdAt = createdAt
    }
}
