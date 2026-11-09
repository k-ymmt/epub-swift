import Foundation

/// Full-text search over the spine documents, without a web view (docs/design/01-core.md §6.2).
///
/// Each spine item's `TextMap` is built on first use (or by `prepare()`) and cached in the actor. Results stream
/// chapter by chapter in spine order so the UI can show them as they arrive.
public actor SearchService {
    private let container: EPUBContainer
    private var maps: [Int: TextMap?] = [:]
    private var documents: [Int: XMLDocument] = [:]
    private var preparation: Task<Void, Never>?

    public init(container: EPUBContainer) {
        self.container = container
    }

    public nonisolated var publication: Publication { container.publication }

    /// Builds the text maps of every spine item in the background. Optional; `search` builds what it needs.
    public func prepare() {
        guard preparation == nil else { return }
        preparation = Task { [weak self] in
            guard let self else { return }
            for item in await self.publication.readingOrder {
                if Task.isCancelled { return }
                _ = await self.textMap(forSpineIndex: item.index)
                await Task.yield()
            }
        }
    }

    /// Finds `query` in the linear spine items. Cancelling the consuming task stops the search.
    public nonisolated func search(_ query: String, options: SearchOptions = .default) -> AsyncThrowingStream<SearchResult, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continuation.finish(); return }
                    for item in publication.linearReadingOrder {
                        try Task.checkCancellation()
                        let results = await self.results(for: trimmed, options: options, spineIndex: item.index)
                        for result in results {
                            try Task.checkCancellation()
                            continuation.yield(result)
                        }
                        await Task.yield()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// All matches in one spine item, in document order.
    public func results(for query: String, options: SearchOptions = .default, spineIndex: Int) async -> [SearchResult] {
        guard let map = await textMap(forSpineIndex: spineIndex), let document = documents[spineIndex] else { return [] }
        let spineSteps = publication.cfiSpineSteps(forSpineIndex: spineIndex)
        let text = map.text as NSString
        var compare: NSString.CompareOptions = []
        if options.caseInsensitive { compare.insert(.caseInsensitive) }
        if options.diacriticInsensitive { compare.insert(.diacriticInsensitive) }
        if options.widthInsensitive { compare.insert(.widthInsensitive) }
        var results: [SearchResult] = []
        var searchRange = NSRange(location: 0, length: text.length)
        let locale = publication.metadata.language.map { Locale(identifier: $0) }
        while searchRange.length > 0 {
            let found = text.range(of: query, options: compare, range: searchRange, locale: locale)
            guard found.location != NSNotFound, found.length > 0 else { break }
            if let result = makeResult(match: found, in: map, text: text, document: document, spineIndex: spineIndex, spineSteps: spineSteps) {
                results.append(result)
            }
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: text.length - next)
        }
        return results
    }

    private func makeResult(match: NSRange, in map: TextMap, text: NSString, document: XMLDocument, spineIndex: Int, spineSteps: [CFI.Step]) -> SearchResult? {
        guard let startLocation = map.location(ofUTF16Offset: match.location),
              let endLocation = map.location(ofUTF16Offset: match.location + match.length),
              let start = CFIGenerator.cfi(for: startLocation, in: document, spineSteps: spineSteps),
              let end = CFIGenerator.cfi(for: endLocation, in: document, spineSteps: spineSteps) else { return nil }
        // Snippet: up to `context` code units on each side, cut at the block boundaries (newlines).
        let context = 40
        var lower = max(0, match.location - context)
        var upper = min(text.length, match.location + match.length + context)
        if let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: lower, length: match.location - lower)).location as Int?, newline != NSNotFound {
            lower = newline + 1
        }
        if let newline = text.range(of: "\n", range: NSRange(location: match.location + match.length, length: upper - match.location - match.length)).location as Int?, newline != NSNotFound {
            upper = newline
        }
        // Do not split a surrogate pair at the edges.
        lower = text.rangeOfComposedCharacterSequence(at: lower).location
        if upper < text.length { upper = text.rangeOfComposedCharacterSequence(at: upper).location }
        let snippet = text.substring(with: NSRange(location: lower, length: upper - lower))
        let matchStart = String.Index(utf16Offset: match.location - lower, in: snippet)
        let matchEnd = String.Index(utf16Offset: match.location + match.length - lower, in: snippet)
        return SearchResult(
            spineIndex: spineIndex,
            range: CFIRange(start: start, end: end),
            snippet: snippet,
            matchRangeInSnippet: matchStart..<matchEnd,
            matchedText: text.substring(with: match)
        )
    }

    /// The text map of a spine item (nil for non-XHTML items and documents that could not be parsed).
    public func textMap(forSpineIndex index: Int) async -> TextMap? {
        if let cached = maps[index] { return cached }
        guard publication.readingOrder.indices.contains(index) else { return nil }
        let item = publication.readingOrder[index]
        var map: TextMap?
        if let document = try? await container.contentDocument(at: item.path), document.isXML, let tree = try? XMLDocument(data: document.data) {
            map = TextMap(document: tree)
            documents[index] = tree
        }
        maps[index] = .some(map)
        return map
    }

    /// The parsed document of a spine item, once its text map has been built.
    public func document(forSpineIndex index: Int) async -> XMLDocument? {
        _ = await textMap(forSpineIndex: index)
        return documents[index]
    }
}

public struct SearchOptions: Sendable, Hashable {
    public var caseInsensitive = true
    public var diacriticInsensitive = true
    /// Full-width and half-width forms compare equal (`Ａ` = `A`, `ｶ` = `カ`).
    public var widthInsensitive = true

    public init(caseInsensitive: Bool = true, diacriticInsensitive: Bool = true, widthInsensitive: Bool = true) {
        self.caseInsensitive = caseInsensitive
        self.diacriticInsensitive = diacriticInsensitive
        self.widthInsensitive = widthInsensitive
    }

    public static let `default` = SearchOptions()
}

public struct SearchResult: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let spineIndex: Int
    public let range: CFIRange
    /// Text around the match, within one block.
    public let snippet: String
    public let matchRangeInSnippet: Range<String.Index>
    /// The matched text as it appears in the document.
    public let matchedText: String

    public init(id: UUID = UUID(), spineIndex: Int, range: CFIRange, snippet: String, matchRangeInSnippet: Range<String.Index>, matchedText: String) {
        self.id = id
        self.spineIndex = spineIndex
        self.range = range
        self.snippet = snippet
        self.matchRangeInSnippet = matchRangeInSnippet
        self.matchedText = matchedText
    }
}
