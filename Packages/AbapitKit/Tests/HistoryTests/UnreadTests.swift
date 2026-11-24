import Darwin
import Foundation
import JSONAPI
import Orgs
import SQLite3
import Testing
@testable import History

/// Which devices a per-device sweep didn't read (`snapshots.unread`, schema version 3): the migration from version 2, the column as it
/// is written and read back, and what an import and an export copy do with it. "Not recorded" (`{}`, a missing key) is never "every
/// device was read".
@Suite("Unread devices")
struct UnreadTests {
    static let acme = Scratch.apple("acme")

    /// A version-2 file as the previous build wrote it: version 1's script and version 2's, never version 3's.
    static func versionTwoFile() throws -> (root: URL, folder: URL, path: String) {
        let root = try Scratch.folder()
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let file = try Scratch.open(path)
        try file.execute(Schema.toVersion1 + Schema.toVersion2)
        try file.execute("""
            INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors, org_id, notes, counts) \
            VALUES ('2026-01-01T00:00:00Z', 'BUSINESSAPI.x', 'Example', 'business', 'swiftabapit 1', '{"applecare": "HTTP 500"}', 'acme', '{}', '{"devices": 2, "applecare": 1}');
            INSERT INTO items VALUES (1, 'devices', 'SERIAL0001', '{"deviceModel": "Mac"}');
            INSERT INTO items VALUES (1, 'devices', 'SERIAL0002', '{"deviceModel": "Mac"}');
            INSERT INTO items VALUES (1, 'applecare', 'CARE1', '{"serialNumber": "SERIAL0001"}');
            INSERT INTO attention VALUES ('acme', 'check_in', 'SERIAL0001', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL, NULL);
            """)
        #expect(try file.userVersion() == 2)
        return (root, folder, path)
    }

    // MARK: migration

    /// A version-2 file migrates by `Schema.toVersion3` alone: every row of `snapshots` (the ten columns it had), `items` and `attention`
    /// is byte-identical, the version is 3, the old row's `unread` is `{}` ("not recorded"), and the mode is held.
    @Test func aVersionTwoFileMigratesAndKeepsEverything() async throws {
        let (root, folder, path) = try Self.versionTwoFile()
        defer { Scratch.remove(root) }
        let dump = {
            let file = try Scratch.open(path)
            let snapshots = try file.rows("SELECT * FROM snapshots ORDER BY id") { row in try (0..<10).map { try row.text(Int32($0)) ?? "NULL" }.joined(separator: "|") }
            let items = try file.rows("SELECT * FROM items ORDER BY snapshot_id, resource, item_id") { row in try (0..<4).map { try row.text(Int32($0)) ?? "NULL" }.joined(separator: "|") }
            let attention = try file.rows("SELECT * FROM attention") { row in try (0..<7).map { try row.text(Int32($0)) ?? "NULL" }.joined(separator: "|") }
            return snapshots + items + attention
        }
        let before = try dump()
        #expect(before.count == 5)

        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readWrite)
        #expect(try dump() == before)
        let file = try Scratch.open(path)
        #expect(try file.userVersion() == 3)
        #expect(try file.rows("SELECT unread FROM snapshots") { try $0.text(0) ?? "NULL" } == ["{}"])
        #expect(Scratch.mode(path) == 0o600)
        // The old row reads as "not recorded", never as "every device was read".
        let old = try #require(try await store.snapshots(org: Self.acme).first)
        #expect(old.unread == [:] && old.counts["applecare"] == 1)
        // The migrated file records as a new one does, and is not migrated again.
        let id = try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("S1")]], unread: ["applecare": ["S1"]])
        #expect(try await store.load(id, org: Self.acme).summary.unread == ["applecare": ["S1"]])
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(try Scratch.count(Scratch.open(path), "SELECT COUNT(*) FROM snapshots") == 2)
    }

    /// A new file is made at version 3, with the column and its default.
    @Test func aNewFileIsVersionThreeWithTheColumn() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        #expect(try file.userVersion() == 3 && Schema.version == 3)
        let columns = try file.rows("PRAGMA table_info(snapshots)") { try [$0.text(1) ?? "", $0.text(2) ?? "", $0.text(4) ?? "", String($0.integer(3))] }
        #expect(columns.last == ["unread", "TEXT", "'{}'", "1"], "\(columns)")
    }

    /// A foreign file at version 2 (`snapshots` without this app's columns, or no `attention` table) is refused before any write, and
    /// left as it was.
    @Test func aForeignFileAtVersionTwoIsRefusedAndLeftAsItIs() throws {
        for setup in ["CREATE TABLE snapshots (id INTEGER PRIMARY KEY, note TEXT); INSERT INTO snapshots VALUES (1, 'x'); PRAGMA user_version = 2;",
                      // This app's columns, but not its attention table.
                      "CREATE TABLE snapshots (id INTEGER PRIMARY KEY, org_id TEXT, counts TEXT); PRAGMA user_version = 2;"] {
            let root = try Scratch.folder()
            defer { Scratch.remove(root) }
            let folder = root.appending(path: "store")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let path = Scratch.path(folder.appending(path: "history.sqlite"))
            #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o644]))
            try Scratch.open(path).execute(setup)
            let before = try Data(contentsOf: URL(filePath: path))
            #expect(throws: SnapshotStore.Failure.notThisAppsFile(path: path)) { _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") }
            #expect(try Data(contentsOf: URL(filePath: path)) == before)
            #expect(Scratch.mode(path) == 0o644)
            #expect(try Scratch.open(path).userVersion() == 2)
        }
    }

    /// A file from a version after this one is read, never written, and its `unread` still reads.
    @Test func aNewerFileStaysReadOnlyAndItsUnreadReads() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let id = try await SnapshotStore(storage: .folder(folder), appVersion: "1")
            .record(org: Self.acme, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("S1")]], unread: ["applecare": ["S1"]])
        try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite"))).execute("PRAGMA user_version = 4")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readOnly(version: 4))
        await #expect(throws: SnapshotStore.Failure.readOnly(version: 4)) { try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: [:], unread: ["applecare": []]) }
        #expect(try await store.load(id, org: Self.acme).summary.unread == ["applecare": ["S1"]])
    }

    /// Two stores open one version-2 file: the second gets in between the first's reading the version and taking the write lock. The first
    /// reads the version again under the lock, finds 3, and doesn't migrate twice (which would fail: the column exists).
    @Test func twoStoresOpeningAVersionTwoFileMigrateItOnce() async throws {
        let (root, folder, path) = try Self.versionTwoFile()
        defer { Scratch.remove(root) }
        let steps = Shared<[String]>([]), second = Unchecked<SnapshotStore?>(nil)
        let first = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(SnapshotStore.Failure) in
            switch step {
            case .foundVersion2:
                steps.set(steps.value + ["found"])
                second.value = try SnapshotStore(storage: .folder(folder), appVersion: "1") { inner throws(SnapshotStore.Failure) in
                    if case .migrating = inner { steps.set(steps.value + ["second migrates"]) }
                }
            case .migrating:
                steps.set(steps.value + ["first migrates"])
            default:
                break
            }
        }
        #expect(steps.value == ["found", "second migrates"])
        #expect(first.access == .readWrite && second.value?.access == .readWrite)
        #expect(try Scratch.open(path).userVersion() == 3)
    }

    /// A v1 file of this app's shape that already has an `unread` column: version 3's script fails, and the whole migration is rolled back:
    /// the version stays 1 and no `attention` table is left behind.
    @Test func aFailedMigrationIsRolledBackWhole() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        try Scratch.open(path).execute(Schema.toVersion1 + "ALTER TABLE snapshots ADD COLUMN unread TEXT NOT NULL DEFAULT '{}';")
        #expect(throws: SnapshotStore.Failure.self) { _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") }
        let file = try Scratch.open(path)
        #expect(try file.userVersion() == 1)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'attention'") == 0)
    }

    /// A version-2 file this process can't write (mode 0400) used to open; it still does, read-only at the version it has, `unread` reading as
    /// `{}` ("not recorded") because the column isn't there. Nothing is written to it.
    @Test func aFileThatCantBeWrittenOpensReadOnlyAtItsVersion() async throws {
        for version in [Int32(1), 2] {
            let (root, folder, path) = try Self.versionTwoFile()
            defer { Scratch.remove(root) }
            if version == 1 {
                // The same file at version 1: no attention table either.
                let file = try Scratch.open(path)
                try file.execute("DROP TABLE attention; PRAGMA user_version = 1;")
            }
            #expect(chmod(path, 0o400) == 0)
            let before = try Data(contentsOf: URL(filePath: path))
            let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
            #expect(store.access == .notWritable(version: version), "version \(version)")
            let snapshots = try await store.snapshots(org: Self.acme)
            #expect(snapshots.count == 1 && snapshots[0].unread == [:] && snapshots[0].counts["applecare"] == 1, "version \(version): \(snapshots)")
            #expect(try await store.load(snapshots[0].id, org: Self.acme).resources["devices"]?.count == 2)
            await #expect(throws: SnapshotStore.Failure.notWritable(version: version)) { try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: [:]) }
            // The words say what is true: not that a newer abapit wrote it.
            do { try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: [:]) } catch {
                #expect(error.message == "The snapshot history can't be written; it is read and never changed. Check the file's permissions or the volume." && !error.message.contains("newer"), "\(error.message)")
            }
            #expect(try Data(contentsOf: URL(filePath: path)) == before && Scratch.mode(path) == 0o400)
            #expect(try Scratch.open(path).userVersion() == version)
        }
    }

    /// An unwritable version-1 file has no `attention` table, and never held a finding: `orgIDs()` and `state(org:)` read what the snapshots
    /// hold (so Add organization is not refused), and a dismissal or a snooze says the file can't be written.
    @Test func anUnwritableVersionOneFileReadsAttentionAsEmpty() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let file = try Scratch.open(path)
        try file.execute(Schema.toVersion1)
        try file.execute("""
            INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors, org_id, notes, counts) \
            VALUES ('2026-01-01T00:00:00Z', 'BUSINESSAPI.x', 'Example', 'business', 'swiftabapit 1', '{}', 'acme', '{}', '{}');
            """)
        #expect(chmod(path, 0o400) == 0)
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .notWritable(version: 1))
        #expect(try await store.orgIDs() == ["acme"])
        #expect(try await store.state(org: Self.acme).isEmpty)
        let words = "The snapshot history can't be written; it is read and never changed. Check the file's permissions or the volume."
        await #expect(throws: SnapshotStore.Failure.notWritable(version: 1)) { try await store.dismiss(org: Self.acme, rule: "r", subject: "A", at: Scratch.noon) }
        do { try await store.snooze(org: Self.acme, rule: "r", subject: "A", until: Scratch.noon) } catch { #expect(error.message == words) }
        do { try await store.seen(org: Self.acme, rule: "r", subjects: ["A"], at: Scratch.noon) } catch { #expect(error.message == words) }
        // A copy of it can still be made.
        try await store.exportCopy(to: URL(filePath: Scratch.path(root) + "/copy.sqlite"))
    }

    /// An empty file another store fills between the look and the lock is decided on the version found there, never assumed writable: a
    /// newer one is read-only; an older one (version 1) is migrated from where it stands.
    @Test func anEmptyFileFilledUnderTheLockIsDecidedOnItsVersion() async throws {
        for (fill, expect) in [("CREATE TABLE other (a); PRAGMA user_version = 4;", SnapshotStore.Access.readOnly(version: 4)),
                               (Schema.toVersion1, SnapshotStore.Access.readWrite)] {
            let root = try Scratch.folder()
            defer { Scratch.remove(root) }
            let folder = root.appending(path: "store")
            let store = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(SnapshotStore.Failure) in
                if case .foundEmpty(let path) = step { try? Scratch.open(path).execute(fill) }
            }
            #expect(store.access == expect, "\(fill)")
            let version = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite"))).userVersion()
            #expect(version == (expect == .readWrite ? 3 : 4), "\(fill)")
        }
    }

    /// Another build migrates the file past this one between this one's looking and its taking the lock: decided on the version read under
    /// the lock, the file is read-only, never `.readWrite`.
    @Test func aFileMigratedPastThisOneUnderTheLockIsReadOnly() async throws {
        let (root, folder, path) = try Self.versionTwoFile()
        defer { Scratch.remove(root) }
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(SnapshotStore.Failure) in
            if case .foundVersion2 = step { try? Scratch.open(path).execute("PRAGMA user_version = 4") }
        }
        #expect(store.access == .readOnly(version: 4))
        await #expect(throws: SnapshotStore.Failure.readOnly(version: 4)) { try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: [:]) }
    }

    // MARK: the column

    /// What a snapshot records reads back: each sweep's ids sorted by bytes, each once; an empty list is kept (a sweep that ran and missed
    /// none); a sweep with no key stays without one; a snapshot recorded with none says `{}`.
    @Test func theColumnIsWrittenSortedAndReadBack() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let id = try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("B"), Scratch.device("a")]],
                                        unread: ["applecare": ["b", "B", "a", "B"], "activation_lock": []])
        let summary = try await store.load(id, org: Self.acme).summary
        #expect(summary.unread == ["applecare": ["B", "a", "b"], "activation_lock": []], "\(summary.unread)")
        #expect(summary.unread["mdm_details"] == nil)
        let none = try await store.record(org: Self.acme, takenAt: Scratch.noon.addingTimeInterval(60), resources: [:])
        #expect(try await store.load(none, org: Self.acme).summary.unread == [:])
        // `newestRead` and `latest` hand the summary over with it.
        #expect(try await store.snapshots(org: Self.acme).first?.unread == [:])
    }

    /// Stored as JSON the other columns are stored as: keys sorted, ASCII, `", "` between members.
    @Test func theColumnIsStoredAsSortedJSON() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: [:], unread: ["applecare": ["S2", "S1"], "activation_lock": []])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        #expect(try file.rows("SELECT unread FROM snapshots") { try $0.text(0) ?? "" } == ["{\"activation_lock\": [], \"applecare\": [\"S1\", \"S2\"]}"])
    }

    /// A column changed outside the app says so, never an empty value.
    @Test func aColumnChangedOutsideTheAppSaysSo() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let id = try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: [:])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        for bad in ["[]", "not json", "{\"applecare\": 1}", "{\"applecare\": [1]}", "{\"applecare\": [null]}"] {
            try file.run("UPDATE snapshots SET unread = ?", [.text(bad)])
            await #expect(throws: SnapshotStore.Failure.corrupt("a snapshot's unread devices"), "\(bad)") { try await store.load(id, org: Self.acme) }
        }
    }

    // MARK: import and export

    /// abapit never recorded which devices a sweep missed: an imported snapshot writes `{}`.
    @Test func anImportedSnapshotWritesNoUnread() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let id = try #require(try await store.recordImported(org: Self.acme, takenAt: Scratch.noon, writtenBy: "abapit 0.2.0",
                                                             resources: ["devices": [Scratch.device("S1")]], errors: ["applecare": "abapit error"]))
        #expect(try await store.load(id, org: Self.acme).summary.unread == [:])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        #expect(try file.rows("SELECT unread FROM snapshots") { try $0.text(0) ?? "" } == ["{}"])
    }

    /// An export copy carries the column, whole and narrowed to some orgs.
    @Test func anExportCopyKeepsUnread() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        try await store.record(org: Self.acme, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("S1")]], unread: ["applecare": ["S1"]])
        try await store.record(org: Scratch.apple("other"), takenAt: Scratch.noon, resources: [:], unread: ["activation_lock": ["Z9"]])
        let whole = Scratch.path(root) + "/whole.sqlite", narrowed = Scratch.path(root) + "/narrowed.sqlite"
        try await store.exportCopy(to: URL(filePath: whole))
        try await store.exportCopy(to: URL(filePath: narrowed), orgs: ["acme"])
        let unread = { (path: String) in try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READONLY).rows("SELECT org_id, unread FROM snapshots ORDER BY id") { try [$0.text(0) ?? "", $0.text(1) ?? ""] } }
        #expect(try unread(whole) == [["acme", "{\"applecare\": [\"S1\"]}"], ["other", "{\"activation_lock\": [\"Z9\"]}"]])
        #expect(try unread(narrowed) == [["acme", "{\"applecare\": [\"S1\"]}"]])
        // The copy opens as a store of its own, `unread` and all.
        let folder = root.appending(path: "opened")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(atPath: narrowed, toPath: Scratch.path(folder) + "/history.sqlite")
        let opened = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(try await opened.snapshots(org: Self.acme).first?.unread == ["applecare": ["S1"]])
    }
}
