import Foundation
import JSONAPI

/// abapit's `items_to_csv` (held to `Tests/Fixtures/parity/csv.json`): an `id` column, then the columns; every
/// cell, header included, guarded against formula injection; written as Python's `csv` module writes (minimal
/// quoting, `""` for a quote, CRLF), scalar by scalar, as Python reads a string.
///
/// Two listed deviations: a dictionary or a list inside a cell is JSON (sorted keys, compact), not Python's repr;
/// and the formula guard also catches full-width triggers and a trigger after leading blanks. And one rule abapit
/// didn't have: an export names its columns (invariant 11). abapit exported the union of every key Apple sent;
/// here that union is only the parity golden's (Phase 1b review M2).
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

    /// The CSV text: an `id` column, then `columns` in order (an allowlist: a key Apple sends that isn't listed
    /// never leaves). The policy's denylist still drops a listed column that must not leave (the second defence),
    /// and `ExportPolicy.notByDefault` unless `includeNotByDefault`.
    public static func text(_ items: [Item], columns: [String], includeNotByDefault: Bool = false) -> String {
        var kept: [String] = [], seen: Set<[UInt8]> = []
        for key in columns where ExportPolicy.permits(key, includeNotByDefault: includeNotByDefault) {
            if seen.insert(Array(key.utf8)).inserted { kept.append(key) }
        }
        return write(items, columns: kept)
    }

    /// abapit's columns, the union of the items' keys in first-seen order, compared by code point as Python
    /// does. Only the parity golden uses it: no export may (invariant 11).
    static func union(_ items: [Item]) -> [String] {
        var columns: [String] = [], seen: Set<[UInt8]> = []
        for item in items {
            for key in item.attributes.keys where seen.insert(Array(key.utf8)).inserted { columns.append(key) }
        }
        return columns
    }

    static func write(_ items: [Item], columns: [String]) -> String {
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

    /// abapit's triggers and their full-width forms (U+FF1D, U+FF0B, U+FF0D, U+FF20).
    static let triggers: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"]

    /// What can stand before a trigger unseen: Unicode spaces (Zs), format characters (Cf, such as U+200B and
    /// U+FEFF), tab, CR and LF.
    static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .format: true
        default: scalar == "\t" || scalar == "\r" || scalar == "\n"
        }
    }

    /// abapit's `_csv_safe`: a cell a spreadsheet would run as a formula gets a leading `'`. abapit's rule is a
    /// tab, a CR or a trigger first; the listed deviation also guards a full-width trigger, and a trigger after
    /// leading blanks (Phase 1b review, LOW: `" =1"`, `"\u{200B}=1"`). By scalar: a CR LF or a trigger with a
    /// combining mark is one `Character`, and Python sees its first code point.
    static func safe(_ text: String) -> String {
        let scalars = text.unicodeScalars
        if let first = scalars.first, first == "\t" || first == "\r" { return "'" + text }
        guard let lead = scalars.first(where: { !isBlank($0) }), triggers.contains(lead) else { return text }
        return "'" + text
    }

    /// One row as CPython's `csv.writer` writes it (excel dialect): a field holding `,`, `"`, CR or LF is quoted
    /// with its quotes doubled; a row of one empty field is `""`; CRLF ends it.
    static func row(_ fields: [String]) -> String {
        if fields.count == 1, fields[0].isEmpty { return "\"\"\r\n" }
        return fields.map(quoted).joined(separator: ",") + "\r\n"
    }

    /// Decided and escaped by scalar, as Python's csv does (Phase 1b review H1). `replacingOccurrences` and
    /// `contains` on a `String` match whole `Character`s: a quote followed by U+0301 wasn't doubled, the field
    /// closed early and the rest of it became a new, unguarded cell; a CR LF (one `Character`) went unquoted.
    static func quoted(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return field }
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in field.unicodeScalars {
            if scalar == "\"" { out.append("\"") }
            out.append(scalar)
        }
        out.append("\"")
        return String(out)
    }
}

/// What never leaves the app in a CSV, whatever the screen (invariant 11). Each view's export is a fixed list of
/// columns (the allowlist); the denylist below drops a listed column that must not leave anyway (the second
/// defence). Mosyle's bypass codes join in Phase 7; the adapter drops them first.
public enum ExportPolicy {
    /// The Devices view's export (Phase 1b review M2): the table's columns (serial, model, family, status,
    /// added), then the rest of Apple's documented `OrgDevice` attributes. Nothing here is secret; a key Apple
    /// adds later is not exported until it is listed here. The table's Service column isn't an attribute.
    public static let devices = [
        "serialNumber", "deviceModel", "productFamily", "status", "addedToOrgDateTime",
        "productType", "deviceCapacity", "color", "partNumber", "orderNumber", "orderDateTime", "purchaseSourceId",
        "purchaseSourceType", "imei", "meid", "eid", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress",
        "isMdmMigrationCapable", "mdmMigrationStatus", "mdmMigrationDeadlineDateTime", "updatedDateTime",
        "releasedFromOrgDateTime",
    ]

    /// Shown in the app, not exported by default (plan §3.9).
    public static let notByDefault: Set = ["lastConnectedIp"]

    /// Stems of a key that must never be exported: Activation Lock bypass codes, tokens, passwords, keys,
    /// assertions and the like. Matched against the key folded by `fold`.
    static let sensitiveStems = ["bypass", "token", "password", "passwd", "passcode", "pwd", "secret", "assertion",
                                 "credential", "privatekey", "apikey", "recoverykey", "escrow", "jwt", "bearer", "unlockpin"]

    /// A key as the denylist reads it: compatibility-normalized (a full-width `TOKEN`, U+FF34 U+FF2F ..., is
    /// `TOKEN`), lowercased, letters and digits only (`tok\u{200B}en`, `api_key` and `api-key` read as `token`
    /// and `apikey`). Phase 1b review M2: each of those spellings got past the old denylist.
    static func fold(_ key: String) -> String {
        let scalars = key.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
        return String(String.UnicodeScalarView(scalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }))
    }

    /// Keys that must never be exported, listed or not.
    public static func isSensitive(_ key: String) -> Bool {
        let folded = fold(key)
        return sensitiveStems.contains { folded.contains($0) }
    }

    /// Whether a listed column may be written.
    static func permits(_ key: String, includeNotByDefault: Bool) -> Bool {
        !isSensitive(key) && (includeNotByDefault || !notByDefault.contains(key))
    }
}
