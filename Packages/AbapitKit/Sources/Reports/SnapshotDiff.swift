import Foundation
import JSONAPI
import MosyleModels

/// abapit's `history.diff_snapshots` over two snapshots held in memory (held to `Tests/Fixtures/parity/diff.json`
/// and the diff reads of `history.json`; invariant 6), and its `item_label`. The store that reads a snapshot back
/// from SQLite is Phase 3's `History` module; this is the rule.
///
/// Resources, ids and fields are ordered by code point (UTF-8 bytes), as Python's `sorted` orders its strings, and
/// distinct by bytes, as Python's sets and dicts keep them: an NFC and an NFD spelling are two ids. A field missing
/// from one side reads as null, as abapit's `.get()` does.
///
/// Two listed deviations, the operator's decisions of 2026-11-20 (the golden's `abapit` field holds abapit's output):
/// - **A boolean is not a number.** Python's `True == 1 == 1.0`, so abapit saw no change when a flag became a count;
///   here `true` against `1` is a change. `1` against `1.0` is still no change: numbers compare by value.
/// - **An item is "changed" only when a field really changed.** abapit listed an item whose attributes differed
///   only by `None` against a missing key as changed, with no field. That is no change here and yields no item.
public enum SnapshotDiff {
    /// A snapshot: resource name, then item id, then the item's attributes.
    public struct Snapshot: Sendable, Equatable {
        /// `{resource: {id: attributes}}`, every level an object.
        let resources: JSONObject

        /// Nil unless `value` is an object of objects of objects, the shape the store writes.
        public init?(_ value: JSONValue) {
            guard let resources = value.object,
                  resources.allSatisfy({ $0.value.object?.allSatisfy { $0.value.object != nil } ?? false })
            else { return nil }
            self.resources = resources
        }

        /// Rows as the store keeps them; a repeated `(resource, id)` keeps the last, as a dict does.
        public init(rows: [(resource: String, id: String, attributes: JSONObject)]) {
            var resources = JSONObject()
            for row in rows {
                var items = resources[row.resource]?.object ?? JSONObject()
                items[row.id] = .object(row.attributes)
                resources[row.resource] = .object(items)
            }
            self.resources = resources
        }

        func items(_ resource: String) -> JSONObject { resources[resource]?.object ?? JSONObject() }
    }

    public struct Item: Sendable, Equatable {
        public let id: String
        public let attributes: JSONObject
    }

    public struct Field: Sendable, Equatable {
        public let field: String
        public let old: JSONValue
        public let new: JSONValue
    }

    /// An item in both snapshots with at least one field that changed; `attributes` are the new snapshot's.
    public struct Change: Sendable, Equatable {
        public let id: String
        public let attributes: JSONObject
        public let fields: [Field]
    }

    public struct Delta: Sendable, Equatable {
        public let resource: String
        public let added: [Item]
        public let removed: [Item]
        public let changed: [Change]
    }

    /// The resources that differ, in code-point order; added, removed and changed items, each in code-point order of
    /// their id, and each changed item's fields in code-point order of their name.
    public static func diff(old: Snapshot, new: Snapshot) -> [Delta] {
        var deltas: [Delta] = []
        for resource in names(old.resources.keys + new.resources.keys) {
            let o = old.items(resource), n = new.items(resource)
            let added = names(n.keys.filter { o[$0] == nil }).map { Item(id: $0, attributes: n[$0]?.object ?? [:]) }
            let removed = names(o.keys.filter { n[$0] == nil }).map { Item(id: $0, attributes: o[$0]?.object ?? [:]) }
            var changed: [Change] = []
            for id in names(o.keys.filter { n[$0] != nil }) {
                let before = o[id]?.object ?? [:], after = n[id]?.object ?? [:]
                if equal(.object(before), .object(after)) { continue }
                let fields = names(before.keys + after.keys).compactMap { name -> Field? in
                    let x = before[name] ?? .null, y = after[name] ?? .null
                    return equal(x, y) ? nil : Field(field: name, old: x, new: y)
                }
                // The operator's decision: an item is changed only when a field really changed.
                if !fields.isEmpty { changed.append(Change(id: id, attributes: after, fields: fields)) }
            }
            if !added.isEmpty || !removed.isEmpty || !changed.isEmpty {
                deltas.append(Delta(resource: resource, added: added, removed: removed, changed: changed))
            }
        }
        return deltas
    }

    /// The distinct names (by bytes), in code-point order: Python's `sorted(set(...))`.
    static func names(_ names: [String]) -> [String] {
        var seen: Set<[UInt8]> = []
        return names.filter { seen.insert(Array($0.utf8)).inserted }.sorted(by: Python.precedes)
    }

    // MARK: equality

    /// JSON equality as the operator decided it: strings by bytes, a boolean only another boolean, numbers by value
    /// (never through `Double` where both are integers), objects by key and value without regard to order, lists
    /// element by element.
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let x), .bool(let y)): x == y
        case (.string(let x), .string(let y)): x.utf8.elementsEqual(y.utf8)
        case (.number(let x), .number(let y)): sameNumber(x, y)
        case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.object(let x), .object(let y)):
            x.count == y.count && x.allSatisfy { member in y[member.key].map { equal(member.value, $0) } ?? false }
        default: false
        }
    }

    /// Python's number equality: two integers exactly (any length); two floats as doubles (`NaN` is never equal,
    /// as two separately parsed `NaN`s aren't); an integer and a float exactly, so `10**16 == 1e16` and
    /// `2**53 + 1 != 2.0**53`.
    static func sameNumber(_ x: String, _ y: String) -> Bool {
        switch (isInteger(x), isInteger(y)) {
        case (true, true): return normalized(x).elementsEqual(normalized(y))
        case (false, false): return JSONValue.number(x).double == JSONValue.number(y).double
        case (true, false): return integer(x, equals: y)
        case (false, true): return integer(y, equals: x)
        }
    }

    private static func isInteger(_ text: String) -> Bool {
        let digits = text.utf8.first == UInt8(ascii: "-") ? text.utf8.dropFirst() : text.utf8.dropFirst(0)
        return !digits.isEmpty && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    /// An integer's digits without the sign of zero: Python's `int("-0")` is `0`.
    private static func normalized(_ text: String) -> [UInt8] {
        text == "-0" ? [UInt8(ascii: "0")] : Array(text.utf8)
    }

    private static func integer(_ integer: String, equals float: String) -> Bool {
        guard let value = JSONValue.number(float).double, value.isFinite, value == value.rounded(.towardZero) else { return false }
        return normalized(integer).elementsEqual(Array(exactInteger(value).utf8))
    }

    /// The decimal digits of an integral, finite double, exactly.
    static func exactInteger(_ value: Double) -> String {
        if abs(value) < 9.0e18 { return String(Int64(value)) }
        // At 2^63 and above a double is a 53-bit integer times a power of two: double the digits that many times.
        var digits = Array(String(value.significandBitPattern | (1 << 52)).utf8.reversed().map { Int($0 - UInt8(ascii: "0")) })
        for _ in 0..<(Int(value.exponent) - 52) {
            var carry = 0
            for index in digits.indices {
                let product = digits[index] * 2 + carry
                digits[index] = product % 10
                carry = product / 10
            }
            if carry > 0 { digits.append(carry) }
        }
        return (value < 0 ? "-" : "") + String(digits.reversed().map { Character(String($0)) })
    }

    // MARK: label

    /// abapit's `item_label`: the first of `deviceModel`, `name`, `serverName`, `managedAppleAccount` and
    /// `description` that holds a truthy value, as text; otherwise nothing. Apple sends these as strings; any other
    /// value is shown as Python's `str` would for a number or a boolean (a list or an object as its JSON, where
    /// Python shows its repr: unreachable from Apple's documents).
    public static func label(_ attributes: JSONObject) -> String {
        for key in ["deviceModel", "name", "serverName", "managedAppleAccount", "description"] {
            guard let value = attributes[key], value.isTruthy else { continue }
            switch value {
            case .string(let text): return text
            case .bool(let flag): return flag ? "True" : "False"
            case .number(let text): return text
            default: return value.jsonText
            }
        }
        return ""
    }
}

extension JSONValue {
    /// Python's truthiness of a value `json.loads` makes: not null, false, zero, or empty.
    var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let flag): flag
        case .number: double.map { $0 != 0 } ?? true
        case .string(let text): !text.isEmpty
        case .array(let items): !items.isEmpty
        case .object(let members): !members.isEmpty
        }
    }
}
