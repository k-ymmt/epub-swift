import Foundation

/// The CSS selectors a CssSelector may use here (06-annotations §6.3): `#id`, type selectors, `:nth-child(n)`,
/// `:nth-of-type(n)` and the child combinator `>`. Anything else (classes, attributes, the descendant combinator,
/// the general `An+B`) fails, and resolution moves on to the next selector.
enum CSSSubset {
    struct Compound: Hashable {
        /// Local name; nil for `*` or no type selector.
        var type: String?
        var id: String?
        var nthChild: Int?
        var nthOfType: Int?
    }

    /// The compounds of a selector joined by `>`, or nil when it uses anything outside the subset.
    static func parse(_ selector: String) -> [Compound]? {
        var parser = Parser(Array(selector.unicodeScalars))
        return parser.parseSelector()
    }

    /// The first element in document order (from the root of `document`, or inside `scope`) that matches, as a path.
    static func evaluate(_ selector: String, in document: XMLDocument, idCounts: [String: Int], scope: [Int]? = nil) -> [Int]? {
        guard let compounds = parse(selector), let first = compounds.first else { return nil }
        // Candidates for the first compound: the element with the id, or a walk of the tree (linear in its size).
        var candidates: [[Int]]
        if let id = first.id {
            guard let path = document.path(ofElementWithID: id) else { return nil }
            if let scope, !(path.starts(with: scope) && path.count > scope.count) { return nil }
            candidates = [path]
        } else {
            candidates = []
            func walk(_ element: XMLElement, _ path: [Int]) {
                for (i, child) in element.children.enumerated() {
                    guard case .element(let e) = child else { continue }
                    candidates.append(path + [i])
                    walk(e, path + [i])
                }
            }
            if let scope {
                if let element = document.element(at: scope) { walk(element, scope) }
            } else {
                candidates.append([])
                walk(document.root, [])
            }
        }
        candidates = candidates.filter { matches(first, at: $0, in: document) }
        for compound in compounds.dropFirst() {
            var next: [[Int]] = []
            for path in candidates {
                guard let element = document.element(at: path) else { continue }
                for (i, child) in element.children.enumerated() where child.element != nil {
                    let childPath = path + [i]
                    if matches(compound, at: childPath, in: document) { next.append(childPath) }
                }
            }
            candidates = next
            if candidates.isEmpty { return nil }
        }
        return candidates.min { comparePaths($0, $1) < 0 }
    }

    static func matches(_ compound: Compound, at path: [Int], in document: XMLDocument) -> Bool {
        guard let element = document.element(at: path) else { return false }
        if let type = compound.type {
            // Element names are case-sensitive in XML, but an HTML type selector matches XHTML elements in any case.
            if element.namespaceURI == XMLNamespace.xhtml || element.namespaceURI == nil {
                guard element.name.lowercased() == type.lowercased() else { return false }
            } else {
                guard element.name == type else { return false }
            }
        }
        if let id = compound.id, element.id != id { return false }
        if compound.nthChild != nil || compound.nthOfType != nil {
            guard let index = path.last, let parent = document.element(at: Array(path.dropLast())) else {
                // The root element is the first and only child of the document.
                return compound.nthChild.map { $0 == 1 } ?? true && compound.nthOfType.map { $0 == 1 } ?? true
            }
            var position = 0
            var typePosition = 0
            for (i, child) in parent.children.enumerated() {
                guard case .element(let e) = child else { continue }
                position += 1
                if e.name == element.name, e.namespaceURI == element.namespaceURI { typePosition += 1 }
                if i == index { break }
            }
            if let n = compound.nthChild, n != position { return false }
            if let n = compound.nthOfType, n != typePosition { return false }
        }
        return true
    }

    // MARK: Generation

    /// Serializes an identifier like `CSS.escape` (CSSOM §2.1.1).
    static func escapeIdentifier(_ identifier: String) -> String {
        let scalars = Array(identifier.unicodeScalars)
        var out = ""
        for (i, c) in scalars.enumerated() {
            let v = c.value
            if v == 0 {
                out += "\u{FFFD}"
            } else if (0x01...0x1F).contains(v) || v == 0x7F
                        || (i == 0 && (0x30...0x39).contains(v))
                        || (i == 1 && (0x30...0x39).contains(v) && scalars[0] == "-") {
                out += "\\" + String(v, radix: 16) + " "
            } else if i == 0, scalars.count == 1, c == "-" {
                out += "\\-"
            } else if v >= 0x80 || c == "-" || c == "_" || (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) {
                out.unicodeScalars.append(c)
            } else {
                out += "\\"
                out.unicodeScalars.append(c)
            }
        }
        return out
    }

    // MARK: Parser

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        mutating func parseSelector() -> [Compound]? {
            var compounds: [Compound] = []
            skipWhitespace()
            while true {
                guard let compound = parseCompound() else { return nil }
                compounds.append(compound)
                let hadSpace = skipWhitespace()
                if i == s.count { break }
                guard s[i] == ">" else {
                    _ = hadSpace // a descendant combinator or another combinator: outside the subset
                    return nil
                }
                i += 1
                skipWhitespace()
            }
            return compounds.isEmpty ? nil : compounds
        }

        @discardableResult
        mutating func skipWhitespace() -> Bool {
            let start = i
            while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" || s[i] == "\u{0C}" { i += 1 }
            return i > start
        }

        mutating func parseCompound() -> Compound? {
            var compound = Compound()
            var any = false
            if i < s.count, s[i] == "*" {
                i += 1
                any = true
            } else if i < s.count, isNameStart(s[i]) || s[i] == "\\" || s[i] == "-" {
                guard let name = parseIdentifier() else { return nil }
                compound.type = name
                any = true
            }
            if i < s.count, s[i] == "|" { return nil } // namespace prefixes
            while i < s.count {
                if s[i] == "#" {
                    i += 1
                    guard compound.id == nil, let id = parseName() else { return nil }
                    compound.id = id
                } else if s[i] == ":" {
                    i += 1
                    guard let name = parseIdentifier()?.lowercased(), i < s.count, s[i] == "(" else { return nil }
                    i += 1
                    skipWhitespace()
                    var digits = ""
                    while i < s.count, ("0"..."9").contains(s[i]) { digits.unicodeScalars.append(s[i]); i += 1 }
                    skipWhitespace()
                    guard i < s.count, s[i] == ")", let n = Int(digits), n > 0 else { return nil }
                    i += 1
                    switch name {
                    case "nth-child":
                        guard compound.nthChild == nil else { return nil }
                        compound.nthChild = n
                    case "nth-of-type":
                        guard compound.nthOfType == nil else { return nil }
                        compound.nthOfType = n
                    default:
                        return nil
                    }
                } else {
                    break
                }
                any = true
            }
            return any ? compound : nil
        }

        func isNameStart(_ c: Unicode.Scalar) -> Bool {
            c.value >= 0x80 || c == "_" || ("a"..."z").contains(c) || ("A"..."Z").contains(c)
        }

        func isNameChar(_ c: Unicode.Scalar) -> Bool {
            isNameStart(c) || c == "-" || ("0"..."9").contains(c)
        }

        /// An identifier: name characters and escapes, not starting with a digit (or `-` + digit).
        mutating func parseIdentifier() -> String? {
            guard i < s.count else { return nil }
            if ("0"..."9").contains(s[i]) { return nil }
            if s[i] == "-", i + 1 < s.count, ("0"..."9").contains(s[i + 1]) { return nil }
            return parseName()
        }

        /// Name characters and escapes (the token after `#`).
        mutating func parseName() -> String? {
            var out = ""
            while i < s.count {
                let c = s[i]
                if c == "\\" {
                    i += 1
                    guard i < s.count, s[i] != "\n" else { return nil }
                    var hex = ""
                    while i < s.count, hex.unicodeScalars.count < 6, s[i].properties.isASCIIHexDigit {
                        hex.unicodeScalars.append(s[i]); i += 1
                    }
                    if !hex.isEmpty {
                        let value = UInt32(hex, radix: 16) ?? 0xFFFD
                        let scalar = (value == 0 || (0xD800...0xDFFF).contains(value) || value > 0x10FFFF) ? Unicode.Scalar(0xFFFD)! : Unicode.Scalar(value)!
                        out.unicodeScalars.append(scalar)
                        if i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" { i += 1 }
                    } else {
                        out.unicodeScalars.append(s[i]); i += 1
                    }
                } else if isNameChar(c) {
                    out.unicodeScalars.append(c); i += 1
                } else {
                    break
                }
            }
            return out.isEmpty ? nil : out
        }
    }
}
