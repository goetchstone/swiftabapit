import Foundation
import JSONAPI

/// abapit's `items_to_csv` (held to `Tests/Fixtures/parity/csv.json`): an `id` column, then the columns; every
/// cell, header included, guarded against formula injection; written as Python's `csv` module writes (minimal
/// quoting, `""` for a quote, CRLF), scalar by scalar, as Python reads a string.
///
/// Two listed deviations: a dictionary or a list inside a cell is JSON (sorted keys, compact), not Python's repr;
/// and the formula guard also catches a look-alike trigger and a trigger after invisible leading scalars. And one
/// rule abapit didn't have: an export names its columns (invariant 11). abapit exported the union of every key
/// Apple sent; here that union is only the parity golden's (Phase 1b review M2).
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
    /// with or without `includeNotByDefault`, which only lets `ExportPolicy.notByDefault` through. A column is
    /// written once, compared by code point as `union` compares Apple's keys.
    public static func text(_ items: [Item], columns: ExportPolicy.Columns, includeNotByDefault: Bool = false) -> String {
        var kept: [String] = [], seen: Set<[UInt8]> = []
        for key in columns.names where ExportPolicy.permits(key, includeNotByDefault: includeNotByDefault) {
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

    /// abapit's triggers, `=+-@`, and U+2212 MINUS SIGN (some locales' numbers use it for `-`), or a scalar whose
    /// compatibility form starts with one: the full-width U+FF1D, U+FF0B, U+FF0D, U+FF20; the small forms U+FE62,
    /// U+FE63, U+FE66, U+FE6B; the super- and subscript signs; U+2A75 and U+2A76 (`==`, `===`); U+FB29. The golden
    /// lists them, and a test holds this to it scalar by scalar (verifier round 1).
    static func isTrigger(_ scalar: Unicode.Scalar) -> Bool {
        guard let form = String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars.first else { return false }
        return form == "=" || form == "+" || form == "-" || form == "@" || form == "\u{2212}"
    }

    /// What can stand before a trigger unseen, as `scripts/check_text.py` defines invisible: every control (Cc:
    /// tab, CR, LF, VT, FF, U+001C to U+001F, NEL), format character (Cf: U+200B, U+FEFF, bidi marks), space
    /// (Zs), line and paragraph separator (Zl, Zp), default-ignorable code point (the Hangul fillers, variation
    /// selectors, U+034F) and U+2800 BRAILLE PATTERN BLANK. That covers every common trimmer's whitespace
    /// (Python's, .NET's, Java's). A combining mark is not blank: it shows, and nothing trims it. The golden
    /// lists the set, and a test holds this to it scalar by scalar (verifier round 1).
    static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator: true
        default: scalar.properties.isDefaultIgnorableCodePoint || scalar == "\u{2800}"
        }
    }

    /// abapit's `_csv_safe`: a cell a spreadsheet would run as a formula gets a leading `'`. abapit's rule is a
    /// tab, a CR or a trigger first; the listed deviation guards a cell whose first visible scalar is a trigger
    /// or reads as one (Phase 1b review, LOW: `" =1"`, `"\u{200B}=1"`, `"\u{FF1D}1"`; verifier round 1:
    /// `"\u{0B}=1"`, `"\u{2028}=1"`, `"\u{FE66}1"`, `"\u{2212}1"`). By scalar: a CR LF or a trigger with a
    /// combining mark is one `Character`, and Python sees its first code point.
    static func safe(_ text: String) -> String {
        let scalars = text.unicodeScalars
        if let first = scalars.first, first == "\t" || first == "\r" { return "'" + text }
        guard let lead = scalars.first(where: { !isBlank($0) }), isTrigger(lead) else { return text }
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
    /// An export's columns. Only this module makes one, so a screen can export a list named here and nothing
    /// else: `CSV.text(items, columns: Array(item.attributes.keys))`, the every-key export the Phase 1b review
    /// removed (M2), doesn't compile outside Reports (verifier round 1).
    public struct Columns: Sendable {
        public let names: [String]
        init(_ names: [String]) { self.names = names }
    }

    /// The Devices view's export (Phase 1b review M2): the table's columns (serial, model, family, status,
    /// added), then the rest of Apple's documented `OrgDevice` attributes in `OrgDevice.fields` order. Nothing
    /// here is secret; a key Apple adds later is not exported until it is listed here. The table's Service
    /// column isn't an attribute.
    public static let devices = Columns([
        "serialNumber", "deviceModel", "productFamily", "status", "addedToOrgDateTime",
        "releasedFromOrgDateTime", "updatedDateTime", "productType", "deviceCapacity", "partNumber", "orderNumber",
        "color", "orderDateTime", "imei", "meid", "eid", "purchaseSourceId", "purchaseSourceType", "wifiMacAddress",
        "bluetoothMacAddress", "ethernetMacAddress", "isMdmMigrationCapable", "mdmMigrationStatus",
        "mdmMigrationDeadlineDateTime",
    ])

    /// Shown in the app, not exported by default (plan §3.9).
    public static let notByDefault: Set = ["lastConnectedIp"]

    /// Stems of a key that must never be exported: Activation Lock bypass codes, tokens, passwords, keys,
    /// assertions and the like. Matched against the key folded by `fold`.
    static let sensitiveStems = ["bypass", "token", "password", "passwd", "passcode", "pwd", "secret", "assertion",
                                 "credential", "privatekey", "apikey", "recoverykey", "escrow", "jwt", "bearer", "unlockpin"]

    /// A key as the denylist reads it: compatibility-decomposed (a full-width `TOKEN`, U+FF34 U+FF2F ..., a
    /// modifier-letter or mathematical-bold `TOKEN` all read `TOKEN`), then lowercased, then letters and numbers
    /// only by general category (`tok\u{200B}en`, `tok\u{301}en`, `tok\u{345}en`, `api_key` and `api-key` read as
    /// `token` and `apikey`). Phase 1b review M2: each of those spellings got past the old denylist. Decomposed,
    /// not composed: NFKC made `k` + U+0301 one letter, U+1E31, so `tok\u{301}en` missed `token`; and decomposed
    /// before lowercasing, because a modifier capital has no lowercase of its own (verifier round 1).
    static func fold(_ key: String) -> String {
        let scalars = key.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
        return String(String.UnicodeScalarView(scalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }))
    }

    /// Keys that must never be exported, listed or not. A stem is found by code point (UTF-8 bytes): `String`'s
    /// `contains` matches `Character`s, and a prepended letter such as U+0D4E joins the `t` of `\u{D4E}token`
    /// into one (verifier round 1).
    public static func isSensitive(_ key: String) -> Bool {
        let folded = Array(fold(key).utf8)
        return sensitiveStems.contains { folded.firstRange(of: Array($0.utf8)) != nil }
    }

    /// Whether a listed column may be written.
    static func permits(_ key: String, includeNotByDefault: Bool) -> Bool {
        !isSensitive(key) && (includeNotByDefault || !notByDefault.contains(key))
    }
}
