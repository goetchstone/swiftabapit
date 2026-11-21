import Darwin
import Foundation
import JSONAPI
import Orgs
import SQLite3
import Testing
@testable import History

/// abapit's `history.sqlite` read for the import (plan Phase 3): opened read-only and never changed (bytes, mode, mtime, no
/// side file, a connection that can't write), refused unless it is abapit's schema, and read a snapshot at a time with its error
/// text never carried. Over synthetic abapit-shaped files in a temporary folder; the operator's real file is never read.
@Suite("abapit history, read")
struct AbapitImportTests {
    typealias Failure = AbapitHistory.Failure

    /// An abapit `history.sqlite` as abapit's own `SCHEMA` makes it, with these rows. Text in the file is invented.
    @discardableResult
    static func makeFile(in folder: URL, name: String = "history.sqlite", snapshots: [(id: Int64, takenAt: String, client: String, scope: String, version: String, errors: String)] = [],
                         items: [(snapshot: Int64, resource: String, id: String, attributes: String)] = [], mode: mode_t = 0o600) throws -> String {
        let path = Scratch.path(folder) + "/" + name
        let database = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try database.execute(Schema.abapit)
        for s in snapshots {
            try database.run("INSERT INTO snapshots (id, taken_at, org_client_id, org_name, org_scope, abapit_version, errors) VALUES (?, ?, ?, ?, ?, ?, ?)",
                             [.integer(s.id), .text(s.takenAt), .text(s.client), .text("Example org"), .text(s.scope), .text(s.version), .text(s.errors)])
        }
        for i in items {
            try database.run("INSERT INTO items VALUES (?, ?, ?, ?)", [.integer(i.snapshot), .text(i.resource), .text(i.id), .text(i.attributes)])
        }
        chmod(path, mode)
        return path
    }

    static let rows: (snapshots: [(id: Int64, takenAt: String, client: String, scope: String, version: String, errors: String)],
                      items: [(snapshot: Int64, resource: String, id: String, attributes: String)]) = (
        [(1, "2026-09-01T08:00:00Z", "CLIENT-A", "business", "0.2.0", "{}"),
         (4, "2026-09-02T08:00:00Z", "CLIENT-A", "business", "0.2.0", #"{"applecare": "HTTPError: 403 https://api-business.apple.com/v1/x?token=CANARYERRORTEXT"}"#)],
        [(1, "devices", "SERIAL0002", #"{"deviceModel": "B", "serialNumber": "SERIAL0002"}"#),
         (1, "devices", "SERIAL0001", #"{"deviceModel": "A", "serialNumber": "SERIAL0001"}"#),
         (1, "mdm_servers", "SVC1", #"{"serverName": "Main"}"#),
         (4, "devices", "SERIAL0001", #"{"deviceModel": "A", "serialNumber": "SERIAL0001"}"#)])

    /// Everything about a file that a read must not change, and the names in its folder.
    struct Footprint: Equatable {
        let bytes: Data, mode: mode_t, modified: timespec, names: [String]
        init(_ path: String) throws {
            bytes = try Data(contentsOf: URL(filePath: path))
            var info = stat()
            guard stat(path, &info) == 0 else { throw CocoaError(.fileNoSuchFile) }
            mode = info.st_mode & 0o7777
            modified = info.st_mtimespec
            names = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent).sorted()
        }
        static func == (a: Footprint, b: Footprint) -> Bool {
            a.bytes == b.bytes && a.mode == b.mode && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec && a.names == b.names
        }
    }

    // MARK: read-only

    /// Opening and reading every snapshot changes nothing: the file's bytes, mode and modification time, and no `-journal`,
    /// `-wal` or `-shm` beside it (the folder holds the one name). The connection reports itself read-only and a write through it
    /// fails.
    @Test func readingNeverChangesTheFileOrLeavesAFileBesideIt() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let before = try Footprint(path)
        let source = try AbapitHistory(file: URL(filePath: path))
        #expect(await source.refusesWrites())
        #expect(source.readsByDescriptor, "SQLite reads the descriptor that was checked, not the path again (where the system allows it)")
        for header in try await source.headers() { _ = try await source.load(header) }
        #expect(try Footprint(path) == before)
        #expect(before.names == ["history.sqlite"])
    }

    /// A read-only file in a folder nobody can write to still reads, and is left as it was.
    @Test func aReadOnlyFileInAReadOnlyFolderReads() async throws {
        let folder = try Scratch.folder()
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items, mode: 0o400)
        chmod(Scratch.path(folder), 0o500)
        defer { chmod(Scratch.path(folder), 0o700); Scratch.remove(folder) }
        let before = try Footprint(path)
        let source = try AbapitHistory(file: URL(filePath: path))
        #expect(try await source.headers().count == 2)
        #expect(try Footprint(path) == before)
    }

    /// A crashed abapit's file with its hot journal, built as a crash leaves it: a transaction whose pages spilled to the database
    /// file before commit, the file and its journal copied while it is open, then the transaction rolled back. Read as it
    /// stands (`immutable`) the file holds a half-written snapshot that `integrity_check` calls ok.
    static func crashed(in folder: URL) throws -> (file: String, committed: Int, torn: Int) {
        let work = Scratch.path(folder) + "/work", crash = Scratch.path(folder) + "/crash"
        mkdir(work, 0o700)
        mkdir(crash, 0o700)
        let path = work + "/history.sqlite"
        let database = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try database.execute(Schema.abapit)
        try database.run("INSERT INTO snapshots (id, taken_at, org_client_id, org_name, org_scope, abapit_version, errors) VALUES (1, '2026-09-01T08:00:00Z', 'CLIENT-TORN', 'Org', 'business', '0.2.0', '{}')")
        for i in 0..<50 { try database.run("INSERT INTO items VALUES (1, 'devices', ?, ?)", [.text("COMMITTED\(i)"), .text(#"{"deviceModel": "A"}"#)]) }
        try database.execute("PRAGMA cache_size = 2")
        try database.execute("PRAGMA cache_spill = ON")
        try database.execute("BEGIN")
        try database.run("INSERT INTO snapshots (id, taken_at, org_client_id, org_name, org_scope, abapit_version, errors) VALUES (2, '2026-09-02T08:00:00Z', 'CLIENT-TORN', 'Org', 'business', '0.2.0', '{}')")
        for i in 0..<2000 {
            try database.run("INSERT INTO items VALUES (2, 'devices', ?, ?)", [.text("UNCOMMITTED\(i)"), .text("{\"deviceModel\": \"" + String(repeating: "B", count: 200) + "\"}")])
        }
        try database.run("DELETE FROM items WHERE snapshot_id = 1 AND item_id >= 'COMMITTED25'")
        try FileManager.default.copyItem(atPath: path, toPath: crash + "/history.sqlite")
        try FileManager.default.copyItem(atPath: path + "-journal", toPath: crash + "/history.sqlite-journal")
        try database.execute("ROLLBACK")
        return (crash + "/history.sqlite", 50, 2000)
    }

    /// The torn read (the review of PR 36): with `immutable` an unfinished write's pages are imported as a real snapshot. A
    /// non-empty journal beside the file is refused in words (how to finish the rollback), and nothing is read or changed.
    @Test func aHotJournalIsRefusedNotReadAround() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let (path, _, _) = try Self.crashed(in: folder)
        let journal = path + "-journal"
        #expect(try Data(contentsOf: URL(filePath: journal)).count > 0, "the crash left a hot journal")
        let before = try Footprint(path), journalBefore = try Data(contentsOf: URL(filePath: journal))
        #expect(throws: Failure.unfinishedWrite(path: path)) { try AbapitHistory(file: URL(filePath: path)) }
        #expect(Failure.unfinishedWrite(path: path).message.contains("sqlite3") && Failure.unfinishedWrite(path: path).message.contains("unfinished write"))
        #expect(try Footprint(path) == before)
        #expect(try Data(contentsOf: URL(filePath: journal)) == journalBefore)
        // After the operator lets SQLite finish the rollback (any normal open does), the file imports, and holds only what was committed.
        let recovered = try Scratch.open(path)
        #expect(try Scratch.count(recovered, "SELECT COUNT(*) FROM snapshots") == 1)
        let source = try AbapitHistory(file: URL(filePath: path))
        let headers = try await source.headers()
        #expect(headers.count == 1)
        #expect(try await source.load(headers[0]).resources["devices"]?.count == 50)
    }

    /// The same for a WAL left beside the file; an empty journal or WAL is nothing; a journal that is a link is refused too.
    @Test func aWalOrALinkedJournalIsRefusedAndAnEmptyJournalIsNot() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        FileManager.default.createFile(atPath: path + "-journal", contents: nil)
        FileManager.default.createFile(atPath: path + "-wal", contents: nil)
        #expect(try await AbapitHistory(file: URL(filePath: path)).headers().count == 2, "empty ones are leftovers, not unfinished writes")
        try Data(repeating: 1, count: 32).write(to: URL(filePath: path + "-wal"))
        #expect(throws: Failure.unfinishedWrite(path: path)) { try AbapitHistory(file: URL(filePath: path)) }
        try FileManager.default.removeItem(atPath: path + "-wal")
        try FileManager.default.removeItem(atPath: path + "-journal")
        symlink("/nonexistent", path + "-journal")
        #expect(throws: Failure.unfinishedWrite(path: path)) { try AbapitHistory(file: URL(filePath: path)) }
    }

    /// Whether the files beside it can be looked at is part of the answer: if they can't, nothing is imported. A name of 250 bytes
    /// opens, but `<name>-journal` is too long to look at (`ENAMETOOLONG`), the one way to make the file reachable and its
    /// sibling not, without the sandbox.
    @Test func aSiblingThatCannotBeLookedAtRefusesTheImport() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let name = String(repeating: "h", count: 250)
        let short = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let path = Scratch.path(folder) + "/" + name
        try FileManager.default.moveItem(atPath: short, toPath: path)
        #expect(throws: Failure.unchecked(path: path, errno: ENAMETOOLONG)) { try AbapitHistory(file: URL(filePath: path)) }
        #expect(Failure.unchecked(path: path, errno: EPERM).message.contains("couldn't be checked"))
        #expect(try Footprint(path).names == [name], "nothing was made beside it")
    }

    // MARK: refusing what isn't abapit's

    private func refused(_ path: String, sourceOf: String? = nil, _ check: (Failure) -> Bool) throws {
        let before = try Footprint(sourceOf ?? path)
        #expect(throws: Failure.self) { try AbapitHistory(file: URL(filePath: path)) }
        do { _ = try AbapitHistory(file: URL(filePath: path)) } catch { #expect(check(error), "\(error)") }
        #expect(try Footprint(sourceOf ?? path) == before, "a refused file is left as it was")
    }

    @Test func aFileThisAppWroteIsRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        try refused(Scratch.path(folder) + "/history.sqlite") { if case .notAbapits(let why) = $0 { why.contains("this app") } else { false } }
    }

    @Test func aNewerSchemaVersionIsRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let database = try Scratch.open(path)
        try database.execute("PRAGMA user_version = 7")
        try refused(path) { if case .notAbapits(let why) = $0 { why.contains("7") } else { false } }
    }

    @Test func aDatabaseWithTheTablesButOtherColumnsIsRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = Scratch.path(folder) + "/history.sqlite"
        let database = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try database.execute("CREATE TABLE snapshots (id INTEGER PRIMARY KEY, taken_at TEXT, org_id TEXT); CREATE TABLE items (snapshot_id INTEGER, resource TEXT, item_id TEXT, attributes TEXT);")
        try refused(path) { if case .notAbapits(let why) = $0 { why.contains("snapshots") } else { false } }
    }

    @Test func anotherProgramsDatabaseIsRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = Scratch.path(folder) + "/other.sqlite"
        let database = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try database.execute("CREATE TABLE notes (a TEXT)")
        try refused(path) { if case .notAbapits(let why) = $0 { why.contains("no snapshots table") } else { false } }
    }

    @Test func aFileThatIsNotSQLiteIsRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = Scratch.path(folder) + "/history.sqlite"
        try Data("not a database, only text that is long enough to pass for a header ...........".utf8).write(to: URL(filePath: path))
        try refused(path) { if case .notAbapits = $0 { true } else { false } }
    }

    @Test func aFolderAndAMissingFileAreRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        #expect(throws: Failure.notAFile(path: Scratch.path(folder))) { try AbapitHistory(file: folder) }
        #expect(throws: Failure.self) { try AbapitHistory(file: folder.appending(path: "missing.sqlite")) }
    }

    /// Where the descriptor's name isn't used (the fallback to the path), the path must still lead to the file that was checked: one
    /// replaced between the check and the open is refused, and nothing is read from it.
    @Test func aPathReplacedBeforeTheFallbackOpenIsRefused() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let other = try Self.makeFile(in: folder, name: "other.sqlite", snapshots: [(9, "2026-09-09T08:00:00Z", "OTHER", "business", "0.2.0", "{}")])
        #expect(throws: Failure.changed(path: path)) {
            try AbapitHistory(file: URL(filePath: path), viaDescriptor: false, beforeOpen: { rename(other, path) })
        }
        // Unchanged, the path route reads the same file.
        let again = try Self.makeFile(in: folder, name: "again.sqlite", snapshots: Self.rows.snapshots, items: Self.rows.items)
        let source = try AbapitHistory(file: URL(filePath: again), viaDescriptor: false, beforeOpen: nil)
        let count = try await source.headers().count
        #expect(!source.readsByDescriptor && count == 2)
    }

    /// Only "can't open" and a permission refusal fall back to the path; another answer is the file's.
    @Test func onlyACantOpenOrAPermissionRefusalFallsBack() {
        #expect(AbapitHistory.mayFallBack(SQLITE_CANTOPEN) && AbapitHistory.mayFallBack(SQLITE_CANTOPEN | (6 << 8)))
        #expect(AbapitHistory.mayFallBack(SQLITE_PERM) && AbapitHistory.mayFallBack(SQLITE_AUTH))
        for code in [SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_ERROR, SQLITE_IOERR, SQLITE_BUSY, SQLITE_READONLY] { #expect(!AbapitHistory.mayFallBack(code), "\(code)") }
    }

    /// A FIFO where the file should be is refused without opening it (no hang), and the file SQLite reads is the one checked.
    @Test func aFIFOIsRefusedWithoutHanging() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = Scratch.path(folder) + "/fifo.sqlite"
        #expect(mkfifo(path, 0o600) == 0)
        #expect(throws: Failure.notAFile(path: path)) { try AbapitHistory(file: URL(filePath: path)) }
    }

    /// A link as the file, or a folder on its way, is refused and nothing behind it is opened.
    @Test func aLinkIsRefusedAsTheFileAndOnThePath() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let real = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let link = Scratch.path(folder) + "/link.sqlite"
        symlink(real, link)
        try refused(link, sourceOf: real) { $0 == .link(path: link) }
        let inner = Scratch.path(folder) + "/inner"
        mkdir(inner, 0o700)
        let linkedFolder = Scratch.path(folder) + "/linked"
        symlink(inner, linkedFolder)
        _ = try Self.makeFile(in: URL(filePath: inner, directoryHint: .isDirectory), snapshots: Self.rows.snapshots)
        try refused(linkedFolder + "/history.sqlite", sourceOf: inner + "/history.sqlite") { if case .link = $0 { true } else { false } }
    }

    // MARK: reading

    @Test func snapshotsAreReadOldestFirstWithTheirItemsAndOnlyTheNamesOfTheirErrors() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let source = try AbapitHistory(file: URL(filePath: path))
        let headers = try await source.headers()
        #expect(headers.map(\.id) == [1, 4])
        #expect(headers.map(\.takenAt) == ["2026-09-01T08:00:00Z", "2026-09-02T08:00:00Z"])
        #expect(headers.map(\.clientID) == ["CLIENT-A", "CLIENT-A"] && headers.map(\.scope) == ["business", "business"])
        #expect(headers[0].writtenBy == "abapit 0.2.0")
        let first = try await source.load(headers[0])
        #expect(first.resources.keys.sorted() == ["devices", "mdm_servers"])
        #expect(first.resources["devices"]?.map(\.id) == ["SERIAL0001", "SERIAL0002"])
        #expect(first.resources["devices"]?.first == Resource(type: "devices", id: "SERIAL0001",
                                                              attributes: ["deviceModel": .string("A"), "serialNumber": .string("SERIAL0001")]))
        #expect(first.errorKeys == [])
        let second = try await source.load(headers[1])
        #expect(second.errorKeys == ["applecare"], "the key of an error, never its text")
        #expect(!"\(second)".contains("CANARYERRORTEXT") && !"\(second)".contains("api-business"), "error text never travels")
    }

    /// The version column is carried only when it looks like a version: text from the file isn't copied into a row as it stands.
    @Test func aVersionThatDoesntLookLikeOneIsNotCarried() {
        func version(_ text: String) -> String { AbapitHistory.Header(id: 1, takenAt: "", clientID: "", scope: "", version: text).writtenBy }
        #expect(version("0.2.0") == "abapit 0.2.0")
        #expect(version("0.3.0+dev-1") == "abapit 0.3.0+dev-1")
        #expect(version("") == "abapit")
        #expect(version("swiftabapit 1") == "abapit")
        #expect(version("0.2.0 https://example.com/?t=CANARY") == "abapit")
        #expect(version(String(repeating: "1", count: 33)) == "abapit")
    }

    /// A row that doesn't read fails that snapshot only, in words that quote nothing from it.
    @Test func aRowThatDoesNotReadFailsItsSnapshotAlone() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: [(1, "2026-09-01T08:00:00Z", "C", "business", "0.2.0", "{}"), (2, "2026-09-02T08:00:00Z", "C", "business", "0.2.0", "not json CANARYBAD")],
                                     items: [(1, "devices", "S1", "[1, 2] CANARYBAD"), (2, "devices", "S2", #"{"a": "b"}"#)])
        let source = try AbapitHistory(file: URL(filePath: path))
        let headers = try await source.headers()
        for header in headers {
            await #expect(throws: Failure.self) { try await source.load(header) }
        }
        do { _ = try await source.load(headers[0]) } catch { #expect(!error.message.contains("CANARYBAD")) }
        do { _ = try await source.load(headers[1]) } catch { #expect(!error.message.contains("CANARYBAD")) }
    }

    @Test func aLoneSurrogateEscapeIsCorruptNotU_FFFD() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: [(1, "2026-09-01T08:00:00Z", "C", "business", "0.2.0", "{}")],
                                     items: [(1, "users", "U1", #"{"name": "\ud800"}"#)])
        let source = try AbapitHistory(file: URL(filePath: path))
        await #expect(throws: Failure.self) { try await source.load(try await source.headers()[0]) }
    }
}

/// The store's two additions for the import and the export: `recordImported`, and `exportCopy`.
@Suite("Snapshot store, import and export")
struct ImportedRecordTests {
    typealias Failure = SnapshotStore.Failure

    /// An imported snapshot is recorded with abapit's own time and writer, `counts` filled for every resource it holds, and read
    /// by `latest` like any other; the same snapshot again is nothing, in the same call and in a later one.
    @Test func importingTheSameSnapshotAgainWritesNothing() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let taken = Date(timeIntervalSince1970: 1_788_249_600)
        let id = try await store.recordImported(org: org, takenAt: taken, writtenBy: "abapit 0.2.0", resources: ["devices": [Scratch.device("S1")], "mdm_servers": []],
                                                errors: ["applecare": "abapit error"])
        let first = try #require(id)
        let summary = try await store.load(first, org: org).summary
        #expect(summary.writtenBy == "abapit 0.2.0" && summary.takenAt == Schema.takenAt(taken))
        #expect(summary.counts == ["devices": 1, "mdm_servers": 0] && summary.errors == ["applecare": "abapit error"])
        guard case .read(let copy)? = try await store.latest("devices", org: org) else { Issue.record("latest should read the imported snapshot"); return }
        #expect(copy.items.map(\.id) == ["S1"])
        #expect(try await store.recordImported(org: org, takenAt: taken, writtenBy: "abapit 0.2.0", resources: ["devices": [Scratch.device("S1")]]) == nil)
        #expect(try await store.snapshots(org: org).count == 1)
        // Another time, another org, another writer, or a snapshot this app took: not the same one.
        #expect(try await store.recordImported(org: org, takenAt: taken.addingTimeInterval(60), writtenBy: "abapit 0.2.0", resources: [:]) != nil)
        #expect(try await store.recordImported(org: Scratch.apple("other"), takenAt: taken, writtenBy: "abapit 0.2.0", resources: [:]) != nil)
        #expect(try await store.recordImported(org: org, takenAt: taken, writtenBy: "abapit 0.3.0", resources: [:]) != nil)
        try await store.record(org: org, takenAt: taken.addingTimeInterval(120), resources: [:])
        #expect(try await store.recordImported(org: org, takenAt: taken.addingTimeInterval(120), writtenBy: "abapit 0.2.0", resources: [:]) != nil)
    }

    // MARK: order

    /// A snapshot this app took, then an older one imported afterwards (it gets the higher id): the native one is still the
    /// newest, for the listing, for `latest` and for `prune`, which keeps it. The id only breaks a tie.
    @Test func anOlderImportNeverOutranksANewerNativeSnapshot() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let native = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("NATIVE1")]])
        let old = Scratch.noon.addingTimeInterval(-30 * 86_400)
        let imported = try #require(try await store.recordImported(org: org, takenAt: old, writtenBy: "abapit 0.2.0", resources: ["devices": [Scratch.device("OLDER1")]],
                                                                   errors: ["applecare": "abapit error"]))
        #expect(imported > native, "the import has the higher id")
        #expect(try await store.snapshots(org: org).map(\.id) == [native, imported])
        guard case .read(let copy)? = try await store.latest("devices", org: org) else { Issue.record("latest should read the native snapshot"); return }
        #expect(copy.summary.id == native && copy.items.map(\.id) == ["NATIVE1"])
        #expect(try await store.prune(org: org, keep: 1) == 1)
        #expect(try await store.snapshots(org: org).map(\.id) == [native])
    }

    /// Two abapit files imported newer first: the order is by time, and `latest` answers from the newer snapshot, with the older
    /// file's failure never the newest attempt. The good copy behind a failure is the newest good one by time.
    @Test func twoFilesImportedNewerFirstAreStillOrderedByTime() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let t1 = Scratch.noon, t0 = t1.addingTimeInterval(-86_400), tm1 = t1.addingTimeInterval(-2 * 86_400)
        // File two (newer): a failure at t1 and a good read at t0. File one (older): a good read at tm1. Imported: two, then one.
        _ = try await store.recordImported(org: org, takenAt: t0, writtenBy: "abapit 0.2.0", resources: ["devices": [Scratch.device("T0")]])
        _ = try await store.recordImported(org: org, takenAt: t1, writtenBy: "abapit 0.2.0", resources: [:], errors: ["devices": "abapit error"])
        _ = try await store.recordImported(org: org, takenAt: tm1, writtenBy: "abapit 0.2.0", resources: ["devices": [Scratch.device("TM1")]])
        #expect(try await store.snapshots(org: org).map(\.takenAt) == [Schema.takenAt(t1), Schema.takenAt(t0), Schema.takenAt(tm1)])
        guard case .failed(let tried, "abapit error", let newest)? = try await store.latest("devices", org: org) else { Issue.record("latest"); return }
        #expect(tried.takenAt == Schema.takenAt(t1) && newest?.summary.takenAt == Schema.takenAt(t0) && newest?.items.map(\.id) == ["T0"], "the newest good copy by time, not the last recorded")
    }

    /// Text order is time order only because every writer writes `Schema.takenAt`: fixed width, UTC, zero-padded. Every write goes
    /// through `insert` (`record` and `recordImported`), which renders the time that way, whatever the caller passed.
    @Test func everyWriterWritesFixedWidthTimes() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        for seconds in [-2_000_000_000.0, 0, 951_782_400.5, 1_795_000_000.999, 4_102_444_800] {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(Schema.takenAt(date).utf8.count == 20 && Schema.takenAt(date).hasSuffix("Z"), "\(Schema.takenAt(date))")
            let id = try await store.record(org: org, takenAt: date, resources: [:])
            let other = try #require(try await store.recordImported(org: org, takenAt: date, writtenBy: "abapit 1", resources: [:]))
            for found in [id, other] { #expect(try await store.load(found, org: org).summary.takenAt == Schema.takenAt(date)) }
        }
        let order = try await store.snapshots(org: org).map(\.takenAt)
        #expect(order == order.sorted(by: >), "text order is time order")
    }

    // MARK: export

    private func filled() async throws -> (store: SnapshotStore, folder: URL) {
        let folder = try Scratch.folder()
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: ["devices": [Scratch.device("S1"), Scratch.device("S2")]])
        return (store, folder)
    }

    /// The copy is a database of its own, `0600`, holding what the store holds, with no journal beside it.
    @Test func aCopyIsAPrivateDatabaseOfTheWholeHistory() async throws {
        let (store, folder) = try await filled()
        defer { Scratch.remove(folder) }
        let path = Scratch.path(folder) + "/copy.sqlite"
        try await store.exportCopy(to: URL(filePath: path))
        #expect(Scratch.mode(path) == 0o600)
        let copy = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READONLY)
        #expect(try Scratch.count(copy, "SELECT COUNT(*) FROM items") == 2)
        #expect(try Scratch.count(copy, "SELECT COUNT(*) FROM devices_view") == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Scratch.path(folder)) == ["copy.sqlite"])
    }

    /// An existing file, empty or not, is refused and left exactly as it was: same bytes, same inode, same mode. Never unlinked,
    /// truncated or written into (so a file another program filled meanwhile, or a descriptor it holds, can't be reached).
    @Test func aCopyNeverTouchesAnExistingFile() async throws {
        let (store, folder) = try await filled()
        defer { Scratch.remove(folder) }
        for (name, contents, mode) in [("taken.sqlite", Data("precious".utf8), mode_t(0o600)), ("empty.sqlite", Data(), mode_t(0o644))] {
            let path = Scratch.path(folder) + "/" + name
            FileManager.default.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: Int(mode)])
            var before = stat()
            stat(path, &before)
            await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: path)) }
            do { try await store.exportCopy(to: URL(filePath: path)) } catch { #expect(error.message.contains("A copy never replaces a file; choose a new name."), "\(error.message)") }
            var after = stat()
            stat(path, &after)
            #expect(try Data(contentsOf: URL(filePath: path)) == contents)
            #expect(before.st_ino == after.st_ino && before.st_mode == after.st_mode && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, "\(name) untouched")
        }
    }

    /// A link as the destination, or a folder on its way, receives nothing; so a link can't send the copy somewhere else.
    @Test func aCopyNeverFollowsALink() async throws {
        let (store, folder) = try await filled()
        defer { Scratch.remove(folder) }
        let target = Scratch.path(folder) + "/target.sqlite"
        let link = Scratch.path(folder) + "/link.sqlite"
        symlink(target, link)
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: link)) }
        #expect(!Scratch.exists(target), "nothing was made behind the link")
        let existing = Scratch.path(folder) + "/existing.sqlite"
        FileManager.default.createFile(atPath: existing, contents: nil)
        let second = Scratch.path(folder) + "/second.sqlite"
        symlink(existing, second)
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: second)) }
        #expect((try? Data(contentsOf: URL(filePath: existing)))?.isEmpty == true, "an empty file behind a link stays empty")
        let inner = Scratch.path(folder) + "/inner"
        mkdir(inner, 0o700)
        let folderLink = Scratch.path(folder) + "/folder-link"
        symlink(inner, folderLink)
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: folderLink + "/copy.sqlite")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: inner).isEmpty)
    }

    /// An empty file with a second name is refused (a write would show through the other name).
    @Test func aCopyIsRefusedOnAHardLinkedFile() async throws {
        let (store, folder) = try await filled()
        defer { Scratch.remove(folder) }
        let one = Scratch.path(folder) + "/one.sqlite", two = Scratch.path(folder) + "/two.sqlite"
        FileManager.default.createFile(atPath: one, contents: nil)
        link(one, two)
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: one)) }
        #expect(try Data(contentsOf: URL(filePath: two)).isEmpty)
    }

    @Test func aRelativeOrDottedPathIsRefused() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        await #expect(throws: Failure.self) { try await store.exportCopy(to: try #require(URL(string: "relative.sqlite"))) }
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: "/tmp/../tmp/x.sqlite")) }
    }

    /// With an org list, only those orgs' snapshots, items and findings are in the copy, free pages included (the working copy is
    /// `VACUUM`ed after the delete): another org's canaries are in no byte of it. No working file is left in the store's folder.
    @Test func aCopyForSomeOrgsHoldsNoOtherOrgsBytes() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let storeFolder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(storeFolder), appVersion: "1")
        let (a, b) = (Scratch.apple("a", clientID: "CLIENT-A"), Scratch.apple("b", clientID: "CLIENT-B"))
        try await store.record(org: a, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("CANARYAAAA")]])
        for day in 0..<20 {
            try await store.record(org: b, takenAt: Scratch.noon.addingTimeInterval(Double(day)), resources: ["devices": (0..<30).map { Scratch.device("CANARYBBBB\(day)-\($0)") }])
        }
        try await store.seen(org: a, rule: "rulea", subjects: ["CANARYSUBJA"], at: Scratch.noon)
        try await store.seen(org: b, rule: "ruleb", subjects: ["CANARYSUBJB"], at: Scratch.noon)
        let copy = Scratch.path(root) + "/copy.sqlite"
        try await store.exportCopy(to: URL(filePath: copy), orgs: ["a"])
        let bytes = try Data(contentsOf: URL(filePath: copy))
        #expect(bytes.range(of: Data("CANARYAAAA".utf8)) != nil && bytes.range(of: Data("CANARYSUBJA".utf8)) != nil)
        for canary in ["CANARYBBBB", "CANARYSUBJB", "CLIENT-B", "ruleb"] { #expect(bytes.range(of: Data(canary.utf8)) == nil, "\(canary)") }
        let database = try SQLiteDatabase(path: copy, flags: SQLITE_OPEN_READONLY)
        #expect(try Scratch.count(database, "SELECT COUNT(*) FROM snapshots") == 1 && Scratch.count(database, "SELECT COUNT(*) FROM items") == 1)
        #expect(try Scratch.count(database, "SELECT COUNT(*) FROM attention") == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: Scratch.path(storeFolder)) == ["history.sqlite"], "the working copy is gone")
        #expect(Scratch.mode(copy) == 0o600)
        // No list: everything, as before.
        let all = Scratch.path(root) + "/all.sqlite"
        try await store.exportCopy(to: URL(filePath: all))
        #expect(try Scratch.count(try SQLiteDatabase(path: all, flags: SQLITE_OPEN_READONLY), "SELECT COUNT(*) FROM snapshots") == 21)
    }

    /// The post-copy check is a check: a destination whose mode was widened after the bytes were written (by another process)
    /// is refused, and a file this call made is removed, not left readable. The hook is where the disk changes under the call.
    @Test func aDestinationWidenedAfterTheCopyIsRefusedAndRemoved() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let widen = Shared("")
        let store = try SnapshotStore(storage: .memory, appVersion: "1", hook: { step throws(Failure) in
            if case .copied(let path) = step { chmod(path, 0o644); widen.set(path) }
        })
        try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: ["devices": [Scratch.device("S1")]])
        let made = Scratch.path(folder) + "/made.sqlite"
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: made)) }
        do { try await store.exportCopy(to: URL(filePath: made)) } catch { #expect(error.message.contains("isn't the private file")) }
        #expect(widen.value.hasSuffix("/made.sqlite") && !Scratch.exists(made), "a file this call made is removed")
    }

    /// The post-copy check looks at the inode: a different regular file renamed onto the path while the copy was written (private,
    /// one name, not empty: everything else about it passes) is refused, and is left alone, since it isn't ours to remove.
    @Test func aFileSwappedOntoTheDestinationIsRefusedAndLeftAlone() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let other = Scratch.path(folder) + "/other"
        let store = try SnapshotStore(storage: .memory, appVersion: "1", hook: { step throws(Failure) in
            if case .copied(let path) = step {
                // Our file keeps one name (a hard link elsewhere), so nlink, mode and size of it still pass: only its inode tells.
                link(path, path + ".kept")
                try? Data("someone else's".utf8).write(to: URL(filePath: other))
                chmod(other, 0o600)
                rename(other, path)
            }
        })
        try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: ["devices": [Scratch.device("S1")]])
        let made = Scratch.path(folder) + "/made.sqlite"
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: made)) }
        #expect(try Data(contentsOf: URL(filePath: made)) == Data("someone else's".utf8), "the swapped-in file is untouched")
    }

    /// An ACL (a folder's inheritable `everyone allow read`, which makes a `0600` file readable by others) is stripped from the new
    /// file at once, and one added after the bytes are written is refused with the file removed.
    @Test func aCopyHasNoACL() async throws {
        let (store, folder) = try await filled()
        defer { Scratch.remove(folder) }
        func chmodACL(_ path: String, _ acl: String) throws {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/chmod")
            process.arguments = ["+a", acl, path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "chmod +a works here")
        }
        func listing(_ path: String) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(filePath: "/bin/ls")
            process.arguments = ["-led", path]
            process.standardOutput = pipe
            try process.run()
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: out, as: UTF8.self)
        }
        let inheriting = Scratch.path(folder) + "/inheriting"
        mkdir(inheriting, 0o700)
        try chmodACL(inheriting, "everyone allow read,file_inherit")
        let copy = inheriting + "/copy.sqlite"
        try await store.exportCopy(to: URL(filePath: copy))
        let shown = try listing(copy)
        #expect(!shown.contains("everyone"), "the inherited ACL was stripped: \(shown)")
        #expect(Scratch.mode(copy) == 0o600)
        // One added after the copy was written.
        let added = Scratch.path(folder) + "/added"
        let hooked = try SnapshotStore(storage: .memory, appVersion: "1", hook: { step throws(Failure) in
            if case .copied(let path) = step {
                let process = Process()
                process.executableURL = URL(filePath: "/bin/chmod")
                process.arguments = ["+a", "everyone allow read", path]
                try? process.run()
                process.waitUntilExit()
            }
        })
        try await hooked.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: [:])
        await #expect(throws: Failure.self) { try await hooked.exportCopy(to: URL(filePath: added)) }
        #expect(!Scratch.exists(added), "a file that gained an ACL is removed")
    }

    /// A working copy a crash left in the store's folder is removed at the start of an export; only that pattern, only there.
    @Test func aCrashsWorkingCopyIsRemovedAtTheNextExport() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let storeFolder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(storeFolder), appVersion: "1")
        let home = Scratch.path(storeFolder)
        let mine = home + "/export-0A1B2C3D-0000-4000-8000-0123456789AB.tmp", journal = mine + "-journal"
        let notMine = ["/export-notes.tmp", "/export-0A1B2C3D-0000-4000-8000-0123456789AB.txt", "/other.tmp"].map { home + $0 }
        for path in [mine, journal] + notMine { try Data("x".utf8).write(to: URL(filePath: path)) }
        let target = Scratch.path(root) + "/copy.sqlite"
        try await store.exportCopy(to: URL(filePath: target))
        #expect(!Scratch.exists(mine) && !Scratch.exists(journal), "the leftovers are gone")
        for path in notMine { #expect(Scratch.exists(path), "\(path) isn't an export's working file") }
    }

    /// The copy's AUTOINCREMENT counter doesn't say how many snapshots the other orgs had. (The remaining ids keep their numbers,
    /// so gaps show: a known limit, in history.md.)
    @Test func aCopyForSomeOrgsDoesNotCarryTheOthersSnapshotCount() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let (a, b) = (Scratch.apple("a"), Scratch.apple("b"))
        for _ in 0..<5 { try await store.record(org: b, takenAt: Scratch.noon, resources: [:]) }
        let kept = try await store.record(org: a, takenAt: Scratch.noon, resources: [:])
        for _ in 0..<5 { try await store.record(org: b, takenAt: Scratch.noon, resources: [:]) }
        let copy = Scratch.path(root) + "/copy.sqlite"
        try await store.exportCopy(to: URL(filePath: copy), orgs: ["a"])
        let database = try SQLiteDatabase(path: copy, flags: SQLITE_OPEN_READONLY)
        #expect(try Scratch.count(database, "SELECT seq FROM sqlite_sequence WHERE name = 'snapshots'") == kept)
    }

    /// A refused file's descriptor is closed once, by the actor's `deinit` alone (it was closed by the init's `defer` as well: the
    /// second close could hit a descriptor some other code had just been given). Counted by the file's inode.
    @Test func aRefusedFilesDescriptorIsClosedOnce() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = Scratch.path(folder) + "/other.sqlite"
        let database = try SQLiteDatabase(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        try database.execute("CREATE TABLE notes (a TEXT)")
        var info = stat()
        stat(path, &info)
        let inode = UInt64(info.st_ino)
        let bystander = open(path, O_RDONLY)
        defer { close(bystander) }
        let before = AbapitHistory.closed.withLock { $0.filter { $0 == inode }.count }
        #expect(throws: AbapitHistory.Failure.self) { try AbapitHistory(file: URL(filePath: path)) }
        // `deinit` of the failed actor has run by now.
        let closes = AbapitHistory.closed.withLock { $0.filter { $0 == inode }.count } - before
        #expect(closes == 1, "closed \(closes) times")
        #expect(fcntl(bystander, F_GETFD) != -1, "another descriptor of the same file is still open")
    }

    /// A newer file the store only reads can be copied too: the copy changes nothing in it.
    @Test func aNewerFileCanBeCopied() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        _ = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let file = Scratch.path(folder) + "/history.sqlite"
        try Scratch.open(file).execute("PRAGMA user_version = 9")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readOnly(version: 9))
        let copy = Scratch.path(folder) + "/copy.sqlite"
        try await store.exportCopy(to: URL(filePath: copy))
        #expect(Scratch.mode(copy) == 0o600)
    }
}
