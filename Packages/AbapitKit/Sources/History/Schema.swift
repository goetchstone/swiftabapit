import Foundation
import JSONAPI

/// The snapshot database's schema (plan L7, §3.7): abapit's `SCHEMA`, word for word, then what this app adds, applied
/// once and recorded in `PRAGMA user_version`. abapit's tables and views stay as abapit wrote them, so the file still
/// answers abapit's queries in `sqlite3` or Datasette, and an abapit `history.sqlite` reads with the same SQL.
enum Schema {
    /// The version this app writes. A database with a higher one was written by a newer version and opens read-only
    /// (`SnapshotStore.Access.readOnly`); abapit's own file says 0.
    static let version: Int32 = 1

    /// abapit's `SCHEMA` (`abapit/history.py` at the commit `scripts/gen_fixtures.py` pins, `ABAPIT_PIN`), byte for byte.
    /// `SchemaTests` holds it to that text's SHA-256.
    static let abapit = """

    CREATE TABLE IF NOT EXISTS snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        taken_at TEXT NOT NULL,
        org_client_id TEXT NOT NULL,
        org_name TEXT NOT NULL,
        org_scope TEXT NOT NULL,
        abapit_version TEXT NOT NULL,
        errors TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE IF NOT EXISTS items (
        snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
        resource TEXT NOT NULL,
        item_id TEXT NOT NULL,
        attributes TEXT NOT NULL,
        PRIMARY KEY (snapshot_id, resource, item_id)
    );

    CREATE VIEW IF NOT EXISTS devices_view AS
    SELECT s.id AS snapshot_id, s.taken_at, s.org_name,
           i.item_id AS serial,
           json_extract(i.attributes, '$.deviceModel') AS model,
           json_extract(i.attributes, '$.productFamily') AS family,
           json_extract(i.attributes, '$.status') AS status,
           json_extract(i.attributes, '$.addedToOrgDateTime') AS added_to_org
    FROM items i JOIN snapshots s ON s.id = i.snapshot_id
    WHERE i.resource = 'devices';

    CREATE VIEW IF NOT EXISTS applecare_view AS
    SELECT s.id AS snapshot_id, s.taken_at, s.org_name,
           json_extract(i.attributes, '$.serialNumber') AS serial,
           json_extract(i.attributes, '$.description') AS description,
           json_extract(i.attributes, '$.status') AS status,
           json_extract(i.attributes, '$.endDateTime') AS end_date
    FROM items i JOIN snapshots s ON s.id = i.snapshot_id
    WHERE i.resource = 'applecare';

    """

    /// What this app adds to abapit's schema, in version 1:
    /// - `org_id`: the org's id in `orgs.json` (`OrgProfile.id`). Every query filters by it; abapit's `org_client_id` is
    ///   kept and filled, but a Mosyle org has no client ID, and an id never changes after the org is added.
    /// - `notes`: per resource, what the operator must hear about it besides an error (a list cut short at the page cap,
    ///   a resource read in part, fields Apple left out), as a JSON object of words, like abapit's `errors`.
    /// - `counts`: per resource the snapshot read, the items it recorded, zero included, as a JSON object of numbers. A
    ///   resource it didn't try is absent, so "read and found none" and "didn't read" are told apart, which abapit's
    ///   items alone couldn't (`SnapshotStore.latest`).
    /// - An index for the per-org listing, and `activation_lock_view` beside abapit's two views, over the Activation Lock
    ///   statuses a collector records as `SnapshotStore.activationLockResource`, keyed by serial number.
    static let additions = """
    ALTER TABLE snapshots ADD COLUMN org_id TEXT NOT NULL DEFAULT '';
    ALTER TABLE snapshots ADD COLUMN notes TEXT NOT NULL DEFAULT '{}';
    ALTER TABLE snapshots ADD COLUMN counts TEXT NOT NULL DEFAULT '{}';
    CREATE INDEX IF NOT EXISTS snapshots_by_org ON snapshots (org_id, id);

    CREATE VIEW IF NOT EXISTS activation_lock_view AS
    SELECT s.id AS snapshot_id, s.taken_at, s.org_id, s.org_name,
           i.item_id AS serial,
           json_extract(i.attributes, '$.isLocked') AS is_locked,
           json_extract(i.attributes, '$.lockType') AS lock_type
    FROM items i JOIN snapshots s ON s.id = i.snapshot_id
    WHERE i.resource = 'activation_lock';

    """

    /// The script that makes a new, empty database version 1, run in one transaction. Never run on a file that holds
    /// anything (abapit's history is imported, never changed in place: `SnapshotStore.Failure.notThisAppsFile`).
    static var toVersion1: String { abapit + additions + "PRAGMA user_version = 1;\n" }

    /// `taken_at` as abapit writes it: UTC, to the second, `Z` (`strftime("%Y-%m-%dT%H:%M:%SZ")`).
    static func takenAt(_ date: Date) -> String {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded(.down)).formatted(.iso8601)
    }
}

/// JSON as abapit stores it in a row: `json.dumps(value, sort_keys=True)`. Keys sorted by code point at every depth;
/// `", "` and `": "` between members; every scalar outside printable ASCII written as `\uXXXX` in lowercase hex (a
/// surrogate pair above U+FFFF), as Python's default `ensure_ascii` writes it. So a row this app writes reads, in
/// `sqlite3`, as the row abapit would have written, and its attributes load in abapit's order (sorted).
///
/// One deviation: a number keeps the text it was read with (`JSONValue` keeps it), where Python reads it as an int or a
/// float and writes that again: `-0` (Python `0`), `1.50` (`1.5`), `1e2` (`100.0`), `3.0e-5` (`3e-05`), `1e400`
/// (`Infinity`). So a diff compares numbers by value (1 is 1.0, as the operator reads them), never by `JSONValue.==`,
/// which compares their text. Apple's and Mosyle's numbers are integers.
enum StoredJSON {
    static func text(_ value: JSONValue) -> String {
        var out = ""
        write(value, to: &out)
        return out
    }

    private static func write(_ value: JSONValue, to out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let text): out += text
        case .string(let text): quote(text, to: &out)
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += ", " }
                write(item, to: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            let members = object.members.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            for (index, member) in members.enumerated() {
                if index > 0 { out += ", " }
                quote(member.key, to: &out)
                out += ": "
                write(member.value, to: &out)
            }
            out += "}"
        }
    }

    private static let hex = Array("0123456789abcdef".unicodeScalars)

    private static func quote(_ text: String, to out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case " "..."~": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x10000 {
                    let value = scalar.value - 0x10000
                    escape(0xD800 + (value >> 10), to: &out)
                    escape(0xDC00 + (value & 0x3FF), to: &out)
                } else {
                    escape(scalar.value, to: &out)
                }
            }
        }
        out += "\""
    }

    private static func escape(_ unit: UInt32, to out: inout String) {
        out += "\\u"
        for shift in stride(from: 12, through: 0, by: -4) { out.unicodeScalars.append(hex[Int((unit >> UInt32(shift)) & 0xF)]) }
    }
}
