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

    /// A journal abapit left behind (a crash) is not rolled back, which would write: `immutable` ignores it, and it is still
    /// there, byte for byte, afterwards.
    @Test func aHotJournalIsIgnoredNotReplayed() async throws {
        let folder = try Scratch.folder()
        defer { Scratch.remove(folder) }
        let path = try Self.makeFile(in: folder, snapshots: Self.rows.snapshots, items: Self.rows.items)
        let journal = path + "-journal"
        try Data(repeating: 0xA5, count: 2048).write(to: URL(filePath: journal))
        let before = try Footprint(path), journalBefore = try Data(contentsOf: URL(filePath: journal))
        let source = try AbapitHistory(file: URL(filePath: path))
        #expect(try await source.headers().count == 2)
        #expect(try Footprint(path) == before)
        #expect(try Data(contentsOf: URL(filePath: journal)) == journalBefore)
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

    /// An existing file with anything in it is never replaced; an existing empty file is replaced by the copy, which is `0600` whatever the empty one was.
    @Test func aCopyNeverReplacesAFileButUsesAnEmptyOne() async throws {
        let (store, folder) = try await filled()
        defer { Scratch.remove(folder) }
        let taken = Scratch.path(folder) + "/taken.sqlite"
        try Data("precious".utf8).write(to: URL(filePath: taken))
        await #expect(throws: Failure.self) { try await store.exportCopy(to: URL(filePath: taken)) }
        do { try await store.exportCopy(to: URL(filePath: taken)) } catch { #expect(error.message.contains("already exists")) }
        #expect(try Data(contentsOf: URL(filePath: taken)) == Data("precious".utf8))
        let empty = Scratch.path(folder) + "/empty.sqlite"
        FileManager.default.createFile(atPath: empty, contents: nil, attributes: [.posixPermissions: 0o644])
        try await store.exportCopy(to: URL(filePath: empty))
        #expect(Scratch.mode(empty) == 0o600)
        #expect(try Scratch.count(try SQLiteDatabase(path: empty, flags: SQLITE_OPEN_READONLY), "SELECT COUNT(*) FROM items") == 2)
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
