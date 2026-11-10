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
