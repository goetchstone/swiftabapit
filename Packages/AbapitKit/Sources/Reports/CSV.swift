import Foundation
import JSONAPI

/// abapit's `items_to_csv` (held to `Tests/Fixtures/parity/csv.json`): an `id` column, then the union of the
/// items' attribute keys in first-seen order; every cell, header included, guarded against formula injection;
/// written as Python's `csv` module writes (minimal quoting, `""` for a quote, CRLF).
///
/// One listed deviation: a dictionary or a list inside a cell is JSON (sorted keys, compact), not Python's
/// repr. And one addition: `allowing` drops columns that must never leave the app (an Activation Lock bypass
/// code, a token; Apple's `lastConnectedIp` by default: plan §3.9, invariant 11).
public enum CSV {
    public struct Item: Sendable {
        public let id: String
        public let attributes: JSONObject

        public init(id: String, attributes: JSONObject) {
            self.id = id
            self.attributes = attributes
        }

        public init(_ resource: Resource) { self.init(id: resource.id, attributes: resource.attributes) }
    }

    /// The CSV text. `allowing` says which attribute keys may be exported; nil allows every one.
    public static func text(_ items: [Item], allowing allowed: (@Sendable (String) -> Bool)? = nil) -> String {
        var columns: [String] = [], seen: Set<[UInt8]> = []
        for item in items {
            for key in item.attributes.keys where allowed?(key) ?? true {
                if seen.insert(Array(key.utf8)).inserted { columns.append(key) }
            }
        }
        var out = row((["id"] + columns).map(safe))
        for item in items {
            out += row(([item.id] + columns.map { cell(item.attributes[$0]) }).map(safe))
        }
        return out
    }

    /// abapit's `_cell`: nothing for null, Python's `str` for a scalar, `"; "`-joined items for a list.
    static func cell(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: ""
        case .string(let text)?: text
        case .bool(let flag)?: flag ? "True" : "False"
        case .number(let text)?: text
        case .array(let items)?:
            items.map { item in
                switch item {
                case .array, .object: json(item)
                case .null: "None"
                default: cell(item)
                }
            }.joined(separator: "; ")
        case .object?: json(value!)
        }
    }

    /// `json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))`.
    static func json(_ value: JSONValue) -> String {
        switch value {
        case .array(let items): "[" + items.map(json).joined(separator: ",") + "]"
        case .object(let members):
            "{" + members.members.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
                .map { JSONValue.dumps(.string($0.key)) + ":" + json($0.value) }.joined(separator: ",") + "}"
        default: JSONValue.dumps(value)
        }
    }

    /// abapit's `_csv_safe`: a cell a spreadsheet would run as a formula (`=`, `+`, `-`, `@`, tab, CR first)
    /// gets a leading `'`.
    static func safe(_ text: String) -> String {
        guard let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return text }
        return "'" + text
    }

    /// One row as CPython's `csv.writer` writes it (excel dialect): a field holding `,`, `"`, CR or LF is quoted
    /// with its quotes doubled; a row of one empty field is `""`; CRLF ends it.
    static func row(_ fields: [String]) -> String {
        if fields.count == 1, fields[0].isEmpty { return "\"\"\r\n" }
        return fields.map { field in
            guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return field }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }.joined(separator: ",") + "\r\n"
    }
}

/// What never leaves the app in a CSV, whatever the screen (invariant 11). Mosyle's bypass codes join in
/// Phase 7; the adapter drops them first, this is the second layer.
public enum ExportPolicy {
    /// Shown in the app, not exported by default (plan §3.9).
    public static let notByDefault: Set = ["lastConnectedIp"]

    /// Keys that must never be exported: Activation Lock bypass codes and anything token-, password- or
    /// secret-shaped.
    public static func isSensitive(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return lowered.hasPrefix("activation_bypass") || lowered.contains("bypass") || lowered.contains("token")
            || lowered.contains("password") || lowered.contains("secret")
    }

    /// The export filter: a typed view's own fields (`fields`) when given, else every key, minus the sensitive
    /// ones and, unless `includeNotByDefault`, `notByDefault`.
    public static func allowing(_ fields: [String]? = nil, includeNotByDefault: Bool = false) -> @Sendable (String) -> Bool {
        let listed = fields.map(Set.init)
        return { key in
            !isSensitive(key) && (includeNotByDefault || !notByDefault.contains(key)) && (listed?.contains(key) ?? true)
        }
    }
}
