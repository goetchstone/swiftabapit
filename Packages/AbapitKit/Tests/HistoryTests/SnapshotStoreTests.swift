import Foundation
import JSONAPI
import Orgs
import SQLite3
import Testing
@testable import History

/// The snapshot store (plan L7, §3.7, Phase 3): what it records and reads back, one org at a time; whole records or
/// none; pruning by id with the items going too; and a file that is the owner's alone and never reached through a link.
@Suite("Snapshot store")
struct SnapshotStoreTests {
    typealias Failure = SnapshotStore.Failure

    static let injected = Failure.database(code: SQLITE_IOERR, message: "injected")

    // MARK: recording and reading

    @Test func aSnapshotReadsBackAsItWasRecorded() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1.0 (7)")
        let org = Scratch.apple("acme")
        let service = Resource(type: "mdmServers", id: "SVC-0001", attributes: ["serverName": .string("Main"), "deviceCount": .number("2")])
        // Fractions of a second are dropped, as abapit's strftime drops them.
        let id = try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(0.9), resources: [
            "devices": [Scratch.device("SERIAL0002", model: "B"), Scratch.device("SERIAL0001", model: "A")],
            "mdm_servers": [service],
        ], errors: ["applecare": "HTTP 429"], notes: ["devices": "showing 2 of at least 3: cut at the page cap"])

        let snapshot = try await store.load(id, org: org)
        #expect(snapshot.summary == SnapshotStore.Summary(
            id: id, takenAt: "2026-11-18T11:06:40Z", orgID: "acme", orgName: "Example acme", orgScope: "business",
            clientID: "BUSINESSAPI.00000000-0000-0000-0000-000000000000", writtenBy: "swiftabapit 1.0 (7)",
            errors: ["applecare": "HTTP 429"], notes: ["devices": "showing 2 of at least 3: cut at the page cap"], deviceCount: 2))
        #expect(snapshot.summary.date == Scratch.noon)
        // Each resource's items by id, typed by the resource's name (abapit's `snapshot_resource`), attributes kept.
        #expect(snapshot.resources.keys.sorted() == ["devices", "mdm_servers"])
        #expect(snapshot.resources["devices"]?.map(\.id) == ["SERIAL0001", "SERIAL0002"])
        #expect(snapshot.resources["devices"]?.first == Resource(type: "devices", id: "SERIAL0001", attributes: Scratch.device("SERIAL0001", model: "A").attributes))
        #expect(snapshot.resources["mdm_servers"] == [Resource(type: "mdm_servers", id: "SVC-0001", attributes: service.attributes)])
        // Loaded in abapit's stored order: keys sorted.
        #expect(snapshot.resources["devices"]?.first?.attributes.keys == ["addedToOrgDateTime", "deviceModel", "productFamily", "serialNumber", "status"])
        #expect(try await store.snapshots(org: org) == [snapshot.summary])
    }

    @Test func aMosyleOrgIsRecordedByItsProviderWithNoClientID() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = OrgProfile(id: "mdm", name: "Example MDM", provider: .mosyle)
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        let summary = try await store.load(id, org: org).summary
        #expect(summary.orgScope == "mosyle")
        #expect(summary.clientID == "")
    }

    /// abapit's `INSERT OR REPLACE`: two items of one resource with one id keep the last.
    @Test func theLastOfTwoItemsWithOneIDIsKept() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: [
            "devices": [Scratch.device("SERIAL0001", model: "first"), Scratch.device("SERIAL0002"), Scratch.device("SERIAL0001", model: "last")],
        ])
        let devices = try #require(try await store.load(id, org: org).resources["devices"])
        #expect(devices.map(\.id) == ["SERIAL0001", "SERIAL0002"])
        #expect(devices.first?.attributes["deviceModel"] == .string("last"))
        #expect(try await store.snapshots(org: org).first?.deviceCount == 2)
    }

    /// abapit's `latest_resource`: the newest snapshot that holds the resource, its items by id.
    @Test func theLatestCopyOfAResourceSkipsSnapshotsWithoutIt() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let coverage = [Resource(type: "appleCareCoverage", id: "C2", attributes: ["serialNumber": .string("SERIAL0001")]),
                        Resource(type: "appleCareCoverage", id: "C1", attributes: ["serialNumber": .string("SERIAL0001")])]
        let first = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")], "applecare": coverage])
        let second = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")], "applecare": []],
                                            errors: ["applecare": "HTTP 500"])
        let applecare = try #require(try await store.latest("applecare", org: org))
        #expect(applecare.summary.id == first)
        #expect(applecare.items.map(\.id) == ["C1", "C2"])
        #expect(applecare.items.allSatisfy { $0.type == "applecare" })
        #expect(try await store.latest("devices", org: org)?.summary.id == second)
        #expect(try await store.latest("people", org: org) == nil)
    }

    @Test func theListIsNewestFirstAndBounded() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        var ids: [Int64] = []
        for _ in 0..<3 { ids.append(try await store.record(org: org, takenAt: Scratch.noon, resources: [:])) }
        #expect(try await store.snapshots(org: org).map(\.id) == ids.reversed())
        #expect(try await store.snapshots(org: org, limit: 2).map(\.id) == [ids[2], ids[1]])
        #expect(try await store.snapshots(org: org, limit: 0).isEmpty)
    }

    // MARK: one org at a time

    @Test func eachOrgSeesOnlyItsOwnSnapshots() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        // The same client ID on both: the org's id, never the client ID, keeps them apart.
        let (a, b) = (Scratch.apple("a"), Scratch.apple("b"))
        let a1 = try await store.record(org: a, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL000A")]])
        let b1 = try await store.record(org: b, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL000B")]])
        let a2 = try await store.record(org: a, takenAt: Scratch.noon, resources: [:])

        #expect(try await store.snapshots(org: a).map(\.id) == [a2, a1])
        #expect(try await store.snapshots(org: b).map(\.id) == [b1])
        #expect(try await store.snapshots(org: Scratch.apple("c")).isEmpty)
        // Another org's snapshot is one that isn't there.
        await #expect(throws: Failure.noSnapshot(b1)) { try await store.load(b1, org: a) }
        await #expect(throws: Failure.noSnapshot(a1)) { try await store.load(a1, org: b) }
        #expect(try await store.load(b1, org: b).resources["devices"]?.map(\.id) == ["SERIAL000B"])
        #expect(try await store.latest("devices", org: a)?.items.map(\.id) == ["SERIAL000A"])
        #expect(try await store.latest("devices", org: Scratch.apple("c")) == nil)

        // Pruning or clearing one org leaves the other's.
        #expect(try await store.prune(org: a, keep: 0) == 2)
        #expect(try await store.snapshots(org: b).map(\.id) == [b1])
        #expect(try await store.removeAll(org: b) == 1)
        #expect(try await store.snapshots(org: b).isEmpty)
    }

    @Test func anOrgWithoutAnIDIsRefused() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let nobody = OrgProfile(raw: ["name": .string("No id"), "provider": .string("apple")])
        await #expect(throws: Failure.noOrg) { try await store.record(org: nobody, takenAt: Scratch.noon, resources: [:]) }
        await #expect(throws: Failure.noOrg) { try await store.snapshots(org: nobody) }
        await #expect(throws: Failure.noOrg) { try await store.load(1, org: nobody) }
        await #expect(throws: Failure.noOrg) { try await store.latest("devices", org: nobody) }
        await #expect(throws: Failure.noOrg) { try await store.prune(org: nobody, keep: 1) }
        await #expect(throws: Failure.noOrg) { try await store.removeAll(org: nobody) }
    }

    // MARK: pruning

    /// Newest by id, the order they were recorded: an import records old snapshots after new ones, so `taken_at` would
    /// keep the wrong ones. Their items go with them (foreign keys on).
    @Test func pruneKeepsTheNewestByIDAndTheirItemsGoToo() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let store = try SnapshotStore(storage: .folder(root.appending(path: "store")), appVersion: "1")
        let org = Scratch.apple("acme")
        var ids: [Int64] = []
        for day in 0..<4 {
            // Each recorded a day earlier than the one before.
            ids.append(try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(Double(-day) * 86_400),
                                              resources: ["devices": [Scratch.device("SERIAL000\(day)"), Scratch.device("SERIAL100\(day)")]]))
        }
        #expect(try await store.prune(org: org, keep: -1) == 0)
        #expect(try await store.snapshots(org: org).count == 4)
        #expect(try await store.prune(org: org, keep: 2) == 2)
        #expect(try await store.snapshots(org: org).map(\.id) == [ids[3], ids[2]])
        #expect(try await store.prune(org: org, keep: 2) == 0)

        let file = try Scratch.open(Scratch.path(root.appending(path: "store/history.sqlite")))
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM items") == 4)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM items WHERE snapshot_id NOT IN (SELECT id FROM snapshots)") == 0)
    }

    @Test func removingAnOrgsHistoryTakesEveryItem() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let store = try SnapshotStore(storage: .folder(root.appending(path: "store")), appVersion: "1")
        let (a, b) = (Scratch.apple("a"), Scratch.apple("b"))
        for _ in 0..<2 { try await store.record(org: a, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL000A")]]) }
        try await store.record(org: b, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL000B")]])
        #expect(try await store.removeAll(org: a) == 2)
        #expect(try await store.removeAll(org: a) == 0)
        let file = try Scratch.open(Scratch.path(root.appending(path: "store/history.sqlite")))
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM snapshots") == 1)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM items") == 1)
    }

    // MARK: whole or not at all

    /// A failure part way through (a disk error, here injected after two items) leaves no snapshot row and no item, and
    /// the store goes on working.
    @Test func aFaultPartWayThroughARecordLeavesNoRow() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let armed = Shared(true)
        let store = try SnapshotStore(storage: .folder(root.appending(path: "store")), appVersion: "1") { step throws(Failure) in
            if step == .recording(items: 2), armed.value {
                armed.set(false)
                throw Self.injected
            }
        }
        let org = Scratch.apple("acme")
        let devices = (1...3).map { Scratch.device("SERIAL000\($0)") }
        await #expect(throws: Self.injected) { try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": devices]) }
        #expect(try await store.snapshots(org: org).isEmpty)
        let file = try Scratch.open(Scratch.path(root.appending(path: "store/history.sqlite")))
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM snapshots") == 0)
        #expect(try Scratch.count(file, "SELECT COUNT(*) FROM items") == 0)

        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": devices])
        #expect(try await store.load(id, org: org).resources["devices"]?.count == 3)
    }

    // MARK: the file is the owner's alone

    /// The folder `0700`, the database `0600`, and the journal SQLite writes beside it during a record `0600` too.
    @Test func theFolderTheFileAndTheJournalAreTheOwnersAlone() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "a/store")
        let file = Scratch.path(folder.appending(path: "history.sqlite"))
        let journal = Shared<mode_t?>(nil)
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(Failure) in
            if step == .recording(items: 1) { journal.set(Scratch.mode(file + "-journal")) }
        }
        #expect(Scratch.mode(Scratch.path(root.appending(path: "a"))) == 0o700)
        #expect(Scratch.mode(Scratch.path(folder)) == 0o700)
        #expect(Scratch.mode(file) == 0o600)
        try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        #expect(journal.value == 0o600)
        #expect(!Scratch.exists(file + "-journal"))
        #expect(!Scratch.exists(file + "-wal"))
        #expect(Scratch.mode(file) == 0o600)
    }

    /// A crash the moment the file exists leaves it `0600`: it is made with its mode, not made and then narrowed.
    @Test func aCrashRightAfterTheFileIsMadeLeavesItTheOwnersAlone() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let file = Scratch.path(folder.appending(path: "history.sqlite"))
        #expect(throws: Self.injected) {
            _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(Failure) in
                if step == .created(path: file) { throw Self.injected }
            }
        }
        #expect(Scratch.mode(file) == 0o600)
    }

    @Test func aWiderFolderAndFileAreNarrowed() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let file = Scratch.path(folder.appending(path: "history.sqlite"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        #expect(FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o644]))
        let made = Shared(false)
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(Failure) in
            if case .created = step { made.set(true) }
        }
        #expect(Scratch.mode(Scratch.path(folder)) == 0o700)
        #expect(Scratch.mode(file) == 0o600)
        #expect(!made.value, "an existing file isn't made again")
        // An empty file is a new database.
        try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: [:])
        #expect(try await store.snapshots(org: Scratch.apple("acme")).count == 1)
    }

    // MARK: never through a link

    @Test func aLinkedFolderIsRefused() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let real = root.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = Scratch.path(root.appending(path: "store"))
        #expect(symlink(Scratch.path(real), link) == 0)
        #expect(throws: Failure.link(path: link)) { _ = try SnapshotStore(storage: .folder(URL(filePath: link)), appVersion: "1") }
        #expect(!Scratch.exists(Scratch.path(real.appending(path: "history.sqlite"))))
    }

    /// A link above the store's folder too: nothing is made through it.
    @Test func aLinkAboveTheFolderIsRefused() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let real = root.appending(path: "real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = Scratch.path(root.appending(path: "up"))
        #expect(symlink(Scratch.path(real), link) == 0)
        #expect(throws: Failure.link(path: link)) {
            _ = try SnapshotStore(storage: .folder(URL(filePath: link).appending(path: "store")), appVersion: "1")
        }
        #expect(!Scratch.exists(Scratch.path(real.appending(path: "store"))))
    }

    @Test func aLinkedFileIsRefused() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = Scratch.path(folder.appending(path: "history.sqlite"))
        let target = Scratch.path(root.appending(path: "elsewhere.sqlite"))
        #expect(FileManager.default.createFile(atPath: target, contents: nil))
        #expect(symlink(target, file) == 0)
        #expect(throws: Failure.link(path: file)) { _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") }
        #expect(try FileManager.default.attributesOfItem(atPath: target)[.size] as? Int == 0)
        // A link to nothing too: nothing is made where it points.
        #expect(unlink(file) == 0)
        let nowhere = Scratch.path(root.appending(path: "nowhere.sqlite"))
        #expect(symlink(nowhere, file) == 0)
        #expect(throws: Failure.link(path: file)) { _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") }
        #expect(!Scratch.exists(nowhere))
    }

    /// A link put in place of the folder after the store checked it is refused by SQLite itself (`SQLITE_OPEN_NOFOLLOW`).
    @Test func aLinkSwappedInAfterTheChecksIsRefused() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = Scratch.path(root.appending(path: "store"))
        let moved = Scratch.path(root.appending(path: "moved"))
        let file = folder + "/history.sqlite"
        #expect(throws: Failure.link(path: file)) {
            _ = try SnapshotStore(storage: .folder(URL(filePath: folder)), appVersion: "1") { step throws(Failure) in
                guard step == .opening(path: file) else { return }
                guard rename(folder, moved) == 0, symlink(moved, folder) == 0 else { throw .unopenable(path: folder, errno: errno) }
            }
        }
    }

    /// A link where the journal goes is never written through: the record fails and the link's target isn't made.
    @Test func aLinkedJournalIsNeverWrittenThrough() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let journal = Scratch.path(folder.appending(path: "history.sqlite-journal"))
        let target = Scratch.path(root.appending(path: "journal-target"))
        #expect(symlink(target, journal) == 0)
        await #expect(throws: Failure.self) { try await store.record(org: Scratch.apple("acme"), takenAt: Scratch.noon, resources: [:]) }
        #expect(!Scratch.exists(target))
    }

    /// A path with `.` or `..`, a file where a folder goes, and a folder where the database goes: each refused, nothing made.
    @Test func whatIsntTheStoresFolderOrFileIsRefused() throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let dotted = Scratch.path(root) + "store/../elsewhere"
        #expect(throws: Failure.notAFolder(path: dotted)) { _ = try SnapshotStore(storage: .folder(URL(filePath: dotted)), appVersion: "1") }
        #expect(!Scratch.exists(Scratch.path(root.appending(path: "store"))))

        let plain = Scratch.path(root.appending(path: "plain"))
        #expect(FileManager.default.createFile(atPath: plain, contents: nil))
        #expect(throws: Failure.notAFolder(path: plain)) {
            _ = try SnapshotStore(storage: .folder(URL(filePath: plain).appending(path: "store")), appVersion: "1")
        }

        let folder = root.appending(path: "store")
        let file = Scratch.path(folder.appending(path: "history.sqlite"))
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: true)
        #expect(throws: Failure.notAFile(path: file)) { _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") }
    }

    // MARK: a newer file

    @Test func aFileFromANewerVersionOpensReadOnlyAndSaysSo() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let org = Scratch.apple("acme")
        let id = try await SnapshotStore(storage: .folder(folder), appVersion: "1")
            .record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        let file = Scratch.path(folder.appending(path: "history.sqlite"))
        try Scratch.open(file).execute("PRAGMA user_version = 2")

        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readOnly(version: 2))
        #expect(Failure.readOnly(version: 2).message.contains("newer"))
        await #expect(throws: Failure.readOnly(version: 2)) { try await store.record(org: org, takenAt: Scratch.noon, resources: [:]) }
        await #expect(throws: Failure.readOnly(version: 2)) { try await store.prune(org: org, keep: 0) }
        await #expect(throws: Failure.readOnly(version: 2)) { try await store.removeAll(org: org) }
        // Still read.
        #expect(try await store.snapshots(org: org).map(\.id) == [id])
        #expect(try await store.load(id, org: org).resources["devices"]?.count == 1)
        let check = try Scratch.open(file)
        #expect(try check.userVersion() == 2)
        #expect(try Scratch.count(check, "SELECT COUNT(*) FROM snapshots") == 1)
    }

    // MARK: rows changed outside the app

    @Test func aRowChangedOutsideTheAppSaysSo() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let org = Scratch.apple("acme")
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        try file.execute("UPDATE items SET attributes = 'not json'")
        await #expect(throws: Failure.corrupt("the attributes of devices SERIAL0001")) { try await store.load(id, org: org) }
        await #expect(throws: Failure.corrupt("the attributes of devices SERIAL0001")) { try await store.latest("devices", org: org) }
        try file.execute("UPDATE snapshots SET errors = '[1]'")
        await #expect(throws: Failure.corrupt("a snapshot's errors")) { try await store.snapshots(org: org) }
        try file.execute("UPDATE snapshots SET errors = '{\"devices\": 1}', notes = 'x'")
        await #expect(throws: Failure.corrupt("a snapshot's notes")) { try await store.snapshots(org: org) }
        // A value abapit didn't write as a string shows as its JSON.
        try file.execute("UPDATE snapshots SET notes = '{}'")
        #expect(try await store.snapshots(org: org).first?.errors == ["devices": "1"])
    }
}
