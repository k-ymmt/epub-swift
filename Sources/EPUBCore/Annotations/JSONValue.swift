import Foundation

/// A JSON value, used to keep the properties of an annotation document that the library does not know
/// (docs/design/06-annotations.md §3.6) and to read and write the documents themselves.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The value as a non-negative integer, when it is a number without a fractional part.
    var nonNegativeIntegerValue: Int? {
        guard case .number(let n) = self, n >= 0, n.rounded() == n, n <= Double(Int.max / 2) else { return nil }
        return Int(n)
    }
}

/// Members of a JSON object. Order is not kept: the writer emits known properties in a fixed order and the rest
/// sorted by name, so output is deterministic.
public typealias JSONObject = [String: JSONValue]

// MARK: - Parsing

/// Limits applied while parsing (06-annotations §11). Exceeding one fails the parse.
struct JSONParseLimits: Sendable {
    var maxDepth: Int
    /// UTF-8 bytes of one string (member names included).
    var maxStringBytes: Int
    /// Returned in place of a string over `maxStringBytes` (its bytes are skipped, not kept), so the caller can drop
    /// what holds it instead of failing the whole document.
    var overlongMarker: String
}

struct JSONParseError: Error, Hashable, Sendable, CustomStringConvertible {
    var offset: Int
    var message: String
    var isDepthLimit = false
    var description: String { "JSON error at byte \(offset): \(message)" }
}

/// A small strict JSON parser (RFC 8259) over UTF-8 bytes, with depth and string-length limits. Written instead of
/// using `JSONSerialization` so the limits hold while parsing (a deeply nested document is refused before it is
/// built) and booleans and numbers stay distinct.
struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private let limits: JSONParseLimits

    static func parse(_ data: Data, limits: JSONParseLimits) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data), limits: limits)
        // A UTF-8 byte order mark is tolerated.
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }

    private init(bytes: [UInt8], limits: JSONParseLimits) {
        self.bytes = bytes
        self.limits = limits
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(offset: index, message: message)
    }

    private func depthError() -> JSONParseError {
        JSONParseError(offset: index, message: "nesting deeper than \(limits.maxDepth)", isDepthLimit: true)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            guard depth < limits.maxDepth else { throw depthError() }
            return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["):
            guard depth < limits.maxDepth else { throw depthError() }
            return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expect("true"); return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false"); return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null"); return .null
        default:
            return .number(try parseNumber())
        }
    }

    private mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw error("invalid literal") }
            index += 1
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var object: JSONObject = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a member name") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth)
            // A repeated member name keeps the first value (as most readers do for EPUB metadata).
            if object[key] == nil { object[key] = value }
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("expected ',' or '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            throw error("expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var utf8: [UInt8] = []
        var overlong = false
        while true {
            guard index < bytes.count else { throw error("unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { index += 1; break }
            if byte < 0x20 { throw error("control character in string") }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): utf8.append(0x22)
                case UInt8(ascii: "\\"): utf8.append(0x5C)
                case UInt8(ascii: "/"): utf8.append(0x2F)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // A high surrogate must be followed by an escaped low surrogate.
                        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                throw error("unpaired surrogate")
                            }
                        } else {
                            throw error("unpaired surrogate")
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("unpaired surrogate")
                    }
                    guard let s = Unicode.Scalar(scalar) else { throw error("invalid escape") }
                    utf8.append(contentsOf: Array(String(Character(s)).utf8))
                default:
                    throw error("invalid escape")
                }
            } else {
                utf8.append(byte)
                index += 1
            }
            if !overlong, utf8.count > limits.maxStringBytes {
                overlong = true
            }
            if overlong { utf8.removeAll(keepingCapacity: true) }
        }
        if overlong { return limits.overlongMarker }
        guard let string = String(validating: utf8, as: UTF8.self) else { throw error("invalid UTF-8") }
        return string
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("short \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        func digits() -> Int {
            var n = 0
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") { index += 1; n += 1 }
            return n
        }
        guard index < bytes.count else { throw error("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            guard digits() > 0 else { throw error("invalid value") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw error("invalid number") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw error("invalid number") }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
            throw error("invalid number")
        }
        return value
    }
}

// MARK: - Writing

/// Writes JSON with two-space indentation. Objects are written as ordered member lists (`JSONWriter.Members`) so
/// the known properties come out in the order the specification lists them.
struct JSONWriter {
    /// An object whose members are written in this order.
    struct Members {
        var pairs: [(String, Node)] = []

        mutating func set(_ key: String, _ node: Node?) {
            guard let node else { return }
            pairs.append((key, node))
        }

        /// Appends the extension members not already written, sorted by name.
        mutating func append(extensions: JSONObject) {
            let written = Set(pairs.map(\.0))
            for key in extensions.keys.sorted() where !written.contains(key) {
                pairs.append((key, .value(extensions[key]!)))
            }
        }
    }

    indirect enum Node {
        case value(JSONValue)
        case object(Members)
        case array([Node])

        static func string(_ s: String) -> Node { .value(.string(s)) }
    }

    static func data(_ node: Node) -> Data {
        var out = ""
        write(node, indent: 0, into: &out)
        out += "\n"
        return Data(out.utf8)
    }

    private static func write(_ node: Node, indent: Int, into out: inout String) {
        switch node {
        case .value(let value):
            write(value, indent: indent, into: &out)
        case .object(let members):
            writeObject(members.pairs.map { pair in (pair.0, { (o: inout String, i: Int) in write(pair.1, indent: i, into: &o) }) }, indent: indent, into: &out)
        case .array(let nodes):
            writeArray(nodes.map { node in { (o: inout String, i: Int) in write(node, indent: i, into: &o) } }, indent: indent, into: &out)
        }
    }

    private static func write(_ value: JSONValue, indent: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += number(n)
        case .string(let s): out += quoted(s)
        case .array(let values):
            writeArray(values.map { v in { (o: inout String, i: Int) in write(v, indent: i, into: &o) } }, indent: indent, into: &out)
        case .object(let object):
            let keys = object.keys.sorted()
            writeObject(keys.map { key in (key, { (o: inout String, i: Int) in write(object[key]!, indent: i, into: &o) }) }, indent: indent, into: &out)
        }
    }

    private typealias Emit = (inout String, Int) -> Void

    private static func writeObject(_ members: [(String, Emit)], indent: Int, into out: inout String) {
        if members.isEmpty { out += "{}"; return }
        out += "{\n"
        for (k, member) in members.enumerated() {
            out += String(repeating: "  ", count: indent + 1)
            out += quoted(member.0)
            out += ": "
            member.1(&out, indent + 1)
            out += k == members.count - 1 ? "\n" : ",\n"
        }
        out += String(repeating: "  ", count: indent) + "}"
    }

    private static func writeArray(_ elements: [Emit], indent: Int, into out: inout String) {
        if elements.isEmpty { out += "[]"; return }
        out += "[\n"
        for (k, element) in elements.enumerated() {
            out += String(repeating: "  ", count: indent + 1)
            element(&out, indent + 1)
            out += k == elements.count - 1 ? "\n" : ",\n"
        }
        out += String(repeating: "  ", count: indent) + "]"
    }

    static func number(_ n: Double) -> String {
        if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { return String(Int64(n)) }
        return String(n)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
