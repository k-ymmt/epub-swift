import Foundation

/// How a position was found (diagnostics and tests).
public enum ResolutionMethod: String, Hashable, Sendable {
    /// The position was already a CFI that is trusted (made here or stored by this app).
    case trusted
    /// `epubswift:CfiSelector`, agreeing with the standard selectors (or the only selector that resolved).
    case cfi
    /// CssSelector (with its TextPositionSelector refinement).
    case cssSelector
    /// TextQuoteSelector.
    case textQuote
    /// FragmentSelector of an element id (RFC 3236).
    case elementFragment
    /// FragmentSelector of a text fragment.
    case textFragment
    case resource
    case unresolved
}

/// The result of resolving a set against a book (06-annotations §6, §7).
public struct AnnotationResolution: Sendable {
    /// The set with each annotation's position resolved where possible. Imported annotations keep their original
    /// selectors.
    public var annotationSet: AnnotationSet
    /// Material for deciding whether the set is about this book. The app decides.
    public var match: AnnotationSetMatch
    public var methods: [Annotation.ID: ResolutionMethod]

    /// Annotations whose position could not be found (kept with their selectors).
    public var unresolvedIDs: [Annotation.ID] {
        annotationSet.items.filter { $0.target.position == .unresolved }.map(\.id)
    }
}

/// Generates the exchange selectors of the specification from CFIs (§5) and resolves them back to CFIs (§6), on
/// EPUBCore's lightweight DOM: no WebView. The CFI is counted on the rendered tree (WebKit's DOM) and the selectors on
/// the source tree (the DOM of a Reading System that runs scripts).
public struct AnnotationResolver: Sendable {
    public let container: EPUBContainer

    public init(container: EPUBContainer) {
        self.container = container
    }

    // MARK: Public API

    /// Resolves the positions of the set's annotations and compares the set with the book.
    ///
    /// An annotation without original selectors whose position is already a CFI (made or stored by this app) is
    /// trusted as it is. Annotations read from a file are resolved from their selectors (§6.2): the CFI selector is
    /// checked against the standard selectors and loses when they cover different text.
    @concurrent
    public func resolve(_ set: AnnotationSet) async -> AnnotationResolution {
        var resolved = set
        var methods: [Annotation.ID: ResolutionMethod] = [:]
        var sourcesFound = 0
        var cache = ChapterCache(container: container)
        for index in resolved.items.indices {
            let (annotation, method, sourceFound) = await resolveAnnotation(resolved.items[index], cache: &cache)
            resolved.items[index] = annotation
            methods[annotation.id] = method
            if sourceFound { sourcesFound += 1 }
        }
        let count = Double(max(1, resolved.items.count))
        let positioned = resolved.items.filter {
            switch $0.target.position {
            case .range, .point: return true
            case .resource: return true
            case .unresolved: return false
            }
        }.count
        let match = AnnotationSetMatch(
            about: set.about,
            publication: container.publication,
            resolvedSourceRatio: resolved.items.isEmpty ? 0 : Double(sourcesFound) / count,
            resolvedPositionRatio: resolved.items.isEmpty ? 0 : Double(positioned) / count
        )
        return AnnotationResolution(annotationSet: resolved, match: match, methods: methods)
    }

    /// Resolves the positions of `annotations` (see `resolve(_:)` for the set).
    @concurrent
    public func resolve(_ annotations: [Annotation]) async -> [Annotation] {
        await resolve(AnnotationSet(items: annotations)).annotationSet.items
    }

    /// Fills `Target.generatedSelectors` (CssSelector refined by a TextPositionSelector, and a TextQuoteSelector for
    /// ranges) for the annotations that need them on export: those made here and those whose position changed.
    /// Annotations that keep their original selectors, and unresolved or whole-document ones, are left alone.
    @concurrent
    public func generatingSelectors(for set: AnnotationSet) async -> AnnotationSet {
        var out = set
        var cache = ChapterCache(container: container)
        let publication = container.publication
        for index in out.items.indices {
            let annotation = out.items[index]
            guard annotation.target.originalSelectors == nil, annotation.target.generatedSelectors == nil else { continue }
            let start: CFI
            let end: CFI
            switch annotation.target.position {
            case .range(let range): start = range.start; end = range.end
            case .point(let cfi): start = cfi; end = cfi
            case .resource, .unresolved: continue
            }
            guard let spineIndex = publication.spineIndex(of: start),
                  let chapter = await cache.chapter(spineIndex) else { continue }
            let isPoint: Bool
            if case .point = annotation.target.position { isPoint = true } else { isPoint = false }
            if let selectors = Self.selectors(start: start, end: end, isPoint: isPoint, in: chapter) {
                out.items[index].target.generatedSelectors = selectors
            }
        }
        return out
    }

    /// Generates selectors for one annotation list (see `generatingSelectors(for:)` on a set).
    @concurrent
    public func generatingSelectors(for annotations: [Annotation]) async -> [Annotation] {
        await generatingSelectors(for: AnnotationSet(items: annotations)).items
    }

    // MARK: Chapters

    struct ChapterCache {
        let container: EPUBContainer
        var chapters: [Int: ChapterText?] = [:]

        init(container: EPUBContainer) {
            self.container = container
        }

        mutating func chapter(_ spineIndex: Int) async -> ChapterText? {
            if let cached = chapters[spineIndex] { return cached }
            let publication = container.publication
            guard publication.readingOrder.indices.contains(spineIndex) else { return nil }
            let path = publication.readingOrder[spineIndex].path
            var chapter: ChapterText?
            if let document = try? await container.contentDocument(at: path), document.isXML {
                chapter = ChapterText(data: document.data, spineIndex: spineIndex, spineSteps: publication.cfiSpineSteps(forSpineIndex: spineIndex))
            }
            chapters[spineIndex] = chapter
            return chapter
        }
    }

    // MARK: Resolution (§6)

    private func resolveAnnotation(_ annotation: Annotation, cache: inout ChapterCache) async -> (Annotation, ResolutionMethod, Bool) {
        let publication = container.publication
        let spineIndex = Self.spineIndex(forSource: annotation.target.source, in: publication)
        guard let originals = annotation.target.originalSelectors else {
            // Made or stored here: the CFI is trusted.
            switch annotation.target.position {
            case .range, .point: return (annotation, .trusted, spineIndex != nil)
            case .resource: return (annotation, .resource, spineIndex != nil)
            case .unresolved: return (annotation, .unresolved, spineIndex != nil)
            }
        }
        var out = annotation
        guard let spineIndex, let chapter = await cache.chapter(spineIndex) else {
            out.target.setResolvedPosition(originals.isEmpty ? .resource : .unresolved)
            return (out, .unresolved, spineIndex != nil)
        }
        if originals.isEmpty {
            out.target.setResolvedPosition(.resource)
            return (out, .resource, true)
        }
        let isPoint = annotation.motivation == .bookmarking
        let result = Self.resolve(originals, isPoint: isPoint, in: chapter, publication: publication)
        out.target.setResolvedPosition(result.position)
        return (out, result.method, true)
    }

    /// The spine index of a `source` (§6.1): the container path from the root, else relative to the package
    /// document's directory. Absolute URLs, absolute paths and paths that climb out of the container are refused.
    static func spineIndex(forSource source: String, in publication: Publication) -> Int? {
        if let path = AnnotationPath.resolveContained(source), let index = publication.spineIndex(ofPath: path) {
            return index
        }
        let packageDirectory = ContainerPath.directory(of: publication.packageDocumentPath)
        if !packageDirectory.isEmpty, let path = AnnotationPath.resolveContained(source, base: packageDirectory),
           let index = publication.spineIndex(ofPath: path) {
            return index
        }
        return nil
    }

    /// A span on the rendered tree, as UTF-16 offsets into the whole text (for comparing results) and locations.
    struct Span: Equatable {
        var start: DocumentLocation
        var end: DocumentLocation
    }

    static func resolve(_ selectors: [AnnotationSelector], isPoint: Bool, in chapter: ChapterText, publication: Publication) -> (position: Target.Position, method: ResolutionMethod) {
        func position(_ span: Span) -> Target.Position? {
            guard let start = CFIGenerator.cfi(for: span.start, in: chapter.rendered, spineSteps: chapter.spineSteps) else { return nil }
            if isPoint { return .point(start) }
            guard let end = CFIGenerator.cfi(for: span.end, in: chapter.rendered, spineSteps: chapter.spineSteps) else { return nil }
            return .range(CFIRange(start: start, end: end))
        }

        // 1. The CFI selector, when it addresses this chapter and resolves.
        var cfiCandidate: (range: CFIRange, span: Span)?
        for case .cfi(let string) in selectors {
            guard let range = CFIRange(string), publication.spineIndex(of: range.start) == chapter.spineIndex,
                  let start = CFIResolver.resolve(range.start, in: chapter.rendered) else { continue }
            let end = isPoint ? start : (CFIResolver.resolve(range.end, in: chapter.rendered) ?? start)
            cfiCandidate = (range, Span(start: start, end: end))
            break
        }
        // 2–6. The standard selectors.
        let hint = cfiCandidate.flatMap { chapter.renderedText.utf16Offset(of: $0.span.start) }
        let standard = resolveStandard(selectors, isPoint: isPoint, in: chapter, cfiHint: hint)

        if let cfiCandidate {
            let cfiPosition: Target.Position = isPoint ? .point(cfiCandidate.range.start) : .range(cfiCandidate.range)
            guard let standard else { return (cfiPosition, .cfi) }
            if sameText(cfiCandidate.span, standard.span, isPoint: isPoint, in: chapter) {
                return (cfiPosition, .cfi)
            }
            if let p = position(standard.span) { return (p, standard.method) }
            return (cfiPosition, .cfi)
        }
        if let standard, let p = position(standard.span) { return (p, standard.method) }
        return (.unresolved, .unresolved)
    }

    /// Whether two spans cover the same text (the same offsets into the rendered text).
    static func sameText(_ a: Span, _ b: Span, isPoint: Bool, in chapter: ChapterText) -> Bool {
        let text = chapter.renderedText
        guard let a0 = text.utf16Offset(of: a.start), let b0 = text.utf16Offset(of: b.start) else { return false }
        if isPoint { return a0 == b0 }
        guard let a1 = text.utf16Offset(of: a.end), let b1 = text.utf16Offset(of: b.end) else { return false }
        return a0 == b0 && a1 == b1
    }

    /// Code-point offsets into the source tree's whole text.
    struct SourceSpan {
        var start: Int
        var end: Int
    }

    static func resolveStandard(_ selectors: [AnnotationSelector], isPoint: Bool, in chapter: ChapterText, cfiHint: Int?) -> (span: Span, method: ResolutionMethod)? {
        let quote = selectors.lazy.compactMap { selector -> (exact: String, prefix: String?, suffix: String?)? in
            if case .textQuote(let exact, let prefix, let suffix) = selector { return (exact, prefix, suffix) }
            return nil
        }.first

        func rendered(_ span: SourceSpan) -> Span? {
            let range = 0..<chapter.sourceText.nodes.count
            guard let s = chapter.sourceText.location(atScalar: span.start, in: range, bias: .forward),
                  let e = chapter.sourceText.location(atScalar: isPoint ? span.start : span.end, in: range, bias: isPoint ? .forward : .backward),
                  let rs = chapter.correspondence.renderedLocation(forSource: s, bias: .forward, sourceText: chapter.sourceText),
                  let re = chapter.correspondence.renderedLocation(forSource: e, bias: isPoint ? .forward : .backward, sourceText: chapter.sourceText) else { return nil }
            return Span(start: rs, end: re)
        }

        // A source span of an element with no text (an image bookmark) is the element itself.
        func renderedElement(_ path: [Int]) -> Span? {
            guard let r = chapter.correspondence.renderedLocation(forSource: DocumentLocation(path: path), bias: .forward, sourceText: chapter.sourceText) else { return nil }
            return Span(start: r, end: r)
        }

        // 2. CssSelector refined by TextPositionSelector (and a top-level TextPositionSelector on the body).
        var cssHint: Int?
        for selector in selectors {
            guard let found = evaluateCSSOrPosition(selector, in: chapter) else { continue }
            if case .element(let path) = found {
                if let span = renderedElement(path) { return (span, .cssSelector) }
                continue
            }
            guard case .span(let span) = found else { continue }
            if let quote, !isPoint {
                if chapter.sourceString(span.start..<span.end) != quote.exact {
                    cssHint = span.start - chapter.bodyStart
                    continue
                }
            }
            if let r = rendered(span) { return (r, .cssSelector) }
        }

        // 3. TextQuoteSelector, near the CSS result (or the CFI) when it occurs more than once.
        if let quote, !quote.exact.isEmpty {
            let body = chapter.body
            var hint = cssHint
            if hint == nil, let cfiHint, let location = chapter.renderedText.location(atUTF16: cfiHint, bias: .forward),
               let source = chapter.correspondence.sourceLocation(forRendered: location, bias: .forward),
               let scalar = chapter.sourceText.scalarOffset(of: source) {
                hint = scalar - chapter.bodyStart
            }
            if let found = TextSearch.findQuote(exact: quote.exact, prefix: quote.prefix, suffix: quote.suffix, in: body, near: hint),
               let r = rendered(SourceSpan(start: chapter.bodyStart + found.lowerBound, end: chapter.bodyStart + found.upperBound)) {
                return (r, .textQuote)
            }
        }

        // 4–5. FragmentSelector: an element id, or a text fragment.
        for case .fragment(let value, let conformsTo, _) in selectors {
            switch FragmentKind(conformsTo: conformsTo, value: value) {
            case .element(let id):
                guard let path = chapter.source.path(ofElementWithID: id) else { continue }
                let range = chapter.sourceText.nodeRange(under: path)
                guard !range.isEmpty else {
                    if let span = renderedElement(path) { return (span, .elementFragment) }
                    continue
                }
                let first = chapter.sourceText.nodes[range.lowerBound]
                let last = chapter.sourceText.nodes[range.upperBound - 1]
                if let r = rendered(SourceSpan(start: first.scalarStart, end: last.scalarStart + last.scalarCount)) {
                    return (r, .elementFragment)
                }
            case .text(let directive):
                let body = chapter.body
                if let found = TextSearch.findTextDirective(directive, in: body),
                   let r = rendered(SourceSpan(start: chapter.bodyStart + found.lowerBound, end: chapter.bodyStart + found.upperBound)) {
                    return (r, .textFragment)
                }
            case .unsupported:
                continue
            }
        }
        return nil
    }

    enum CSSResult {
        case span(SourceSpan)
        case element([Int])
    }

    /// A CssSelector (refined by a TextPositionSelector, or by another CssSelector evaluated inside it), or a
    /// TextPositionSelector on the body.
    static func evaluateCSSOrPosition(_ selector: AnnotationSelector, in chapter: ChapterText, scope: [Int]? = nil) -> CSSResult? {
        switch selector {
        case .css(let value, let refinedBy):
            guard let path = CSSSubset.evaluate(value, in: chapter.source, idCounts: chapter.idCounts, scope: scope) else { return nil }
            if refinedBy.isEmpty { return wholeElement(path, in: chapter) }
            // Refinements are alternatives: the first that resolves.
            for refinement in refinedBy {
                switch refinement {
                case .textPosition(let start, let end, _):
                    if let span = textPosition(start: start, end: end, scope: path, in: chapter) { return span }
                case .css:
                    if let inner = evaluateCSSOrPosition(refinement, in: chapter, scope: path) { return inner }
                default:
                    continue
                }
            }
            return nil
        case .textPosition(let start, let end, _) where scope == nil:
            return textPosition(start: start, end: end, scope: chapter.bodyPath, in: chapter)
        default:
            return nil
        }
    }

    static func wholeElement(_ path: [Int], in chapter: ChapterText) -> CSSResult {
        let range = chapter.sourceText.nodeRange(under: path)
        guard !range.isEmpty else { return .element(path) }
        let first = chapter.sourceText.nodes[range.lowerBound]
        let last = chapter.sourceText.nodes[range.upperBound - 1]
        return .span(SourceSpan(start: first.scalarStart, end: last.scalarStart + last.scalarCount))
    }

    static func textPosition(start: Int, end: Int, scope: [Int], in chapter: ChapterText) -> CSSResult? {
        guard start <= end, let base = chapter.sourceText.scalarOffset(of: DocumentLocation(path: scope)) else { return nil }
        let range = chapter.sourceText.nodeRange(under: scope)
        let length = range.reduce(0) { $0 + chapter.sourceText.nodes[$1].scalarCount }
        if range.isEmpty, start == 0 { return .element(scope) }
        guard end <= length else { return nil }
        return .span(SourceSpan(start: base + start, end: base + end))
    }

    enum FragmentKind {
        case element(String)
        case text(String)
        case unsupported

        static let rfc3236 = "http://tools.ietf.org/rfc/rfc3236"
        static let textFragment = "https://wicg.github.io/scroll-to-text-fragment/"

        init(conformsTo: String?, value: String) {
            let trimmed = value.hasPrefix("#") ? String(value.dropFirst()) : value
            if let range = trimmed.range(of: ":~:") {
                self = .text(String(trimmed[range.upperBound...]))
                return
            }
            switch conformsTo {
            case Self.textFragment?:
                self = .text(trimmed)
            case Self.rfc3236?, nil:
                // Media fragments (`t=`, `xywh=`) and SVG views without conformsTo are not ids.
                if conformsTo == nil, trimmed.hasPrefix("xywh=") || trimmed.hasPrefix("t=") || trimmed.hasPrefix("svgView(") {
                    self = .unsupported
                } else {
                    let id = trimmed.removingPercentEncoding ?? trimmed
                    self = id.isEmpty ? .unsupported : .element(id)
                }
            default:
                self = .unsupported
            }
        }
    }

    // MARK: Generation (§5)

    /// Number of code points of context on each side of a quote, and the most it grows to.
    static let quoteContextStep = 32
    static let quoteContextLimit = 256

    static func selectors(start: CFI, end: CFI, isPoint: Bool, in chapter: ChapterText) -> [AnnotationSelector]? {
        guard let renderedStart = CFIResolver.resolve(start, in: chapter.rendered) else { return nil }
        let renderedEnd = isPoint ? renderedStart : (CFIResolver.resolve(end, in: chapter.rendered) ?? renderedStart)
        guard let sourceStart = chapter.correspondence.sourceLocation(forRendered: renderedStart, bias: .forward),
              var sourceEnd = chapter.correspondence.sourceLocation(forRendered: renderedEnd, bias: isPoint ? .forward : .backward),
              let startScalar = chapter.sourceText.scalarOffset(of: sourceStart),
              var endScalar = chapter.sourceText.scalarOffset(of: sourceEnd) else { return nil }
        if isPoint || endScalar < startScalar {
            sourceEnd = sourceStart
            endScalar = startScalar
        }
        // The scope: the deepest element containing both ends (an element location contains itself).
        func elementPath(_ location: DocumentLocation) -> [Int] {
            location.offset == nil ? location.path : Array(location.path.dropLast())
        }
        let a = elementPath(sourceStart)
        let b = elementPath(sourceEnd)
        let scope = Array(a.prefix(zip(a, b).prefix { $0 == $1 }.count))
        guard let scopeStart = chapter.sourceText.scalarOffset(of: DocumentLocation(path: scope)),
              let css = cssSelector(for: scope, in: chapter) else { return nil }
        var selectors: [AnnotationSelector] = [
            .css(value: css, refinedBy: [.textPosition(start: startScalar - scopeStart, end: endScalar - scopeStart, refinedBy: [])]),
        ]
        if !isPoint, endScalar > startScalar {
            let body = chapter.body
            let s = startScalar - chapter.bodyStart
            let e = endScalar - chapter.bodyStart
            if s >= 0, e <= body.count {
                selectors.append(TextSearch.quote(in: body, range: s..<e, step: quoteContextStep, limit: quoteContextLimit))
            }
        }
        return selectors
    }

    /// `#id > :nth-child(n) > …` from the nearest ancestor-or-self with a unique id, else from `body` (or the root
    /// element's name for documents without a body).
    static func cssSelector(for path: [Int], in chapter: ChapterText) -> String? {
        var anchor = path
        var anchorSelector: String?
        while true {
            guard let element = chapter.source.element(at: anchor) else { return nil }
            if let id = element.id, !id.isEmpty, chapter.idCounts[id] == 1 {
                anchorSelector = "#" + CSSSubset.escapeIdentifier(id)
                break
            }
            if anchor.isEmpty { break }
            anchor.removeLast()
        }
        if anchorSelector == nil {
            if path.starts(with: chapter.bodyPath), !chapter.bodyPath.isEmpty {
                anchor = chapter.bodyPath
                anchorSelector = "body"
            } else {
                anchor = []
                anchorSelector = CSSSubset.escapeIdentifier(chapter.source.root.name)
            }
        }
        var out = anchorSelector!
        var element = chapter.source.element(at: anchor)!
        for index in path.dropFirst(anchor.count) {
            var n = 0
            for child in element.children.prefix(index + 1) where child.element != nil { n += 1 }
            guard case .element(let child) = element.children[index] else { return nil }
            out += " > :nth-child(\(n))"
            element = child
        }
        return out
    }
}

/// Text search over code points for TextQuoteSelector and text fragments.
enum TextSearch {
    /// Start offsets of `needle` in `haystack`.
    static func occurrences(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], limit: Int = .max) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var out: [Int] = []
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var k = 1
                while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
                if k == needle.count {
                    out.append(i)
                    if out.count >= limit { break }
                }
            }
            i += 1
        }
        return out
    }

    /// A TextQuoteSelector for `range` of `body`: 32 code points of context on each side, grown by 32 until
    /// `prefix + exact + suffix` is unique in the body or 256 is reached (§5 step 5).
    static func quote(in body: [Unicode.Scalar], range: Range<Int>, step: Int, limit: Int) -> AnnotationSelector {
        let exact = Array(body[range])
        var length = step
        while true {
            let prefixStart = max(0, range.lowerBound - length)
            let suffixEnd = min(body.count, range.upperBound + length)
            let needle = Array(body[prefixStart..<suffixEnd])
            let unique = occurrences(of: needle, in: body, limit: 2).count <= 1
            if unique || length >= limit || (prefixStart == 0 && suffixEnd == body.count) {
                let prefix = Array(body[prefixStart..<range.lowerBound])
                let suffix = Array(body[range.upperBound..<suffixEnd])
                return .textQuote(
                    exact: string(exact),
                    prefix: prefix.isEmpty ? nil : string(prefix),
                    suffix: suffix.isEmpty ? nil : string(suffix)
                )
            }
            length += step
        }
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return String(s)
    }

    /// Finds `prefix + exact + suffix`, shortening the context from its far ends until it is found, down to `exact`
    /// alone. Among several matches the one nearest `near` (a body offset) wins, else the first.
    static func findQuote(exact: String, prefix: String?, suffix: String?, in body: [Unicode.Scalar], near: Int?) -> Range<Int>? {
        let e = Array(exact.unicodeScalars)
        let p = Array((prefix ?? "").unicodeScalars)
        let s = Array((suffix ?? "").unicodeScalars)
        var prefixLength = p.count
        var suffixLength = s.count
        while true {
            let usedPrefix = Array(p.suffix(prefixLength))
            let usedSuffix = Array(s.prefix(suffixLength))
            let starts = occurrences(of: usedPrefix + e + usedSuffix, in: body).map { $0 + usedPrefix.count }
            if !starts.isEmpty {
                let start: Int
                if let near {
                    start = starts.min { abs($0 - near) < abs($1 - near) }!
                } else {
                    start = starts[0]
                }
                // With context, a unique match is certain; without, the hint decides between repeats.
                return start..<(start + e.count)
            }
            if prefixLength == 0, suffixLength == 0 { return nil }
            prefixLength /= 2
            suffixLength /= 2
        }
    }

    /// A text directive `[prefix-,]start[,end][,-suffix]` (percent-encoded parts; the first `&`-separated
    /// directive only).
    static func findTextDirective(_ directive: String, in body: [Unicode.Scalar]) -> Range<Int>? {
        var value = directive
        if let amp = value.firstIndex(of: "&") { value = String(value[..<amp]) }
        if value.hasPrefix("text=") { value = String(value.dropFirst(5)) }
        var parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var prefix: String?
        var suffix: String?
        if let first = parts.first, first.hasSuffix("-") {
            prefix = String(first.dropLast()).removingPercentEncoding
            parts.removeFirst()
        }
        if let last = parts.last, last.hasPrefix("-") {
            suffix = String(last.dropFirst()).removingPercentEncoding
            parts.removeLast()
        }
        guard (1...2).contains(parts.count), let textStart = parts[0].removingPercentEncoding, !textStart.isEmpty else { return nil }
        let textEnd = parts.count == 2 ? parts[1].removingPercentEncoding : nil
        let startScalars = Array(textStart.unicodeScalars)
        let p = Array((prefix ?? "").unicodeScalars)
        let s = Array((suffix ?? "").unicodeScalars)
        // The prefix and suffix match with whitespace allowed between them and the text (the text fragment rules).
        func isSpace(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace }
        func prefixMatches(before start: Int) -> Bool {
            guard !p.isEmpty else { return true }
            var i = start
            while i > 0, isSpace(body[i - 1]) { i -= 1 }
            return i >= p.count && Array(body[(i - p.count)..<i]) == p
        }
        func suffixMatches(after end: Int) -> Bool {
            guard !s.isEmpty else { return true }
            var i = end
            while i < body.count, isSpace(body[i]) { i += 1 }
            return i + s.count <= body.count && Array(body[i..<(i + s.count)]) == s
        }
        for start in occurrences(of: startScalars, in: body) where prefixMatches(before: start) {
            var end = start + startScalars.count
            if let textEnd {
                let endScalars = Array(textEnd.unicodeScalars)
                guard !endScalars.isEmpty,
                      let found = occurrences(of: endScalars, in: Array(body[end...]), limit: 1).first else { continue }
                end = end + found + endScalars.count
            }
            if suffixMatches(after: end) { return start..<end }
        }
        return nil
    }
}
