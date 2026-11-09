import Foundation

/// An EPUB Canonical Fragment Identifier (EPUB CFI 1.1 subset, docs/design/01-core.md §5).
///
/// `epubcfi(/6/4[chap01]!/4/2/1:10[before,after])`: the steps before `!` address the spine item in the package
/// document (`spineSteps`), the steps after it address a node in that document (`steps`), `:10` is a character
/// offset into a text node and `[before,after]` a text location assertion used to re-find the position when the
/// structure has changed.
///
/// Rules shared with the JavaScript implementation in `reader.js`:
/// - even step indices are elements (`/2` = first element child), odd indices are the text between elements
///   (`/1` = text before the first element child); adjacent text, CDATA and comments count as one text node;
/// - character offsets count UTF-16 code units (WebKit's DOM offsets), M3 decision;
/// - the text assertion is taken from the text node itself: up to 10 code units on each side of the offset;
/// - temporal (`~`) and spatial (`@`) offsets and side bias (`;s=`) are parsed and dropped.
public struct CFI: Hashable, Codable, Sendable, Comparable, LosslessStringConvertible {
    /// One path step: `/index[id]`.
    public struct Step: Hashable, Codable, Sendable {
        public var index: Int
        /// ID assertion of an element step.
        public var id: String?

        public init(index: Int, id: String? = nil) {
            self.index = index
            self.id = id
        }

        /// Even indices are element steps, odd indices text steps.
        public var isElement: Bool { index % 2 == 0 }
    }

    /// Text around the character offset (`[before,after]`), for re-resolution.
    public struct TextAssertion: Hashable, Codable, Sendable {
        public var before: String
        public var after: String

        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }

        public var isEmpty: Bool { before.isEmpty && after.isEmpty }
    }

    /// Steps addressing the spine item in the package document (`/6/4[chap01]`). Normally two steps.
    public var spineSteps: [Step]
    /// Steps addressing a node in the content document, from the children of the root element.
    public var steps: [Step]
    /// UTF-16 offset into the text node addressed by the last (odd) step.
    public var characterOffset: Int?
    public var textAssertion: TextAssertion?

    public init(spineSteps: [Step], steps: [Step], characterOffset: Int? = nil, textAssertion: TextAssertion? = nil) {
        self.spineSteps = spineSteps
        self.steps = steps
        self.characterOffset = characterOffset
        self.textAssertion = textAssertion
    }

    /// Spine index derived from the last spine step (`/4` → 1). Does not consult the package document; use
    /// `Publication.spineIndex(of:)` when the ID assertion or a non-standard package layout matters.
    public var spineIndex: Int {
        guard let last = spineSteps.last else { return 0 }
        return max(0, last.index / 2 - 1)
    }

    /// The position without its assertions (for comparisons that ignore how it was generated).
    public var withoutAssertions: CFI {
        CFI(spineSteps: spineSteps.map { Step(index: $0.index) }, steps: steps.map { Step(index: $0.index) }, characterOffset: characterOffset)
    }

    // MARK: - String form

    public init?(_ description: String) {
        guard let parsed = CFIParser.parse(description), parsed.count == 1 else { return nil }
        self = parsed[0]
    }

    public var description: String {
        "epubcfi(" + path + ")"
    }

    /// The path inside `epubcfi(...)`.
    var path: String {
        var out = CFI.render(steps: spineSteps)
        if !spineSteps.isEmpty { out += "!" }
        out += localPath
        return out
    }

    /// Steps, offset and assertion of the document part (no spine).
    var localPath: String {
        var out = CFI.render(steps: steps)
        out += CFI.renderTermination(offset: characterOffset, assertion: textAssertion)
        return out
    }

    /// `/6/4[id]...` for a list of steps.
    public static func render(steps: [Step]) -> String {
        var out = ""
        for step in steps {
            out += "/\(step.index)"
            if let id = step.id, !id.isEmpty { out += "[\(escape(id))]" }
        }
        return out
    }

    static func renderTermination(offset: Int?, assertion: TextAssertion?) -> String {
        guard let offset else { return "" }
        var out = ":\(offset)"
        if let assertion, !assertion.isEmpty {
            out += "[\(escape(assertion.before)),\(escape(assertion.after))]"
        }
        return out
    }

    /// `^` escapes the characters with meaning inside an assertion (EPUB CFI §3.1.2).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for c in s {
            if "^[](),;=".contains(c) { out.append("^") }
            out.append(c)
        }
        return out
    }

    // MARK: - Codable (single string)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let cfi = CFI(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an EPUB CFI: \(string)")
        }
        self = cfi
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Comparable

    /// Document order: spine index, then the step indices lexicographically (a shorter path that is a prefix of
    /// another comes first), then the character offset (nil = 0). Assertions only break ties so that the order is
    /// consistent with `==`.
    public static func < (lhs: CFI, rhs: CFI) -> Bool {
        if lhs.spineIndex != rhs.spineIndex { return lhs.spineIndex < rhs.spineIndex }
        let position = comparePosition(lhs, rhs)
        if position != 0 { return position < 0 }
        return lhs.description < rhs.description
    }

    /// -1, 0 or 1 comparing only the positions (steps and offset, within the same spine item).
    public static func comparePosition(_ lhs: CFI, _ rhs: CFI) -> Int {
        if lhs.spineIndex != rhs.spineIndex { return lhs.spineIndex < rhs.spineIndex ? -1 : 1 }
        for (a, b) in zip(lhs.steps, rhs.steps) where a.index != b.index {
            return a.index < b.index ? -1 : 1
        }
        if lhs.steps.count != rhs.steps.count {
            // The longer path descends into a child of the node the shorter path ends at. A text/element child
            // sits after the start of its parent, so the parent (shorter path) compares as earlier.
            return lhs.steps.count < rhs.steps.count ? -1 : 1
        }
        let lo = lhs.characterOffset ?? 0
        let ro = rhs.characterOffset ?? 0
        if lo != ro { return lo < ro ? -1 : 1 }
        return 0
    }
}

/// A range between two positions in the same spine item (`epubcfi(parent,start,end)`).
public struct CFIRange: Hashable, Codable, Sendable, LosslessStringConvertible {
    public var start: CFI
    public var end: CFI

    public init(start: CFI, end: CFI) {
        self.start = start
        self.end = end
    }

    /// A collapsed range at one position.
    public init(at cfi: CFI) {
        self.start = cfi
        self.end = cfi
    }

    public var spineIndex: Int { start.spineIndex }
    public var isCollapsed: Bool { CFI.comparePosition(start, end) == 0 }

    /// Whether `cfi` lies within the range (positions only, inclusive of the start, exclusive of the end unless
    /// the range is collapsed).
    public func contains(_ cfi: CFI) -> Bool {
        guard cfi.spineIndex == spineIndex else { return false }
        let fromStart = CFI.comparePosition(start, cfi)
        let toEnd = CFI.comparePosition(cfi, end)
        return fromStart <= 0 && (isCollapsed ? toEnd <= 0 : toEnd < 0)
    }

    public init?(_ description: String) {
        guard let parsed = CFIParser.parse(description) else { return nil }
        switch parsed.count {
        case 1: self.init(at: parsed[0])
        case 2: self.init(start: parsed[0], end: parsed[1])
        default: return nil
        }
    }

    /// `epubcfi(parent,start,end)` with the longest common parent path. A collapsed range renders as a point.
    public var description: String {
        if start == end { return start.description }
        guard start.spineSteps == end.spineSteps else {
            // Ranges across spine items are not valid CFI; render the start.
            return start.description
        }
        var common = 0
        while common < start.steps.count, common < end.steps.count, start.steps[common] == end.steps[common] {
            common += 1
        }
        // Each local path keeps at least one step when it has any.
        if common == start.steps.count, !start.steps.isEmpty { common -= 1 }
        if common == end.steps.count, !end.steps.isEmpty { common = min(common, end.steps.count - 1) }
        let parent = CFI(spineSteps: start.spineSteps, steps: Array(start.steps.prefix(common)))
        let startLocal = CFI(spineSteps: [], steps: Array(start.steps.dropFirst(common)), characterOffset: start.characterOffset, textAssertion: start.textAssertion)
        let endLocal = CFI(spineSteps: [], steps: Array(end.steps.dropFirst(common)), characterOffset: end.characterOffset, textAssertion: end.textAssertion)
        return "epubcfi(\(parent.path),\(startLocal.localPath),\(endLocal.localPath))"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let range = CFIRange(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an EPUB CFI range: \(string)")
        }
        self = range
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Parser

/// Parses `epubcfi(...)` into one CFI (a point) or two (a range).
enum CFIParser {
    private enum Component {
        case step(CFI.Step)
        case indirection
        case offset(Int, CFI.TextAssertion?)
    }

    /// Returns `[point]` or `[start, end]`, nil when the string is not a CFI this library understands.
    static func parse(_ string: String) -> [CFI]? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("epubcfi("), trimmed.hasSuffix(")") else { return nil }
        let inner = Array(trimmed.dropFirst("epubcfi(".count).dropLast())
        guard !inner.isEmpty else { return nil }
        let parts = splitTopLevel(inner)
        switch parts.count {
        case 1:
            guard let components = parseComponents(parts[0]) else { return nil }
            return assemble(components).map { [$0] }
        case 3:
            guard let parent = parseComponents(parts[0]), let s = parseComponents(parts[1]), let e = parseComponents(parts[2]),
                  !s.isEmpty, !e.isEmpty, !parent.isEmpty else { return nil }
            guard let start = assemble(parent + s), let end = assemble(parent + e) else { return nil }
            return [start, end]
        default:
            return nil
        }
    }

    /// Splits on `,` outside brackets (and not escaped).
    private static func splitTopLevel(_ chars: [Character]) -> [[Character]] {
        var parts: [[Character]] = [[]]
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "^", i + 1 < chars.count {
                parts[parts.count - 1].append(c)
                parts[parts.count - 1].append(chars[i + 1])
                i += 2
                continue
            }
            if c == "[" { depth += 1 } else if c == "]" { depth = max(0, depth - 1) }
            if c == ",", depth == 0 {
                parts.append([])
            } else {
                parts[parts.count - 1].append(c)
            }
            i += 1
        }
        return parts
    }

    private static func parseComponents(_ chars: [Character]) -> [Component]? {
        var components: [Component] = []
        var i = 0
        func readInteger() -> Int? {
            var digits = ""
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { digits.append(chars[i]); i += 1 }
            return digits.isEmpty ? nil : Int(digits)
        }
        func readNumber() -> Bool {
            var any = false
            while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." { i += 1; any = true }
            return any
        }
        /// Reads `[...]` (the opening bracket at `i`) into unescaped comma-separated values; `;` parameters dropped.
        func readAssertion() -> [String]? {
            guard i < chars.count, chars[i] == "[" else { return nil }
            i += 1
            var values: [String] = [""]
            var inParameters = false
            while i < chars.count {
                let c = chars[i]
                if c == "^", i + 1 < chars.count {
                    if !inParameters { values[values.count - 1].append(chars[i + 1]) }
                    i += 2
                    continue
                }
                if c == "]" { i += 1; return values }
                if c == ";" { inParameters = true } else if c == "," && !inParameters { values.append("") } else if !inParameters { values[values.count - 1].append(c) }
                i += 1
            }
            return nil // unterminated
        }
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "/":
                i += 1
                guard let index = readInteger() else { return nil }
                var id: String?
                if i < chars.count, chars[i] == "[" {
                    guard let values = readAssertion() else { return nil }
                    id = values.first.flatMap { $0.isEmpty ? nil : $0 }
                }
                components.append(.step(CFI.Step(index: index, id: id)))
            case "!":
                i += 1
                components.append(.indirection)
            case ":":
                i += 1
                guard let offset = readInteger() else { return nil }
                var assertion: CFI.TextAssertion?
                if i < chars.count, chars[i] == "[" {
                    guard let values = readAssertion() else { return nil }
                    let before = values.first ?? ""
                    let after = values.count > 1 ? values[1] : ""
                    assertion = CFI.TextAssertion(before: before, after: after)
                    if assertion?.isEmpty == true { assertion = nil }
                }
                components.append(.offset(offset, assertion))
            case "~":
                i += 1
                guard readNumber() else { return nil }
            case "@":
                i += 1
                guard readNumber() else { return nil }
                guard i < chars.count, chars[i] == ":" else { return nil }
                i += 1
                guard readNumber() else { return nil }
            default:
                return nil
            }
        }
        return components
    }

    private static func assemble(_ components: [Component]) -> CFI? {
        var spine: [CFI.Step] = []
        var steps: [CFI.Step] = []
        var sawIndirection = false
        var offset: Int?
        var assertion: CFI.TextAssertion?
        for component in components {
            switch component {
            case .step(let step):
                guard offset == nil else { return nil } // steps after the offset
                if sawIndirection { steps.append(step) } else { spine.append(step) }
            case .indirection:
                guard !sawIndirection, offset == nil else { return nil } // one level of indirection only
                sawIndirection = true
            case .offset(let value, let a):
                guard offset == nil else { return nil }
                offset = value
                assertion = a
            }
        }
        if !sawIndirection {
            // No `!`: the whole path addresses the document (no spine).
            steps = spine
            spine = []
        }
        guard !steps.isEmpty || !spine.isEmpty else { return nil }
        return CFI(spineSteps: spine, steps: steps, characterOffset: offset, textAssertion: assertion)
    }
}
