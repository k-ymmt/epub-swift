import Foundation

/// How `AnnotationCodec.encode` writes a set (06-annotations §4.3).
public enum AnnotationEncodingMode: Sendable {
    /// The app's own storage: everything, including the origin (`epubswift:origin`) and full-precision dates.
    /// Positions are read back from the CFI selector without opening the book.
    case storage
    /// For other people and other apps.
    case export(ExportOptions)
}

/// What an exported file contains (06-annotations §4.3). The defaults share as little as possible: no creator,
/// dates rounded to the day, and the CFI kept (it repeats the position the other selectors give).
public struct ExportOptions: Hashable, Sendable {
    public enum TimestampPrecision: Hashable, Sendable {
        /// `created`, `modified` and `generated` at the start of their UTC day.
        case day
        case second
    }

    public var includesCreator: Bool
    public var timestampPrecision: TimestampPrecision
    /// Append `epubswift:CfiSelector` to each selector list (§2.2).
    public var includesCFI: Bool
    public var filter: AnnotationFilter

    public init(includesCreator: Bool = false, timestampPrecision: TimestampPrecision = .day, includesCFI: Bool = true, filter: AnnotationFilter = AnnotationFilter()) {
        self.includesCreator = includesCreator
        self.timestampPrecision = timestampPrecision
        self.includesCFI = includesCFI
        self.filter = filter
    }
}

/// Which annotations an export includes. A nil criterion does not filter. The default leaves out the publication's
/// embedded annotations (they are the publisher's, not the reader's).
public struct AnnotationFilter: Hashable, Sendable {
    public var motivations: Set<Annotation.Motivation>?
    public var colors: Set<HighlightColor>?
    public var styles: Set<HighlightStyle>?
    /// Annotations with at least one of these tags.
    public var tags: Set<String>?
    /// Creator ids. Annotations without a creator do not match a non-nil set.
    public var creatorIDs: Set<String>?
    public var origins: Set<Origin.Kind>

    public init(
        motivations: Set<Annotation.Motivation>? = nil,
        colors: Set<HighlightColor>? = nil,
        styles: Set<HighlightStyle>? = nil,
        tags: Set<String>? = nil,
        creatorIDs: Set<String>? = nil,
        origins: Set<Origin.Kind> = [.local, .imported]
    ) {
        self.motivations = motivations
        self.colors = colors
        self.styles = styles
        self.tags = tags
        self.creatorIDs = creatorIDs
        self.origins = origins
    }

    public func includes(_ annotation: Annotation) -> Bool {
        if let motivations, !motivations.contains(annotation.motivation) { return false }
        if let colors, !colors.contains(annotation.color) { return false }
        if let styles, !styles.contains(annotation.style) { return false }
        if let tags, Set(annotation.body?.tags ?? []).isDisjoint(with: tags) { return false }
        if let creatorIDs {
            guard let id = annotation.creator?.id, creatorIDs.contains(id) else { return false }
        }
        return origins.contains(annotation.origin.kind)
    }
}

/// Limits on what a read accepts (06-annotations §11). Exceeding the size, nesting or refinement limits fails the
/// read; extra annotations and over-long strings drop only the annotations concerned, with a warning.
public struct AnnotationImportLimits: Hashable, Sendable {
    /// Bytes of `annotations.json`.
    public var maxJSONBytes: Int
    public var maxAnnotations: Int
    public var maxNestingDepth: Int
    /// UTF-8 bytes of one string.
    public var maxStringBytes: Int
    /// Length of a `refinedBy` chain.
    public var maxRefinementDepth: Int
    /// Total uncompressed bytes of a `.annotations` ZIP.
    public var maxArchiveUncompressedBytes: Int64

    public init(maxJSONBytes: Int = 32 << 20, maxAnnotations: Int = 100_000, maxNestingDepth: Int = 32, maxStringBytes: Int = 1 << 20, maxRefinementDepth: Int = 8, maxArchiveUncompressedBytes: Int64 = 512 << 20) {
        self.maxJSONBytes = maxJSONBytes
        self.maxAnnotations = maxAnnotations
        self.maxNestingDepth = maxNestingDepth
        self.maxStringBytes = maxStringBytes
        self.maxRefinementDepth = maxRefinementDepth
        self.maxArchiveUncompressedBytes = maxArchiveUncompressedBytes
    }

    public static let `default` = AnnotationImportLimits()
}

/// Something a read skipped. The rest of the set was read.
public enum AnnotationImportWarning: Hashable, Sendable {
    /// An item that is not a valid annotation (index in `items`).
    case invalidAnnotation(index: Int, id: String?, reason: String)
    /// An item with a string longer than `maxStringBytes`.
    case stringTooLong(index: Int)
    /// Items after `maxAnnotations` were dropped.
    case tooManyAnnotations(limit: Int, dropped: Int)
    /// A later item with an id already used in the set was dropped (the specification's §7: ids are unique).
    case duplicateID(String)
}

public enum AnnotationCodecError: Error, Hashable, Sendable {
    case invalidJSON(String)
    /// The document is not an `AnnotationSet` (no `type: "AnnotationSet"`) or has no `items` array.
    case notAnAnnotationSet
    case notAnAnnotation(String)
    case tooLarge(bytes: Int, limit: Int)
    case nestingTooDeep(limit: Int)
    case refinementTooDeep(limit: Int)
    /// A string outside the items (in the set's own members) exceeded the limit.
    case stringTooLong(limit: Int)
}

/// JSON encoding and decoding of annotation sets (06-annotations §4, §9.1). Decoding does not open the book: a
/// position comes from the CFI selector when there is one, otherwise it stays `.unresolved` until
/// `AnnotationResolver` resolves the exchange selectors.
public enum AnnotationCodec {
    public static let contextURL = "https://www.w3.org/ns/epub-anno.jsonld"
    /// Namespace of this library's terms (`epubswift:CfiSelector`, `epubswift:origin`). An identifier only; kept
    /// even if the repository moves (§2.2).
    public static let namespace = "https://github.com/k-ymmt/epub-swift/ns/annotations#"
    public static let namespacePrefix = "epubswift"
    /// Media type of an annotation set as JSON-LD (the specification's §5).
    public static let jsonMediaType = #"application/ld+json;profile="http://www.w3.org/ns/anno.jsonld""#

    static let cfiSelectorType = "epubswift:CfiSelector"
    static let originKey = "epubswift:origin"
    /// Stands in for a string over the limit while parsing, so the item holding it can be dropped.
    static let overlongMarker = "\u{FFFF}epubswift-overlong-string\u{FFFF}"

    // MARK: Decoding

    public static func decode(_ data: Data, limits: AnnotationImportLimits = .default) throws -> (AnnotationSet, [AnnotationImportWarning]) {
        let root = try parse(data, limits: limits)
        guard case .object(let object) = root, hasType(object, "AnnotationSet"), case .array(let rawItems)? = object["items"] else {
            throw AnnotationCodecError.notAnAnnotationSet
        }
        var warnings: [AnnotationImportWarning] = []
        var set = AnnotationSet(id: "", items: [])
        set.id = object["id"]?.stringValue ?? AnnotationSet.newID()
        set.generated = object["generated"]?.stringValue.flatMap(AnnotationDate.parse)
        let context = readContext(object["@context"])
        set.defaultLanguage = context.language
        set.defaultDirection = context.direction
        var setLevel = object
        setLevel["items"] = nil
        guard !contains(.object(setLevel), overlong) else { throw AnnotationCodecError.stringTooLong(limit: limits.maxStringBytes) }
        if case .object(let about)? = object["about"] {
            set.about = readAbout(about)
        } else if let about = object["about"] {
            set.extensions["about"] = about
        }
        set.extensions.merge(unknownMembers(of: object, known: ["@context", "id", "type", "generated", "about", "items"])) { a, _ in a }
        if case .array(let contextArray)? = object["@context"], contextArray.count > 2 || context.hasOtherMembers {
            // Contexts this library does not write itself are kept as read.
            set.extensions["@context"] = object["@context"]
        }

        var items = rawItems
        if items.count > limits.maxAnnotations {
            warnings.append(.tooManyAnnotations(limit: limits.maxAnnotations, dropped: items.count - limits.maxAnnotations))
            items = Array(items.prefix(limits.maxAnnotations))
        }
        var seen: Set<String> = []
        let importedAt = Annotation.now()
        for (index, item) in items.enumerated() {
            if contains(item, overlong) {
                warnings.append(.stringTooLong(index: index))
                continue
            }
            do {
                var annotation = try readAnnotation(item, limits: limits)
                if annotation.origin == .local, item.objectValue?[originKey] == nil {
                    annotation.origin = .imported(setID: set.id, importedAt: importedAt)
                }
                guard seen.insert(annotation.id).inserted else {
                    warnings.append(.duplicateID(annotation.id))
                    continue
                }
                set.items.append(annotation)
            } catch let error as AnnotationCodecError where error == .refinementTooDeep(limit: limits.maxRefinementDepth) {
                throw error
            } catch {
                let id = item.objectValue?["id"]?.stringValue
                warnings.append(.invalidAnnotation(index: index, id: id, reason: (error as? ItemError)?.reason ?? String(describing: error)))
            }
        }
        return (set, warnings)
    }

    /// Decodes a single annotation document (an `Annotation` with its own `@context`).
    public static func decodeAnnotation(_ data: Data, limits: AnnotationImportLimits = .default) throws -> Annotation {
        let root = try parse(data, limits: limits)
        guard !contains(root, overlong) else { throw AnnotationCodecError.stringTooLong(limit: limits.maxStringBytes) }
        do {
            return try readAnnotation(root, limits: limits)
        } catch let error as ItemError {
            throw AnnotationCodecError.notAnAnnotation(error.reason)
        }
    }

    private static func overlong(_ value: JSONValue) -> Bool {
        value == .string(overlongMarker)
    }

    private static func parse(_ data: Data, limits: AnnotationImportLimits) throws -> JSONValue {
        guard data.count <= limits.maxJSONBytes else { throw AnnotationCodecError.tooLarge(bytes: data.count, limit: limits.maxJSONBytes) }
        do {
            return try JSONParser.parse(data, limits: JSONParseLimits(maxDepth: limits.maxNestingDepth, maxStringBytes: limits.maxStringBytes, overlongMarker: overlongMarker))
        } catch let error as JSONParseError where error.isDepthLimit {
            throw AnnotationCodecError.nestingTooDeep(limit: limits.maxNestingDepth)
        } catch {
            throw AnnotationCodecError.invalidJSON(String(describing: error))
        }
    }

    private static func contains(_ value: JSONValue, _ predicate: (JSONValue) -> Bool) -> Bool {
        if predicate(value) { return true }
        switch value {
        case .array(let values): return values.contains { contains($0, predicate) }
        case .object(let object): return object.keys.contains(overlongMarker) || object.values.contains { contains($0, predicate) }
        default: return false
        }
    }

    struct ItemError: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// `type` equal to `name`, or an array containing it.
    private static func hasType(_ object: JSONObject, _ name: String) -> Bool {
        switch object["type"] {
        case .string(let s)?: return s == name
        case .array(let values)?: return values.contains(.string(name))
        default: return false
        }
    }

    private static func unknownMembers(of object: JSONObject, known: Set<String>) -> JSONObject {
        object.filter { !known.contains($0.key) }
    }

    private struct Context {
        var language: String?
        var direction: TextDirection?
        var hasOtherMembers = false
    }

    private static func readContext(_ value: JSONValue?) -> Context {
        var context = Context()
        guard case .array(let values)? = value else { return context }
        for case .object(let object) in values {
            if let language = object["@language"]?.stringValue { context.language = language }
            if let direction = object["@direction"]?.stringValue { context.direction = TextDirection(rawValue: direction) }
            let known: Set<String> = ["@language", "@direction", namespacePrefix]
            if object.keys.contains(where: { !known.contains($0) }) || (object[namespacePrefix] != nil && object[namespacePrefix] != .string(namespace)) {
                context.hasOtherMembers = true
            }
        }
        return context
    }

    private static func readText(_ value: JSONValue?) -> LocalizableText? {
        switch value {
        case .string(let s)?:
            return LocalizableText(s)
        case .object(let object)?:
            guard let text = (object["text"] ?? object["@value"] ?? object["value"])?.stringValue else { return nil }
            let language = (object["language"] ?? object["@language"])?.stringValue
            let direction = (object["direction"] ?? object["@direction"])?.stringValue.flatMap(TextDirection.init)
            return LocalizableText(text, language: language, direction: direction)
        case .array(let values)?:
            return values.lazy.compactMap { readText($0) }.first
        default:
            return nil
        }
    }

    private static func readAbout(_ object: JSONObject) -> AnnotationSet.About {
        var about = AnnotationSet.About()
        about.title = readText(object["dc:title"])
        switch object["dc:creator"] {
        case .array(let values)?: about.creators = values.compactMap { readText($0) }
        case let value?: about.creators = readText(value).map { [$0] } ?? []
        case nil: break
        }
        about.publisher = readText(object["dc:publisher"])
        about.date = object["dc:date"]?.stringValue
        about.identifier = object["dc:identifier"]?.stringValue
        about.extensions = unknownMembers(of: object, known: ["dc:title", "dc:creator", "dc:publisher", "dc:date", "dc:identifier"])
        // Members that did not parse are kept as read.
        for key in ["dc:title", "dc:publisher", "dc:date", "dc:identifier"] where object[key] != nil {
            let parsed: Bool
            switch key {
            case "dc:title": parsed = about.title != nil
            case "dc:publisher": parsed = about.publisher != nil
            case "dc:date": parsed = about.date != nil
            default: parsed = about.identifier != nil
            }
            if !parsed { about.extensions[key] = object[key] }
        }
        return about
    }

    static func readAnnotation(_ value: JSONValue, limits: AnnotationImportLimits) throws -> Annotation {
        guard case .object(let object) = value else { throw ItemError("not an object") }
        if object["type"] != nil, !hasType(object, "Annotation") { throw ItemError("type is not Annotation") }
        guard let id = object["id"]?.stringValue, !id.isEmpty else { throw ItemError("missing id") }
        var extensions = unknownMembers(of: object, known: ["@context", "id", "type", "motivation", "created", "modified", "creator", "target", "body", originKey])

        let motivation: Annotation.Motivation
        let motivationValue: String? = {
            switch object["motivation"] {
            case .string(let s)?: return s
            case .array(let values)?: return values.compactMap(\.stringValue).first
            default: return nil
            }
        }()
        switch motivationValue {
        case nil: motivation = .bookmarking
        case "bookmarking"?: motivation = .bookmarking
        default:
            // "highlighting", and motivations the specification does not use ("commenting", …): an annotation
            // with a body on a range.
            motivation = .highlighting
            if motivationValue != "highlighting" { extensions["motivation"] = object["motivation"] }
        }

        let modified = object["modified"]?.stringValue.flatMap(AnnotationDate.parse)
        guard let created = object["created"]?.stringValue.flatMap(AnnotationDate.parse) ?? modified else {
            throw ItemError("missing or invalid created")
        }

        var creator: Creator?
        if let value = object["creator"] {
            let first: JSONValue? = value.arrayValue?.first ?? value
            if case .object(let c)? = first, let creatorID = c["id"]?.stringValue {
                let kind: Creator.Kind = {
                    switch c["type"] {
                    case .string(let s)?: return Creator.Kind(rawValue: s) ?? .person
                    case .array(let values)?: return values.compactMap { $0.stringValue.flatMap(Creator.Kind.init) }.first ?? .person
                    default: return .person
                    }
                }()
                creator = Creator(id: creatorID, kind: kind, name: readText(c["name"]), extensions: unknownMembers(of: c, known: ["id", "type", "name"]))
            }
            if creator == nil || value.arrayValue.map({ $0.count > 1 }) == true {
                // Kept as read when it did not parse, or when there were several.
                extensions["creator"] = value
            }
        }

        guard let targetValue = object["target"] else { throw ItemError("missing target") }
        var target: Target
        switch targetValue {
        case .array(let values):
            guard let first = values.first else { throw ItemError("empty target") }
            target = try readTarget(first, motivation: motivation, limits: limits)
            if values.count > 1 { target.extensions[additionalKey] = .array(Array(values.dropFirst())) }
        default:
            target = try readTarget(targetValue, motivation: motivation, limits: limits)
        }

        var body: Body?
        if let bodyValue = object["body"] {
            let values = bodyValue.arrayValue ?? [bodyValue]
            if let first = values.first {
                body = readBody(first)
                if body == nil { extensions["body"] = bodyValue }
                else if values.count > 1 { body?.extensions[additionalKey] = .array(Array(values.dropFirst())) }
            }
        }

        var origin = Origin.local
        if case .object(let o)? = object[originKey] {
            switch o["kind"]?.stringValue {
            case "imported"?:
                origin = .imported(setID: o["set"]?.stringValue ?? "", importedAt: o["importedAt"]?.stringValue.flatMap(AnnotationDate.parse) ?? created)
            case "publication"?:
                origin = .publication
            default:
                origin = .local
            }
        }

        return Annotation(id: id, motivation: motivation, created: created, modified: modified, creator: creator, target: target, body: body, origin: origin, extensions: extensions)
    }

    /// Key under which the elements after the first of a `target` / `body` array are kept (in the first element's
    /// `extensions`), so the array is written back whole (§2.3: one each, extra ones kept).
    static let additionalKey = "\u{0}additional"

    private static func readTarget(_ value: JSONValue, motivation: Annotation.Motivation, limits: AnnotationImportLimits) throws -> Target {
        let object: JSONObject
        switch value {
        case .string(let s): object = ["source": .string(s)]
        case .object(let o): object = o
        default: throw ItemError("invalid target")
        }
        guard let source = object["source"]?.stringValue, !source.isEmpty else { throw ItemError("missing target source") }
        let extensions = unknownMembers(of: object, known: ["source", "selector"])
        let rawSelectors: [JSONValue]
        switch object["selector"] {
        case nil, .null?: rawSelectors = []
        case .array(let values)?: rawSelectors = values
        case let single?: rawSelectors = [single]
        }
        var selectors: [Selector] = []
        for raw in rawSelectors {
            selectors.append(try readSelector(raw, depth: 0, limits: limits))
        }
        var position: Target.Position = selectors.isEmpty ? .resource : .unresolved
        if let cfiString = selectors.lazy.compactMap({ selector -> String? in if case .cfi(let s) = selector { return s } else { return nil } }).first {
            position = Self.position(fromCFI: cfiString, motivation: motivation) ?? .unresolved
        }
        let onlyCFI = selectors.allSatisfy(\.isCFI)
        return Target(
            source: AnnotationPath.decodedSource(source),
            position: position,
            originalSelectors: onlyCFI ? nil : selectors,
            originalSelectorJSON: onlyCFI ? nil : rawSelectors,
            extensions: extensions
        )
    }

    /// A bookmark is a point (a range's start, as the specification says), a highlight a range.
    static func position(fromCFI string: String, motivation: Annotation.Motivation) -> Target.Position? {
        guard let range = CFIRange(string) else { return nil }
        switch motivation {
        case .bookmarking: return .point(range.start)
        case .highlighting: return .range(range)
        }
    }

    static func readSelector(_ value: JSONValue, depth: Int, limits: AnnotationImportLimits) throws -> Selector {
        guard depth <= limits.maxRefinementDepth else { throw AnnotationCodecError.refinementTooDeep(limit: limits.maxRefinementDepth) }
        guard case .object(let object) = value else { throw ItemError("invalid selector") }
        func refinements() throws -> [Selector] {
            switch object["refinedBy"] {
            case nil, .null?: return []
            case .array(let values)?: return try values.map { try readSelector($0, depth: depth + 1, limits: limits) }
            case let single?: return [try readSelector(single, depth: depth + 1, limits: limits)]
            }
        }
        let type: String? = {
            switch object["type"] {
            case .string(let s)?: return s
            case .array(let values)?: return values.compactMap(\.stringValue).first
            default: return nil
            }
        }()
        switch type {
        case "FragmentSelector"?:
            guard let v = object["value"]?.stringValue else { break }
            return .fragment(value: v, conformsTo: object["conformsTo"]?.stringValue, refinedBy: try refinements())
        case "CssSelector"?:
            guard let v = object["value"]?.stringValue else { break }
            return .css(value: v, refinedBy: try refinements())
        case "TextPositionSelector"?:
            guard let start = object["start"]?.nonNegativeIntegerValue, let end = object["end"]?.nonNegativeIntegerValue else { break }
            return .textPosition(start: start, end: end, refinedBy: try refinements())
        case "TextQuoteSelector"?:
            guard let exact = object["exact"]?.stringValue else { break }
            return .textQuote(exact: exact, prefix: object["prefix"]?.stringValue, suffix: object["suffix"]?.stringValue)
        case cfiSelectorType?, "CfiSelector"?, namespace + "CfiSelector":
            guard let v = object["value"]?.stringValue else { break }
            return .cfi(v)
        default:
            break
        }
        // Unknown types, and known types missing a required member, are kept as read and ignored by resolution.
        _ = try refinements() // the refinement limit applies to these too
        return .unknown(object)
    }

    private static func readBody(_ value: JSONValue) -> Body? {
        guard case .object(let object) = value else { return nil }
        var body = Body()
        let type: String? = {
            switch object["type"] {
            case .string(let s)?: return s
            case .array(let values)?: return values.compactMap(\.stringValue).first
            default: return nil
            }
        }()
        var known: Set<String> = ["type", "format", "color", "highlight", "tags"]
        switch type {
        case "TextualBody"?, nil:
            known.insert("value")
            if let text = readText(object["value"]), !text.text.isEmpty {
                body.content = .text(text)
            }
            if type == nil, object["value"] == nil, object["id"] != nil { return nil }
        case "Image"?, "Audio"?, "Video"?:
            known.insert("id")
            guard let url = object["id"]?.stringValue else { return nil }
            body.content = type == "Image" ? .image(url) : type == "Audio" ? .audio(url) : .video(url)
        default:
            return nil
        }
        body.format = object["format"]?.stringValue
        if let color = object["color"]?.stringValue { body.color = HighlightColor(rawValue: color) }
        if let style = object["highlight"]?.stringValue { body.style = HighlightStyle(rawValue: style) }
        switch object["tags"] {
        case .array(let values)?: body.tags = values.compactMap(\.stringValue)
        case .string(let s)?: body.tags = [s]
        default: break
        }
        body.extensions = unknownMembers(of: object, known: known)
        return body
    }

    // MARK: Encoding

    public static func encode(_ set: AnnotationSet, mode: AnnotationEncodingMode) throws -> Data {
        JSONWriter.data(setNode(set, mode: mode))
    }

    /// Encodes one annotation as a document of its own, with `@context`.
    public static func encode(_ annotation: Annotation, mode: AnnotationEncodingMode, defaultLanguage: String? = nil, defaultDirection: TextDirection? = nil) throws -> Data {
        JSONWriter.data(.object(annotationMembers(annotation, mode: mode, context: contextNode(language: defaultLanguage, direction: defaultDirection, extensions: [:]))))
    }

    static func setNode(_ set: AnnotationSet, mode: AnnotationEncodingMode) -> JSONWriter.Node {
        var members = JSONWriter.Members()
        members.set("@context", contextNode(language: set.defaultLanguage, direction: set.defaultDirection, extensions: set.extensions))
        members.set("id", .string(set.id))
        members.set("type", .string("AnnotationSet"))
        if let generated = set.generated {
            members.set("generated", .string(format(generated, mode: mode)))
        }
        members.set("about", .object(aboutMembers(set.about)))
        let items = set.items.filter { annotation in
            if case .export(let options) = mode { return options.filter.includes(annotation) }
            return true
        }
        members.set("items", .array(items.map { .object(annotationMembers($0, mode: mode, context: nil)) }))
        members.append(extensions: set.extensions.filter { $0.key != "@context" })
        return .object(members)
    }

    private static func contextNode(language: String?, direction: TextDirection?, extensions: JSONObject) -> JSONWriter.Node {
        if let kept = extensions["@context"] { return .value(kept) }
        var local = JSONWriter.Members()
        local.set(namespacePrefix, .string(namespace))
        if let language { local.set("@language", .string(language)) }
        if let direction { local.set("@direction", .string(direction.rawValue)) }
        return .array([.string(contextURL), .object(local)])
    }

    private static func format(_ date: Date, mode: AnnotationEncodingMode) -> String {
        switch mode {
        case .storage: return AnnotationDate.format(date, precision: .millisecond)
        case .export(let options):
            return AnnotationDate.format(date, precision: options.timestampPrecision == .day ? .day : .second)
        }
    }

    private static func textNode(_ text: LocalizableText) -> JSONWriter.Node {
        guard text.language != nil || text.direction != nil else { return .string(text.text) }
        var members = JSONWriter.Members()
        members.set("text", .string(text.text))
        if let language = text.language { members.set("language", .string(language)) }
        if let direction = text.direction { members.set("direction", .string(direction.rawValue)) }
        return .object(members)
    }

    private static func aboutMembers(_ about: AnnotationSet.About) -> JSONWriter.Members {
        var members = JSONWriter.Members()
        members.set("dc:title", about.title.map(textNode))
        if !about.creators.isEmpty { members.set("dc:creator", .array(about.creators.map(textNode))) }
        members.set("dc:publisher", about.publisher.map(textNode))
        members.set("dc:date", about.date.map { .string($0) })
        members.set("dc:identifier", about.identifier.map { .string($0) })
        members.append(extensions: about.extensions)
        return members
    }

    static func annotationMembers(_ annotation: Annotation, mode: AnnotationEncodingMode, context: JSONWriter.Node?) -> JSONWriter.Members {
        var members = JSONWriter.Members()
        members.set("@context", context)
        members.set("id", .string(annotation.id))
        members.set("type", .string("Annotation"))
        // An unknown motivation read from a file is written back as read.
        members.set("motivation", annotation.extensions["motivation"].map { .value($0) } ?? .string(annotation.motivation.rawValue))
        members.set("created", .string(format(annotation.created, mode: mode)))
        if let modified = annotation.modified { members.set("modified", .string(format(modified, mode: mode))) }
        let includesCreator: Bool
        let includesCFI: Bool
        switch mode {
        case .storage:
            includesCreator = true
            includesCFI = true
        case .export(let options):
            includesCreator = options.includesCreator
            includesCFI = options.includesCFI
        }
        if includesCreator {
            if let creator = annotation.creator {
                members.set("creator", .object(creatorMembers(creator)))
            }
        }
        members.set("target", targetNode(annotation.target, includesCFI: includesCFI))
        if let body = annotation.body, shouldWriteBody(body, motivation: annotation.motivation) {
            members.set("body", bodyNode(body))
        } else if annotation.motivation == .highlighting, annotation.body == nil, annotation.extensions["body"] == nil {
            // A highlight always carries its look (§2.3).
            members.set("body", bodyNode(Body()))
        }
        if case .storage = mode {
            members.set(originKey, .object(originMembers(annotation.origin)))
        }
        var extensions = annotation.extensions
        extensions["motivation"] = nil
        if !includesCreator { extensions["creator"] = nil }
        members.append(extensions: extensions)
        return members
    }

    private static func shouldWriteBody(_ body: Body, motivation: Annotation.Motivation) -> Bool {
        if motivation == .highlighting { return true }
        return body.content != nil || !body.tags.isEmpty || body.color != .yellow || body.style != .solid || body.format != nil || !body.extensions.isEmpty
    }

    private static func creatorMembers(_ creator: Creator) -> JSONWriter.Members {
        var members = JSONWriter.Members()
        members.set("id", .string(creator.id))
        members.set("type", .string(creator.kind.rawValue))
        members.set("name", creator.name.map(textNode))
        members.append(extensions: creator.extensions)
        return members
    }

    private static func originMembers(_ origin: Origin) -> JSONWriter.Members {
        var members = JSONWriter.Members()
        members.set("kind", .string(origin.kind.rawValue))
        if case .imported(let setID, let importedAt) = origin {
            members.set("set", .string(setID))
            members.set("importedAt", .string(AnnotationDate.format(importedAt, precision: .millisecond)))
        }
        return members
    }

    private static func targetNode(_ target: Target, includesCFI: Bool) -> JSONWriter.Node {
        var members = JSONWriter.Members()
        members.set("source", .string(AnnotationPath.encodedSource(target.source)))
        var selectors: [JSONWriter.Node] = []
        if let raw = target.originalSelectorJSON {
            selectors = raw.filter { !isCFISelectorJSON($0) }.map { .value($0) }
        } else if let generated = target.generatedSelectors {
            selectors = generated.filter { !$0.isCFI }.map(selectorNode)
        }
        if includesCFI, let cfi = target.position.cfiString {
            selectors.append(selectorNode(.cfi(cfi)))
        }
        if !selectors.isEmpty { members.set("selector", .array(selectors)) }
        var extensions = target.extensions
        extensions[additionalKey] = nil
        members.append(extensions: extensions)
        guard case .array(let additional)? = target.extensions[additionalKey] else { return .object(members) }
        return .array([.object(members)] + additional.map { .value($0) })
    }

    private static func isCFISelectorJSON(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value, let type = object["type"]?.stringValue else { return false }
        return type == cfiSelectorType || type == "CfiSelector" || type == namespace + "CfiSelector"
    }

    static func selectorNode(_ selector: Selector) -> JSONWriter.Node {
        var members = JSONWriter.Members()
        func refinements(_ list: [Selector]) {
            guard !list.isEmpty else { return }
            // One refinement as an object, several as an array (the Web Annotation convention, §4.1).
            members.set("refinedBy", list.count == 1 ? selectorNode(list[0]) : .array(list.map(selectorNode)))
        }
        switch selector {
        case .fragment(let value, let conformsTo, let refinedBy):
            members.set("type", .string("FragmentSelector"))
            members.set("value", .string(value))
            members.set("conformsTo", conformsTo.map { .string($0) })
            refinements(refinedBy)
        case .css(let value, let refinedBy):
            members.set("type", .string("CssSelector"))
            members.set("value", .string(value))
            refinements(refinedBy)
        case .textPosition(let start, let end, let refinedBy):
            members.set("type", .string("TextPositionSelector"))
            members.set("start", .value(.number(Double(start))))
            members.set("end", .value(.number(Double(end))))
            refinements(refinedBy)
        case .textQuote(let exact, let prefix, let suffix):
            members.set("type", .string("TextQuoteSelector"))
            members.set("exact", .string(exact))
            members.set("prefix", prefix.map { .string($0) })
            members.set("suffix", suffix.map { .string($0) })
        case .cfi(let value):
            members.set("type", .string(cfiSelectorType))
            members.set("value", .string(value))
        case .unknown(let object):
            return .value(.object(object))
        }
        return .object(members)
    }

    private static func bodyNode(_ body: Body) -> JSONWriter.Node {
        var members = JSONWriter.Members()
        switch body.content {
        case .text(let text)?:
            members.set("type", .string("TextualBody"))
            members.set("value", textNode(text))
        case nil:
            members.set("type", .string("TextualBody"))
            members.set("value", .string(""))
        case .image(let url)?:
            members.set("type", .string("Image"))
            members.set("id", .string(url))
        case .audio(let url)?:
            members.set("type", .string("Audio"))
            members.set("id", .string(url))
        case .video(let url)?:
            members.set("type", .string("Video"))
            members.set("id", .string(url))
        }
        members.set("format", body.format.map { .string($0) })
        members.set("color", .string(body.color.rawValue))
        members.set("highlight", .string(body.style.rawValue))
        if !body.tags.isEmpty { members.set("tags", .array(body.tags.map { .string($0) })) }
        var extensions = body.extensions
        extensions[additionalKey] = nil
        members.append(extensions: extensions)
        guard case .array(let additional)? = body.extensions[additionalKey] else { return .object(members) }
        return .array([.object(members)] + additional.map { .value($0) })
    }
}
