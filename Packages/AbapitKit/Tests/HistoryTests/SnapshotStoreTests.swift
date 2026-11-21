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
            errors: ["applecare": "HTTP 429"], notes: ["devices": "showing 2 of at least 3: cut at the page cap"],
            counts: ["devices": 2, "mdm_servers": 1], deviceCount: 2))
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
        #expect(try await store.snapshots(org: org).first?.counts == ["devices": 2])
    }

    /// What the newest attempt found is the answer, even none: recorded `[X]` at T1 and `[]` at T2, the latest is "none at
    /// T2" (abapit's `latest_resource` showed T1's as current). A snapshot that didn't try is passed over.
    @Test func theLatestIsWhatTheNewestAttemptFoundEvenNone() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let coverage = [Resource(type: "appleCareCoverage", id: "C2", attributes: ["serialNumber": .string("SERIAL0001")]),
                        Resource(type: "appleCareCoverage", id: "C1", attributes: ["serialNumber": .string("SERIAL0001")])]
        #expect(try await store.latest("applecare", org: org) == nil)
        let t1 = try await store.record(org: org, takenAt: Scratch.noon, resources: ["applecare": coverage])
        let first = try #require(try await store.latest("applecare", org: org))
        let summary1 = try await store.load(t1, org: org).summary
        #expect(first == .read(SnapshotStore.Copy(summary: summary1, items: [
            Resource(type: "applecare", id: "C1", attributes: coverage[1].attributes),
            Resource(type: "applecare", id: "C2", attributes: coverage[0].attributes),
        ])))

        let t2 = try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(60), resources: ["applecare": []])
        // T3 didn't try: passed over.
        try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(120), resources: ["devices": [Scratch.device("SERIAL0001")]])
        let summary2 = try await store.load(t2, org: org).summary
        #expect(summary2.counts == ["applecare": 0])
        #expect(try await store.latest("applecare", org: org) == .read(SnapshotStore.Copy(summary: summary2, items: [])))
        #expect(try await store.latest("people", org: org) == nil)
    }

    /// The newest attempt failed: the latest says so, when, and why, and shows the last good copy, with its own age
    /// (invariant 8). Recorded `[X]` at T1, an error at T2: "failed at T2; showing T1".
    @Test func aFailedAttemptSaysSoAndShowsTheNewestCopy() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let t1 = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        let t2 = try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(60), resources: [:], errors: ["devices": "HTTP 500"])
        let (summary1, summary2) = (try await store.load(t1, org: org).summary, try await store.load(t2, org: org).summary)
        #expect(summary2.counts.isEmpty)
        let copy = SnapshotStore.Copy(summary: summary1, items: [Resource(type: "devices", id: "SERIAL0001", attributes: Scratch.device("SERIAL0001").attributes)])
        #expect(try await store.latest("devices", org: org) == .failed(summary2, error: "HTTP 500", newest: copy))

        // Failed with nothing before it: no copy to show.
        let other = Scratch.apple("other")
        let only = try await store.record(org: other, takenAt: Scratch.noon, resources: [:], errors: ["devices": "HTTP 403"])
        #expect(try await store.latest("devices", org: other) == .failed(try await store.load(only, org: other).summary, error: "HTTP 403", newest: nil))
    }

    /// The last good copy is the newest read without an error, even an empty one (plan §2.3 defect 13): T1 read a device,
    /// T2 read none, T3 failed, so the latest shows T2's none, never T1's device, which T2 proved gone.
    @Test func theLastGoodCopyIsTheNewestReadWithoutAnErrorEvenEmpty() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        let t2 = try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(60), resources: ["devices": []])
        let t3 = try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(120), resources: [:], errors: ["devices": "HTTP 500"])
        let (summary2, summary3) = (try await store.load(t2, org: org).summary, try await store.load(t3, org: org).summary)
        #expect(try await store.latest("devices", org: org) == .failed(summary3, error: "HTTP 500", newest: SnapshotStore.Copy(summary: summary2, items: [])))
    }

    /// A read that recorded part and then failed is never the last good copy: T1 read three devices, T2 recorded one and
    /// failed, so the latest says T2 failed and shows T1's three.
    @Test func aPartReadThatFailedIsNeverTheLastGoodCopy() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let org = Scratch.apple("acme")
        let devices = (1...3).map { Scratch.device("SERIAL000\($0)") }
        let t1 = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": devices])
        let t2 = try await store.record(org: org, takenAt: Scratch.noon.addingTimeInterval(60), resources: ["devices": [devices[0]]],
                                        errors: ["devices": "page 2: HTTP 500"])
        let (summary1, summary2) = (try await store.load(t1, org: org).summary, try await store.load(t2, org: org).summary)
        #expect(summary2.counts == ["devices": 1])
        let copy = SnapshotStore.Copy(summary: summary1, items: devices.map { Resource(type: "devices", id: $0.id, attributes: $0.attributes) })
        #expect(try await store.latest("devices", org: org) == .failed(summary2, error: "page 2: HTTP 500", newest: copy))
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
        guard case .read(let copy)? = try await store.latest("devices", org: a) else {
            Issue.record("a's latest devices weren't read")
            return
        }
        #expect(copy.summary.id == a1)
        #expect(copy.items.map(\.id) == ["SERIAL000A"])
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

    /// Newest by `taken_at` (then id), whatever order they were recorded in: an import records old snapshots after new ones, which
    /// the id would keep (changed 2026-11-21, the review of PR 36). Their items go with them (foreign keys on).
    @Test func pruneKeepsTheNewestByTimeAndTheirItemsGoToo() async throws {
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
        #expect(try await store.snapshots(org: org).map(\.id) == [ids[0], ids[1]], "the two newest by time, not the two recorded last")
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

    /// The newest N are the org's own newest: another org's newer snapshots don't count towards them.
    @Test func pruneCountsOnlyTheOrgsOwnSnapshots() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        let (a, b) = (Scratch.apple("a"), Scratch.apple("b"))
        let a1 = try await store.record(org: a, takenAt: Scratch.noon, resources: [:])
        let a2 = try await store.record(org: a, takenAt: Scratch.noon, resources: [:])
        let b1 = try await store.record(org: b, takenAt: Scratch.noon, resources: [:])
        let b2 = try await store.record(org: b, takenAt: Scratch.noon, resources: [:])
        #expect(try await store.prune(org: a, keep: 1) == 1)
        #expect(try await store.snapshots(org: a).map(\.id) == [a2])
        #expect(try await store.snapshots(org: b).map(\.id) == [b2, b1])
        #expect(a1 < a2)
    }

    /// Org ids are slugs of names and come round again: every id with history, so a new org is never given one and never
    /// inherits a removed org's snapshots.
    @Test func everyOrgIDWithHistoryIsListed() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        #expect(try await store.orgIDs().isEmpty)
        for id in ["b", "a", "c"] { try await store.record(org: Scratch.apple(id), takenAt: Scratch.noon, resources: [:]) }
        try await store.record(org: Scratch.apple("a"), takenAt: Scratch.noon, resources: [:])
        #expect(try await store.orgIDs() == ["a", "b", "c"])
        try await store.removeAll(org: Scratch.apple("c"))
        #expect(try await store.orgIDs() == ["a", "b"])
    }

    // MARK: what is kept

    /// Text is stored by its bytes: a NUL inside an id or a name comes back whole, not cut at it.
    @Test func aNULInsideAnIDOrANameRoundTrips() async throws {
        let store = try SnapshotStore(storage: .memory, appVersion: "1")
        var org = Scratch.apple("acme")
        org.name = "Example\u{0}Org"
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL\u{0}0001")]])
        let snapshot = try await store.load(id, org: org)
        #expect(Array(snapshot.summary.orgName.utf8) == Array("Example\u{0}Org".utf8))
        #expect(snapshot.resources["devices"]?.map { Array($0.id.utf8) } == [Array("SERIAL\u{0}0001".utf8)])
    }

    /// History never keeps a secret: an attribute whose name looks like a secret's, at any depth, is left out and the rest
    /// of the item kept (coordinating session's decision, 2026-11-20). The resource's note counts what was left out, never
    /// names it, and the canary reaches neither the file, the journal, the notes nor an error. A backstop: the collectors
    /// never hand one over.
    @Test func anAttributeNamedLikeASecretIsLeftOutAndCounted() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let canary = "canary-7f3a91c2"
        let journals = Shared<[Data]>([])
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(Failure) in
            guard case .recording = step else { return }
            if let bytes = try? Data(contentsOf: folder.appending(path: "history.sqlite-journal")) { journals.set(journals.value + [bytes]) }
        }
        let org = Scratch.apple("acme")
        let nested = Resource(type: "configurations", id: "CFG-0001", attributes: [
            "name": .string("Wi-Fi"),
            "payloads": .array([.object(["kind": .string("wifi"), "settings": .object([
                "ssid": .string("Example"), "Password": .string(canary), "Credentials": .object(["UserPassword": .string(canary)]),
            ])])]),
        ])
        let device = Resource(type: "orgDevices", id: "SERIAL0001", attributes: ["deviceModel": .string("MacBook Air"), "activation_bypass": .string(canary)])
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [device], "configurations": [nested]],
                                        notes: ["devices": "showing 1 of at least 2"])

        let snapshot = try await store.load(id, org: org)
        // The rest of each item is kept.
        #expect(snapshot.resources["configurations"]?.first?.attributes == [
            "name": .string("Wi-Fi"),
            "payloads": .array([.object(["kind": .string("wifi"), "settings": .object(["ssid": .string("Example")])])]),
        ])
        #expect(snapshot.resources["devices"]?.first?.attributes == ["deviceModel": .string("MacBook Air")])
        // Counted per resource, after any note the collector wrote; a member left out isn't looked into.
        #expect(snapshot.summary.notes == [
            "configurations": "2 attributes left out: their names look like a secret's",
            "devices": "showing 1 of at least 2; 1 attribute left out: its name looks like a secret's",
        ])
        #expect(snapshot.summary.counts == ["configurations": 1, "devices": 1])
        for note in snapshot.summary.notes.values { #expect(!note.contains("Password") && !note.contains("bypass") && !note.contains(canary)) }
        let file = try Data(contentsOf: folder.appending(path: "history.sqlite"))
        #expect(file.firstRange(of: Data(canary.utf8)) == nil, "the database holds the canary")
        #expect(!journals.value.isEmpty, "the journal was looked at mid-record")
        for journal in journals.value { #expect(journal.firstRange(of: Data(canary.utf8)) == nil, "the journal holds the canary") }
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
        // Read the moment the file exists, before anything the store does on the way out (a `defer` included) can run.
        let born = Shared<mode_t?>(nil)
        #expect(throws: Self.injected) {
            _ = try SnapshotStore(storage: .folder(folder), appVersion: "1") { step throws(Failure) in
                guard step == .created(path: file) else { return }
                born.set(Scratch.mode(file))
                throw Self.injected
            }
        }
        #expect(born.value == 0o600)
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

    /// A link put in place of a folder the walk has already opened, an ancestor or the store's own, leads nowhere: the next
    /// folder and the database are made from the descriptor the walk holds, so the link's target receives nothing (an
    /// attacker's folder, `evil/store`, made ready for it), and SQLite then refuses the path.
    @Test(arguments: ["a", "a/store"])
    func aLinkSwappedInDuringTheWalkReceivesNothing(swapped: String) throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let base = Scratch.path(root)
        try FileManager.default.createDirectory(atPath: base + "a", withIntermediateDirectories: false)
        try FileManager.default.createDirectory(atPath: base + "evil/store", withIntermediateDirectories: true)
        let target = base + (swapped == "a" ? "evil" : "evil/store")
        let file = base + "a/store/history.sqlite"
        #expect(throws: Failure.link(path: file)) {
            _ = try SnapshotStore(storage: .folder(URL(filePath: base + "a/store")), appVersion: "1") { step throws(Failure) in
                guard step == .walked(path: base + swapped) else { return }
                guard rename(base + swapped, base + "moved") == 0, symlink(target, base + swapped) == 0 else {
                    throw .unopenable(path: base + swapped, errno: errno)
                }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base + "evil/store").isEmpty)
        // What was made went where the walk was: the folder it held, now called `moved`.
        let made = base + (swapped == "a" ? "moved/store/history.sqlite" : "moved/history.sqlite")
        #expect(Scratch.mode(made) == 0o600)
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
        try Scratch.open(file).execute("PRAGMA user_version = 3")

        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        #expect(store.access == .readOnly(version: 3))
        #expect(Failure.readOnly(version: 3).message.contains("newer"))
        await #expect(throws: Failure.readOnly(version: 3)) { try await store.record(org: org, takenAt: Scratch.noon, resources: [:]) }
        await #expect(throws: Failure.readOnly(version: 3)) { try await store.prune(org: org, keep: 0) }
        await #expect(throws: Failure.readOnly(version: 3)) { try await store.removeAll(org: org) }
        // Still read.
        #expect(try await store.snapshots(org: org).map(\.id) == [id])
        #expect(try await store.load(id, org: org).resources["devices"]?.count == 1)
        let check = try Scratch.open(file)
        #expect(try check.userVersion() == 3)
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
        try file.execute("UPDATE snapshots SET counts = '{\"devices\": -1}'")
        await #expect(throws: Failure.corrupt("a snapshot's counts")) { try await store.snapshots(org: org) }
    }

    /// An escape of half a character (a lone surrogate) in a JSON column says which column, never reads as U+FFFD, which
    /// would change an id or merge two keys. A whole pair, as `StoredJSON` writes one, still reads.
    @Test func anEscapeOfHalfACharacterSaysWhichColumn() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let org = Scratch.apple("acme")
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [
            Resource(type: "orgDevices", id: "SERIAL0001", attributes: ["name": .string("\u{1F600}")]),
        ]])
        #expect(try await store.load(id, org: org).resources["devices"]?.first?.attributes["name"] == .string("\u{1F600}"))
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        let u = "\u{5C}u"  // a backslash and a u, so the escapes below are SQL text, not Swift's
        let half = Failure.corrupt("the column attributes holds an escape of half a character")
        try file.execute("UPDATE items SET attributes = '{\"name\": \"\(u)d800x\"}'")
        await #expect(throws: half) { try await store.load(id, org: org) }
        // Two keys that would both read as U+FFFD, and merge.
        try file.execute("UPDATE items SET attributes = '{\"\(u)dc00\": 1, \"\(u)dbff\": 2}'")
        await #expect(throws: half) { try await store.latest("devices", org: org) }
        try file.execute("UPDATE items SET attributes = '{}'")
        try file.execute("UPDATE snapshots SET errors = '{\"devices\": \"\(u)d800\"}'")
        await #expect(throws: Failure.corrupt("the column errors holds an escape of half a character")) { try await store.snapshots(org: org) }
        try file.execute("UPDATE snapshots SET errors = '{}', counts = '{\"\(u)d800\": 1}'")
        await #expect(throws: Failure.corrupt("the column counts holds an escape of half a character")) { try await store.snapshots(org: org) }
    }

    /// Which escapes are half a character. `~` stands for a backslash and a u.
    @Test(arguments: [
        ("~d83d~de00", false), ("~0041", false), ("\\\\ud800", false), ("plain", false),
        ("~d800", true), ("~dc00", true), ("~d83d~0041", true), ("~d83dx", true), ("~d83d~d83d", true), ("~de00~d83d", true),
    ])
    func aLoneSurrogateIsFound(_ escapes: String, lone: Bool) {
        let text = escapes.replacingOccurrences(of: "~", with: "\u{5C}u")
        #expect(SnapshotStore.hasLoneSurrogate("{\"a\": \"" + text + "\"}") == lone, "\(text)")
    }

    /// Bytes that aren't UTF-8 in a text column say which column, never read as U+FFFD (a changed id or name would pass for
    /// another).
    @Test func textThatIsntUTF8SaysWhichColumn() async throws {
        let root = try Scratch.folder()
        defer { Scratch.remove(root) }
        let folder = root.appending(path: "store")
        let store = try SnapshotStore(storage: .folder(folder), appVersion: "1")
        let org = Scratch.apple("acme")
        let id = try await store.record(org: org, takenAt: Scratch.noon, resources: ["devices": [Scratch.device("SERIAL0001")]])
        let file = try Scratch.open(Scratch.path(folder.appending(path: "history.sqlite")))
        try file.execute("UPDATE items SET item_id = CAST(X'5345524941C3' AS TEXT)")
        await #expect(throws: Failure.corrupt("the column item_id isn't UTF-8")) { try await store.load(id, org: org) }
        try file.execute("UPDATE items SET item_id = 'SERIAL0001'")
        try file.execute("UPDATE snapshots SET org_name = CAST(X'4578FF' AS TEXT)")
        await #expect(throws: Failure.corrupt("the column org_name isn't UTF-8")) { try await store.snapshots(org: org) }
        try file.execute("UPDATE snapshots SET org_name = 'Example', org_id = CAST(X'61C0' AS TEXT)")
        await #expect(throws: Failure.corrupt("the column org_id isn't UTF-8")) { try await store.orgIDs() }
    }
}
