// Adapted from SwiftGamGui Packages/GamKit/Sources/GamEngine/JSONValue.swift @ bfdb494.

/// A JSON value as Python's `json.loads` reads one, so Apple's and Mosyle's responses parse into what
/// abapit parsed: objects keep their keys in order (abapit's CSV columns are the attributes' first-seen
/// order), and an attribute this app doesn't model yet survives into exports and snapshots (invariant 10).
/// Numbers keep their text (Python reads integers exactly, however long). `NaN`, `Infinity` and
/// `-Infinity` are accepted, as Python accepts them. Strings compare by their exact text, as Python's
/// do, not by Swift's canonical equivalence.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number as written. The parser only makes JSON numbers, `NaN`, `Infinity` or `-Infinity`.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var double: Double? {
        guard case .number(let text) = self else { return nil }
        return switch text {
        case "NaN": .nan
        case "Infinity": .infinity
        case "-Infinity": -.infinity
        default: Double(text)
        }
    }

    /// The number when it is written as an integer that fits an `Int`: not `1.0` or `1e5`.
    public var int: Int? {
        if case .number(let text) = self { Int(text) } else { nil }
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var object: JSONObject? {
        if case .object(let value) = self { value } else { nil }
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let x), .bool(let y)): x == y
        case (.number(let x), .number(let y)): x.utf8.elementsEqual(y.utf8)
        case (.string(let x), .string(let y)): x.utf8.elementsEqual(y.utf8)
        case (.array(let x), .array(let y)): x == y
        case (.object(let x), .object(let y)): x == y
        default: false
        }
    }

    /// Nesting deeper than this is refused. Python's own limit is the C stack (about 87,000 on this
    /// Mac). Here each level is a stack frame when parsing, comparing and freeing, and a debug build
    /// overflowed a 512 KiB thread at about 470 (SwiftGamGui PR #7's review). Apple's documents are a
    /// few levels deep; Mosyle's Logs Stream about six.
    public static let maximumDepth = 128

    /// Python's limit on an integer's digits (`sys.int_info.default_max_str_digits`): past it,
    /// `json.loads` raises.
    public static let maximumIntegerDigits = 4300

    /// `json.loads(text)`, or nil where it raises (including nesting past `maximumDepth`). A lone
    /// surrogate escape (`"\ud800"`), which Python keeps, becomes U+FFFD: a Swift string can't hold one.
    public static func parse(_ text: String) -> JSONValue? {
        var reader = Reader(Array(text.unicodeScalars))
        reader.skipWhitespace()
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.atEnd ? value : nil
    }

    /// `json.dumps(value, ensure_ascii=False)`: `", "` and `": "` separators, non-ASCII kept as it is,
    /// and only `"`, `\` and the C0 controls escaped.
    package static func dumps(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let text): return text
        case .string(let text): return quoted(text)
        case .array(let items): return "[" + items.map(dumps).joined(separator: ", ") + "]"
        case .object(let members):
            return "{" + members.map { quoted($0.key) + ": " + dumps($0.value) }.joined(separator: ", ") + "}"
        }
    }

    /// The value as JSON text (`json.dumps`), for showing a nested attribute.
    public var jsonText: String { Self.dumps(self) }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index == scalars.count }
        var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        /// JSON's whitespace only: space, tab, LF, CR.
        mutating func skipWhitespace() {
            while let scalar = current, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
                index += 1
            }
        }

        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard current == scalar else { return false }
            index += 1
            return true
        }

        /// No allocation: this runs for every value of a megabyte of output.
        mutating func take(_ literal: StaticString) -> Bool {
            var position = index
            for byte in UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount) {
                guard position < scalars.count, scalars[position].value == UInt32(byte) else { return false }
                position += 1
            }
            index = position
            return true
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard let scalar = current else { return nil }
            switch scalar {
            case "{": return depth < JSONValue.maximumDepth ? object(depth: depth + 1) : nil
            case "[": return depth < JSONValue.maximumDepth ? array(depth: depth + 1) : nil
            case "\"": return string().map(JSONValue.string)
            case "n": return take("null") ? .null : nil
            case "t": return take("true") ? .bool(true) : nil
            case "f": return take("false") ? .bool(false) : nil
            case "N": return take("NaN") ? .number("NaN") : nil
            case "I": return take("Infinity") ? .number("Infinity") : nil
            default:
                if take("-Infinity") { return .number("-Infinity") }
                return number()
            }
        }

        mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var members = JSONObject()
            skipWhitespace()
            if take("}" as Unicode.Scalar) { return .object(members) }
            while true {
                skipWhitespace()
                guard current == "\"", let key = string() else { return nil }
                skipWhitespace()
                guard take(":" as Unicode.Scalar) else { return nil }
                skipWhitespace()
                guard let member = value(depth: depth) else { return nil }
                members[key] = member
                skipWhitespace()
                if take("}" as Unicode.Scalar) { return .object(members) }
                guard take("," as Unicode.Scalar) else { return nil }
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var elements: [JSONValue] = []
            skipWhitespace()
            if take("]" as Unicode.Scalar) { return .array(elements) }
            while true {
                skipWhitespace()
                guard let element = value(depth: depth) else { return nil }
                elements.append(element)
                skipWhitespace()
                if take("]" as Unicode.Scalar) { return .array(elements) }
                guard take("," as Unicode.Scalar) else { return nil }
            }
        }

        /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?`, ASCII digits only. A fraction or an
        /// exponent that doesn't complete is left for the next token, as Python's scanner leaves it.
        mutating func number() -> JSONValue? {
            let start = index
            func digits() -> Int {
                let first = index
                while let scalar = current, ("0"..."9").contains(scalar) { index += 1 }
                return index - first
            }
            _ = take("-" as Unicode.Scalar)
            let integerStart = index
            if take("0" as Unicode.Scalar) {
            } else if let scalar = current, ("1"..."9").contains(scalar) {
                _ = digits()
            } else {
                index = start
                return nil
            }
            let integerEnd = index
            var isInteger = true
            if take("." as Unicode.Scalar), digits() > 0 { isInteger = false } else { index = integerEnd }
            let fractionEnd = index
            if let scalar = current, scalar == "e" || scalar == "E" {
                index += 1
                if let sign = current, sign == "+" || sign == "-" { index += 1 }
                if digits() > 0 { isInteger = false } else { index = fractionEnd }
            }
            if isInteger, integerEnd - integerStart > JSONValue.maximumIntegerDigits { return nil }
            return .number(String(String.UnicodeScalarView(scalars[start..<index])))
        }

        /// A string at `"`: escapes decoded, a raw control character refused (Python's strict mode).
        mutating func string() -> String? {
            index += 1
            var out: [Unicode.Scalar] = []
            while let scalar = current {
                index += 1
                switch scalar {
                case "\"":
                    return String(String.UnicodeScalarView(out))
                case "\\":
                    guard let escaped = current else { return nil }
                    index += 1
                    switch escaped {
                    case "\"", "\\", "/": out.append(escaped)
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard let unit = hex4() else { return nil }
                        out.append(decode(unit))
                    default: return nil
                    }
                default:
                    guard scalar.value >= 0x20 else { return nil }
                    out.append(scalar)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard scalars.count - index >= 4 else { return nil }
            var value: UInt32 = 0
            for scalar in scalars[index..<(index + 4)] {
                guard let digit = hexDigit(scalar) else { return nil }
                value = value * 16 + digit
            }
            index += 4
            return value
        }

        func hexDigit(_ scalar: Unicode.Scalar) -> UInt32? {
            switch scalar {
            case "0"..."9": scalar.value - 0x30
            case "a"..."f": scalar.value - 0x61 + 10
            case "A"..."F": scalar.value - 0x41 + 10
            default: nil
            }
        }

        /// A `\u` escape: a high surrogate followed by a `\u` low one is one character; any other
        /// surrogate stands alone and becomes U+FFFD.
        mutating func decode(_ unit: UInt32) -> Unicode.Scalar {
            if (0xD800...0xDBFF).contains(unit) {
                let saved = index
                if take("\\u"), let low = hex4(), (0xDC00...0xDFFF).contains(low) {
                    return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))!
                }
                index = saved
            }
            return Unicode.Scalar(unit) ?? "\u{FFFD}"
        }
    }
}

/// A JSON object as Python's `dict` holds one: keys distinct by their exact text, in the order first
/// set, a repeated key keeping its last value. A Swift `Dictionary` would merge keys that differ only
/// in Unicode normalization ("é" and "e" + U+0301) and silently drop one (SwiftGamGui PR #7's review).
public struct JSONObject: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var members: [(key: String, value: JSONValue)] = []
    private var positions: [[UInt8]: Int] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (key, value) in elements { self[key] = value }
    }

    public var count: Int { members.count }
    public var isEmpty: Bool { members.isEmpty }
    public var keys: [String] { members.map(\.key) }

    /// Setting nil removes the key.
    public subscript(key: String) -> JSONValue? {
        get { positions[Array(key.utf8)].map { members[$0].value } }
        set {
            let bytes = Array(key.utf8)
            if let newValue {
                if let position = positions[bytes] {
                    members[position].value = newValue
                } else {
                    positions[bytes] = members.count
                    members.append((key, newValue))
                }
            } else if let position = positions.removeValue(forKey: bytes) {
                members.remove(at: position)
                for (index, member) in members.enumerated().dropFirst(position) { positions[Array(member.key.utf8)] = index }
            }
        }
    }

    /// This object with `other`'s members set over it: `{**self, **other}`.
    public func merging(_ other: JSONObject) -> JSONObject {
        var merged = self
        for (key, value) in other.members { merged[key] = value }
        return merged
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        members.makeIterator()
    }

    /// The same keys, by exact text, with equal values; order aside, as Python's dicts compare.
    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        a.count == b.count && a.members.allSatisfy { b[$0.key] == $0.value }
    }
}
