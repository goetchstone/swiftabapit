import CryptoKit
import Foundation
import JSONAPI
import Orgs
import Testing
@testable import History

/// The schema is abapit's `SCHEMA`, word for word, plus this app's additions (plan L7, §3.7), and rows are written as
/// abapit writes them, so the file reads in `sqlite3` or Datasette as abapit's did.
@Suite("Snapshot schema")
struct SchemaTests {
    /// SHA-256 of abapit's `SCHEMA` at the pin (`ABAPIT_PIN` in scripts/gen_fixtures.py, 3890091), computed from abapit's
    /// own text: `git -C ../abapit show 3890091:abapit/history.py`, then `hashlib.sha256(SCHEMA.encode()).hexdigest()` on
    /// the `SCHEMA` the AST holds. A change on either side fails here.
    static let abapitSchemaSHA256 = "ef2ae0e17824136766d1683fb40c5fc12ac1f2b41abbce9d651ae6789885cb18"

    @Test func abapitsSchemaIsCopiedByteForByte() {
        let digest = SHA256.hash(data: Data(Schema.abapit.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == Self.abapitSchemaSHA256)
        #expect(Schema.abapit.utf8.count == 1421)
        // The additions come after abapit's text, which runs first and unchanged.
        #expect(Schema.toVersion1.utf8.starts(with: Schema.abapit.utf8))
    }

    /// abapit's tables and views as abapit wrote them, the two columns, the index and the new view; version 1.
    @Test func aNewDatabaseIsAbapitsSchemaPlusTheAdditions() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))

        #expect(try file.userVersion() == Schema.version)
        #expect(Schema.version == 1)
        let columns = { (table: String) in try file.rows("PRAGMA table_info(\(table))") { try $0.text(1) ?? "" } }
        #expect(try columns("snapshots") == ["id", "taken_at", "org_client_id", "org_name", "org_scope", "abapit_version", "errors",
                                             "org_id", "notes", "counts"])
        #expect(try columns("items") == ["snapshot_id", "resource", "item_id", "attributes"])
        // items → snapshots, deleted with it.
        let keys = try file.rows("PRAGMA foreign_key_list(items)") { try [$0.text(2) ?? "", $0.text(3) ?? "", $0.text(4) ?? "", $0.text(6) ?? ""] }
        #expect(keys == [["snapshots", "snapshot_id", "id", "CASCADE"]])
        let named = { (type: String) in try file.rows("SELECT name FROM sqlite_master WHERE type = '\(type)' AND name NOT LIKE 'sqlite_%' ORDER BY name") { try $0.text(0) ?? "" } }
        #expect(try named("table") == ["items", "snapshots"])
        #expect(try named("view") == ["activation_lock_view", "applecare_view", "devices_view"])
        #expect(try named("index") == ["snapshots_by_org"])

        // SQLite keeps each statement as written, less `IF NOT EXISTS` and the `;`: abapit's items table and two views
        // are abapit's text.
        let abapit = Schema.abapit.components(separatedBy: ";\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " IF NOT EXISTS", with: "")
        }
        for name in ["items", "devices_view", "applecare_view"] {
            let stored = try file.rows("SELECT sql FROM sqlite_master WHERE name = '\(name)'") { try $0.text(0) ?? "" }
            #expect(stored.count == 1 && abapit.contains { Array($0.utf8) == Array(stored[0].utf8) }, "\(name): \(stored)")
        }
    }

    /// A file at version 1 opens as it is: the additions aren't run again (they would fail: a column can't be added twice).
    @Test func aCurrentFileOpensWithoutMigratingAgain() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let org = Scratch.apple("acme")
        let id = try await SnapshotStore(storage: .folder(folder), appVersion: "1").record(org: org, takenAt: Scratch.noon, resources: [:])
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readWrite)
        #expect(try await store.snapshots(org: org).map(\.id) == [id])
    }

    /// abapit's own file is never changed in place: one copied in, or one with a second name (a hard link) there, is
    /// refused, and its bytes and its mode stay as they were. The import (a later PR) reads abapit's file and copies rows.
    @Test(arguments: [false, true])
    func abapitsFileIsRefusedAndLeftAsItIs(hardLinked: Bool) async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        // abapit's file, as abapit leaves it, but wider (a copy keeps the copier's mode).
        let original = hardLinked ? Scratch.path(root.appending(path: "abapit-history.sqlite")) : path
        #expect(FileManager.default.createFile(atPath: original, contents: nil, attributes: [.posixPermissions: 0o644]))
        do {
            let file = try Scratch.open(original)
            try file.execute(Schema.abapit)
            try file.execute("""
                INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors) \
                VALUES ('2026-01-01T00:00:00Z', 'BUSINESSAPI.x', 'Example', 'business', '0.9.0', '{}')
                """)
        }
        if hardLinked { #expect(link(original, path) == 0) }
        let before = try Data(contentsOf: URL(filePath: path))

        #expect(throws: hardLinked ? SnapshotStore.Failure.hardLinked(path: path) : .notThisAppsFile(path: path)) {
            _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        }
        #expect(try Data(contentsOf: URL(filePath: path)) == before)
        #expect(Scratch.mode(path) == 0o644)
        #expect(!Scratch.exists(path + "-journal"))
        #expect(try Scratch.open(path).userVersion() == 0)
        #expect(SnapshotStore.Failure.notThisAppsFile(path: path).message.contains("import abapit's history instead"))
    }

    /// The empty-file check is made again under the write lock (the review's probe, 2026-11-20): another connection holds
    /// `BEGIN IMMEDIATE` when the store first looks and sees an empty file, then makes abapit's tables and commits. The
    /// store refuses the file and leaves it at version 0.
    @Test func aFileFilledAfterTheFirstLookIsRefusedUnderTheLock() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        let other = Unchecked<SQLiteDatabase?>(nil)
        #expect(throws: SnapshotStore.Failure.notThisAppsFile(path: path)) {
            _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(SnapshotStore.Failure) in
                switch step {
                case .opening:
                    // The file exists, empty; the other connection takes the write lock first.
                    other.value = try? Scratch.open(path)
                    try? other.value?.execute("BEGIN IMMEDIATE")
                case .foundEmpty:
                    // The store has seen it empty; the other fills it and lets go.
                    try? other.value?.execute(Schema.abapit)
                    try? other.value?.execute("COMMIT")
                default:
                    break
                }
            }
        }
        other.value = nil
        let file = try Scratch.open(path)
        #expect(try file.userVersion() == 0)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'snapshots'") == 1)
        #expect(try file.rows("PRAGMA table_info(snapshots)") { try $0.text(1) ?? "" }.contains("org_id") == false)
    }

    /// An empty file this app didn't make is made this app's (a file left empty by a crash before its schema).
    @Test func anEmptyFileWithOneNameIsMadeThisAppsOwn() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readWrite)
        #expect(try Scratch.open(path).userVersion() == 1)
    }

    /// abapit's two views and the new one read what a snapshot records.
    @Test func theViewsReadWhatIsRecorded() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let id = try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: [
            "devices": [Scratch.device("SERIAL0001")],
            "applecare": [Resource(type: "appleCareCoverage", id: "COVER0001", attributes: [
                "serialNumber": .string("SERIAL0001"), "description": .string("AppleCare+"), "status": .string("ACTIVE"),
                "endDateTime": .string("2027-01-01T00:00:00Z"),
            ])],
            SnapshotStore.activationLockResource: [Resource(type: "activationLockStatus", id: "SERIAL0001", attributes: [
                "isLocked": .bool(true), "lockType": .string("USER"),
            ])],
        ])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        let row = { (sql: String, count: Int32) in
            try file.rows(sql) { row in try (0..<count).map { try row.text($0) ?? "NULL" } }
        }
        #expect(try row("SELECT * FROM devices_view", 8)
                == [["\(id)", "2026-11-18T11:06:40Z", "Example acme", "SERIAL0001", "MacBook Air", "Mac", "ASSIGNED", "2025-01-02T03:04:05Z"]])
        #expect(try row("SELECT * FROM applecare_view", 7)
                == [["\(id)", "2026-11-18T11:06:40Z", "Example acme", "SERIAL0001", "AppleCare+", "ACTIVE", "2027-01-01T00:00:00Z"]])
        #expect(try row("SELECT * FROM activation_lock_view", 7)
                == [["\(id)", "2026-11-18T11:06:40Z", "acme", "Example acme", "SERIAL0001", "1", "USER"]])
    }

    /// Python's `json.dumps(value, sort_keys=True)`, the outputs written in from Python 3.12: keys by code point at every
    /// depth (`B` before `a`; `e` + U+0301 before U+00E9), every scalar outside printable ASCII escaped in lowercase hex, a
    /// surrogate pair above U+FFFF, U+007F escaped, `~` and the space kept.
    @Test func rowsAreWrittenAsAbapitWritesThem() async throws {
        let nested: JSONValue = .object([
            "b": .number("1"), "a": .object(["d": .array([.number("1"), .object(["z": .null, "y": .bool(true)])]), "c": .string("x")]),
            "B": .bool(false), "e": .array([]), "f": .object([:]),
        ])
        #expect(StoredJSON.text(nested) == #"{"B": false, "a": {"c": "x", "d": [1, {"y": true, "z": null}]}, "b": 1, "e": [], "f": {}}"#)
        let escaped: JSONValue = .object([
            "\u{E9}": .string("caf\u{E9}"), "e\u{301}": .string("\u{1F600}"),
            "q": .string("a\"b\\c\nd\te\u{08}f\u{0C}g\rh\u{01}i\u{7F}j~ k"),
        ])
        #expect(StoredJSON.text(escaped)
                == #"{"e\u0301": "\ud83d\ude00", "q": "a\"b\\c\nd\te\bf\fg\rh\u0001i\u007fj~ k", "\u00e9": "caf\u00e9"}"#)
        // abapit's `json.dumps(errors)` kept the collectors' order; a Swift dictionary has none, so keys are sorted.
        #expect(StoredJSON.text(.object(["devices": .string("boom"), "applecare_partial": .string("2 device(s) failed")]))
                == #"{"applecare_partial": "2 device(s) failed", "devices": "boom"}"#)
        // The one deviation: a number keeps its text, where Python writes what it read again (in brackets).
        for (text, python) in [("-0", "0"), ("1.50", "1.5"), ("1e2", "100.0"), ("3.0e-5", "3e-05"), ("1e400", "Infinity")] {
            #expect(StoredJSON.text(.number(text)) == text, "Python writes \(python)")
        }

        // And that text is what a record writes.
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon,
                               resources: ["devices": [Resource(type: "orgDevices", id: "SERIAL0001", attributes: escaped.object ?? [:])]],
                               errors: ["devices": "caf\u{E9}"])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        #expect(try file.rows("SELECT attributes FROM items") { try $0.text(0) ?? "" } == [StoredJSON.text(escaped)])
        #expect(try file.rows("SELECT errors, notes FROM snapshots") { try [$0.text(0) ?? "", $0.text(1) ?? ""] }
                == [[#"{"devices": "caf\u00e9"}"#, "{}"]])
    }

    /// `taken_at` as abapit's `strftime("%Y-%m-%dT%H:%M:%SZ")` writes it: UTC, whole seconds, fractions dropped.
    @Test func takenAtIsAbapitsText() {
        #expect(Schema.takenAt(Scratch.noon) == "2026-11-18T11:06:40Z")
        #expect(Schema.takenAt(Scratch.noon.addingTimeInterval(0.999)) == "2026-11-18T11:06:40Z")
        #expect(Schema.takenAt(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }
}
