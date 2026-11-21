import AppleModels
import AppModels
import Foundation
import History
import JSONAPI
import Orgs
import SQLite3
import Testing
import TestSupport

/// abapit's history imported into the snapshot store (plan Phase 3): mapped to orgs by client ID, never by name; every item
/// through the operator's snapshot policy; `counts` filled so `latest` answers; no duplicates on a second import; error text
/// never carried; and the file the operator chose never changed. Over synthetic abapit-shaped files in a temporary folder; the
/// operator's real file is never read.
@MainActor
@Suite("History import", .serialized)
struct HistoryTransferTests {
    // MARK: an abapit file

    /// One snapshot row and its items, as abapit's `take_snapshot` writes them.
    struct Row {
        var id: Int64
        var takenAt: String
        var client: String
        var name = "Example org"
        var scope = "business"
        var version = "0.2.0"
        var errors = "{}"
        var items: [(resource: String, id: String, attributes: JSONObject)] = []
    }

    /// A file with abapit's own `SCHEMA` (the golden's text) and `rows`, in a new folder; its path.
    static func abapitFile(_ rows: [Row], in folder: URL, schema: String? = nil) throws -> String {
        let path = folder.path(percentEncoded: false) + "/history.sqlite"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = handle else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let ddl = try schema ?? (try Fixtures.parityValue("history")["schema"]?.string).unwrap()
        guard sqlite3_exec(db, ddl, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        // Plain literals: the values are the tests' own, and quotes are doubled.
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        for row in rows {
            let insert = "INSERT INTO snapshots (id, taken_at, org_client_id, org_name, org_scope, abapit_version, errors) VALUES "
                + "(\(row.id), \(quote(row.takenAt)), \(quote(row.client)), \(quote(row.name)), \(quote(row.scope)), \(quote(row.version)), \(quote(row.errors)))"
            guard sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            for item in row.items {
                let sql = "INSERT INTO items VALUES (\(row.id), \(quote(item.resource)), \(quote(item.id)), \(quote(JSONValue.object(item.attributes).jsonText)))"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        chmod(path, 0o600)
        return path
    }

    static func folder() throws -> URL { try CollectorTests.folder() }

    static func device(_ serial: String, _ extra: JSONObject = [:]) -> (resource: String, id: String, attributes: JSONObject) {
        var attributes: JSONObject = ["serialNumber": .string(serial), "deviceModel": .string("MacBook Air"), "productFamily": .string("Mac"), "status": .string("ASSIGNED")]
        for member in extra.members { attributes[member.key] = member.value }
        return ("devices", serial, attributes)
    }

    static let a = World.clientID("a"), b = World.clientID("b")

    /// The bytes of every file in `folder`: what a canary is looked for in.
    static func bytes(in folder: URL) throws -> Data {
        var all = Data()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { all += try Data(contentsOf: file) }
        return all
    }

    /// A history in a folder of its own, so the test can read its bytes.
    static func world(profiles: [OrgProfile]? = nil, store folder: URL? = nil) async throws -> World {
        var opener: (@MainActor () -> Result<SnapshotStore, SnapshotStore.Failure>)?
        if let folder {
            let opened = Result { () throws(SnapshotStore.Failure) in try SnapshotStore(storage: .folder(folder), appVersion: "test") }
            opener = { opened }
        }
        return try await World.make(profiles: profiles, history: opener)
    }

    func stored(_ world: World, org: String = "a") async throws -> [SnapshotStore.Summary] {
        try await world.history!.snapshots(org: world.orgs.store[org]!)
    }

    // MARK: mapping

    /// A snapshot goes to the org of the active client whose client ID it carries, however the client ID is written; one no org
    /// here has is skipped and counted, whatever name it carries, and never put under the active org.
    @Test func snapshotsAreMappedByClientIDAndNeverByName() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try await Self.world()
        let rows = [
            // The active org's client ID, upper-cased and padded as `clientKey` reads it, under another name.
            Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: "  " + Self.a.uppercased() + " ", name: "Renamed Since", items: [Self.device("MINE0001")]),
            // Another client's org, carrying the active org's name.
            Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: Self.b, name: "Org a", items: [Self.device("OTHER0001")]),
            // An account nobody here has, with the active org's name too.
            Row(id: 3, takenAt: "2026-09-03T08:00:00Z", client: "SOMEONE-ELSE-CANARYCLIENT", name: "Org a", items: [Self.device("STRANGER0001")]),
            Row(id: 4, takenAt: "2026-09-04T08:00:00Z", client: "SOMEONE-ELSE-CANARYCLIENT", name: "Org a", items: [Self.device("STRANGER0002")]),
            // No client ID at all (a Mosyle org's is empty), with the active org's name.
            Row(id: 5, takenAt: "2026-09-05T08:00:00Z", client: "", name: "Org a", items: [Self.device("NOBODY0001")]),
        ]
        let path = try Self.abapitFile(rows, in: folder)
        let outcome = await world.screens.historyTransfer.importHistory(from: URL(filePath: path))
        guard case .imported(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.imported == 1 && report.orgs == 1 && report.skipped == 4 && report.skippedAccounts == 3 && report.alreadyHere == 0)
        let mine = try await stored(world)
        #expect(mine.map(\.takenAt) == ["2026-09-01T08:00:00Z"] && mine.first?.clientID == Self.a && mine.first?.orgName == "Org a")
        let snapshot = try await world.history!.load(mine[0].id, org: world.orgs.store["a"]!)
        #expect(snapshot.resources["devices"]?.map(\.id) == ["MINE0001"], "only the matched snapshot's devices, never a stranger's")
        // Nothing is under the other client's org either, and the words never name an id.
        #expect(try await stored(world, org: "b").isEmpty)
        let words = world.screens.historyTransfer.summary ?? ""
        #expect(words == "Imported 1 snapshot for 1 organization. 4 skipped because no organization here has that client ID (3 accounts). 0 attributes left out by the snapshot policy.", "\(words)")
        #expect(!words.contains("CANARYCLIENT") && !words.contains(Self.b))
        // The other client, once active, takes its own; the first import's snapshot isn't repeated.
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "b")).id)
        #expect(world.screens.historyTransfer.summary == nil, "a result is never shown under another client")
        _ = await world.screens.historyTransfer.importHistory(from: URL(filePath: path))
        #expect(try await stored(world, org: "b").map(\.takenAt) == ["2026-09-02T08:00:00Z"])
        #expect(try await stored(world).count == 1)
    }

    /// Mosyle orgs and orgs of another provider are never a target: a client ID is an Apple API account's.
    @Test func targetsAreTheApplePlainOrgsWithOneClientID() {
        var mosyle = OrgProfile(id: "m", name: "M", provider: .mosyle)
        mosyle.clientID = "SHARED"
        var apple = World.profile("a"), twin = World.profile("b")
        apple.clientID = "SHARED"
        twin.clientID = "SHARED"
        #expect(HistoryTransfer.targets([mosyle]).isEmpty, "a Mosyle org has no client ID")
        #expect(HistoryTransfer.targets([apple, mosyle]).keys.sorted() == ["shared"])
        #expect(HistoryTransfer.targets([apple, twin]).isEmpty, "a client ID two orgs hold maps to neither")
        var blank = World.profile("c")
        blank.clientID = "  "
        #expect(HistoryTransfer.targets([blank]).isEmpty)
    }

    // MARK: the policy

    /// Every item passes through the snapshot policy: what the operator left out is never stored, in the database or beside it,
    /// and what he kept is.
    @Test func everyItemPassesThroughTheSnapshotPolicy() async throws {
        let source = try Self.folder(), history = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: history) }
        let world = try await Self.world(store: history)
        let device = Self.device("DEV0001", ["imei": .array([.string("CANARYIMEI")]), "wifiMacAddress": .string("CA:NA:RY:WI:FI:00"), "eid": .string("CANARYEID")])
        let items: [(resource: String, id: String, attributes: JSONObject)] = [
            device,
            ("mdm_servers", "S1", ["serverName": .string("Main"), "serverType": .string("MDM"), "lastConnectedIp": .string("198.51.100.234")]),
            ("users", "U1", ["managedAppleAccount": .string("u1@appleid.example.com"), "status": .string("ACTIVE"), "firstName": .string("CANARYFIRST"),
                             "email": .string("canary.mail@example.com"), "phoneNumbers": .array([.string("CANARYPHONE")]), "jobTitle": .string("CANARYJOB")]),
            ("packages", "P1", ["name": .string("Agent"), "version": .string("1.2"), "url": .string("https://deploy:CANARYURLPW@canaryhost.example.com/a.pkg"),
                                "description": .string("Mirror: https://deploy:CANARYDESCPW@mirror.example.com/a.pkg")]),
            ("configurations", "C1", ["name": .string("Wi-Fi"), "customSettingsValues": .object(["configurationProfile": .string("<plist>CANARYWIFIPW</plist>")])]),
            // Not a resource the snapshot policy keeps at all.
            ("secrets", "X1", ["token": .string("CANARYTOKEN")]),
            ("devices_extra", "X2", ["serialNumber": .string("CANARYEXTRA")]),
        ]
        let path = try Self.abapitFile([Row(id: 7, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: items)], in: source)
        guard case .imported(let report) = await world.screens.historyTransfer.importHistory(from: URL(filePath: path)) else { Issue.record("not imported"); return }
        // imei, wifiMacAddress, eid | lastConnectedIp | firstName, email, phoneNumbers, jobTitle | url | customSettingsValues is kept (null in a list read)
        #expect(report.attributesLeftOut == 3 + 1 + 4 + 1)
        #expect(report.resourcesLeftOut == 2)
        let snapshot = try await world.history!.load(try #require(try await stored(world).first).id, org: world.orgs.active!)
        func keys(_ resource: String, _ id: String) -> [String] { (snapshot.resources[resource]?.first { $0.id == id }?.attributes.keys ?? []).sorted() }
        #expect(keys("devices", "DEV0001") == ["deviceModel", "productFamily", "serialNumber", "status"])
        #expect(keys("mdm_servers", "S1") == ["serverName", "serverType"])
        #expect(keys("users", "U1") == ["managedAppleAccount", "status"])
        #expect(keys("packages", "P1") == ["description", "name", "version"])
        #expect(keys("configurations", "C1") == ["customSettingsValues", "name"])
        #expect(snapshot.resources.keys.sorted() == ["configurations", "devices", "mdm_servers", "packages", "users"])
        #expect(snapshot.summary.notes["devices"] == "3 attribute values left out by the snapshot policy")
        #expect(snapshot.summary.notes["packages"]?.contains("1 attribute value left out by the snapshot policy; an address was masked in 1 item") == true,
                "\(snapshot.summary.notes)")
        let description = snapshot.resources["packages"]?.first?.attributes["description"]?.string ?? ""
        #expect(!description.contains("CANARYDESCPW"), "\(description)")
        let stored = try Self.bytes(in: history)
        for canary in CollectorTests.canaries + ["CANARYTOKEN", "CANARYEXTRA"] {
            #expect(stored.range(of: Data(canary.utf8)) == nil, "\(canary) reached the history")
        }
        // The source is the operator's: its bytes still hold what abapit stored, which is the point of reading it read-only.
        #expect(try Data(contentsOf: URL(filePath: path)).range(of: Data("CANARYTOKEN".utf8)) != nil)
    }

    /// A School org has no Business-only resources: a snapshot of one that carries them keeps none.
    @Test func aSchoolOrgKeepsNoBusinessOnlyResource() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await World.make(profiles: [World.profile("a", scope: .school)])
        let items: [(resource: String, id: String, attributes: JSONObject)] = [
            Self.device("DEV0001"), ("users", "U1", ["managedAppleAccount": .string("u1@appleid.example.com")]), ("apps", "A1", ["name": .string("Pages")]),
        ]
        let path = try Self.abapitFile([Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, scope: "school", errors: #"{"users": "x", "applecare": "y"}"#, items: items)], in: source)
        guard case .imported(let report) = await world.screens.historyTransfer.importHistory(from: URL(filePath: path)) else { Issue.record("not imported"); return }
        #expect(report.resourcesLeftOut == 3, "users, apps and users' error")
        let snapshot = try await world.history!.load(try #require(try await stored(world).first).id, org: world.orgs.active!)
        #expect(snapshot.resources.keys.sorted() == ["devices"] && snapshot.summary.counts == ["devices": 1] && snapshot.summary.errors == ["applecare": "abapit error"])
    }

    // MARK: counts, errors, ordering

    /// `counts` is filled for every resource the snapshot holds, so `latest` answers from imported history; a resource abapit
    /// failed on is an error code and nothing of its text; AppleCare read in part keeps its items with a part-read code.
    @Test func countsAreFilledAndErrorsAreCodesOnly() async throws {
        let source = try Self.folder(), history = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: history) }
        let world = try await Self.world(store: history)
        let errorText = #"{"users": "HTTPError: 403 https://api-business.apple.com/v1/users?token=CANARYERRORTEXT", "applecare_partial": "2 device(s) failed: CANARYSERIAL", "elsewhere": "CANARYOTHER"}"#
        let rows = [
            Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1"), Self.device("D2"), ("users", "U1", ["status": .string("ACTIVE")])]),
            Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: Self.a, errors: errorText,
                items: [Self.device("D1"), ("applecare", "D1:0", ["serialNumber": .string("D1"), "status": .string("ACTIVE")])]),
        ]
        let path = try Self.abapitFile(rows, in: source)
        guard case .imported(let report) = await world.screens.historyTransfer.importHistory(from: URL(filePath: path)) else { Issue.record("not imported"); return }
        #expect(report.imported == 2 && report.resourcesLeftOut == 1, "an error for a resource the policy doesn't list is counted, its key never kept")
        let summaries = try await stored(world)
        #expect(summaries.map(\.takenAt) == ["2026-09-02T08:00:00Z", "2026-09-01T08:00:00Z"], "newest first")
        let first = try #require(summaries.last), second = try #require(summaries.first)
        #expect(first.counts == ["devices": 2, "users": 1] && first.errors.isEmpty && first.writtenBy == "abapit 0.2.0")
        #expect(second.counts == ["devices": 1, "applecare": 1])
        #expect(second.errors == ["users": "abapit error", "applecare": "abapit partial"])
        // `latest`: devices from the newest snapshot; users failed at the newest that tried, with the good copy before it;
        // AppleCare read in part is never a good copy.
        let org = try #require(world.orgs.store["a"])
        guard case .read(let devices)? = try await world.history!.latest("devices", org: org) else { Issue.record("devices"); return }
        #expect(devices.summary.id == second.id && devices.items.map(\.id) == ["D1"])
        guard case .failed(let tried, let error, let newest)? = try await world.history!.latest("users", org: org) else { Issue.record("users"); return }
        #expect(tried.id == second.id && error == "abapit error" && newest?.summary.id == first.id && newest?.items.map(\.id) == ["U1"])
        guard case .failed(_, let partial, let none)? = try await world.history!.latest("applecare", org: org) else { Issue.record("applecare"); return }
        #expect(partial == "abapit partial" && none == nil)
        let stored = try Self.bytes(in: history)
        for canary in ["CANARYERRORTEXT", "api-business", "CANARYSERIAL", "CANARYOTHER", "elsewhere"] { #expect(stored.range(of: Data(canary.utf8)) == nil, "\(canary)") }
    }

    /// Plan defect 13, listed: where the newest snapshot failed to read a resource, abapit's `latest_resource` shows the older
    /// copy as if it were current; this store says it failed and shows the older copy as the last good one.
    @Test func aFailureAtTheNewestSnapshotIsNotHiddenByAnOlderCopy() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]),
                    Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: Self.a, errors: #"{"devices": "boom"}"#)]
        _ = await world.screens.historyTransfer.importHistory(from: URL(filePath: try Self.abapitFile(rows, in: source)))
        let org = try #require(world.orgs.store["a"])
        guard case .failed(let tried, "abapit error", let newest)? = try await world.history!.latest("devices", org: org) else { Issue.record("devices"); return }
        #expect(tried.takenAt == "2026-09-02T08:00:00Z" && newest?.summary.takenAt == "2026-09-01T08:00:00Z" && newest?.items.map(\.id) == ["D1"])
    }

    /// Imported in abapit's id order whatever order the file's rows were written in, so the store's ids follow the order the
    /// snapshots were taken in.
    @Test func snapshotsAreRecordedOldestFirst() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 30, takenAt: "2026-09-03T08:00:00Z", client: Self.a), Row(id: 10, takenAt: "2026-09-01T08:00:00Z", client: Self.a),
                    Row(id: 20, takenAt: "2026-09-02T08:00:00Z", client: Self.a)]
        _ = await world.screens.historyTransfer.importHistory(from: URL(filePath: try Self.abapitFile(rows, in: source)))
        let found = try await stored(world)
        #expect(found.map(\.takenAt) == ["2026-09-03T08:00:00Z", "2026-09-02T08:00:00Z", "2026-09-01T08:00:00Z"])
        #expect(found.map(\.id) == found.map(\.id).sorted(by: >), "ids descend with time")
    }

    // MARK: again, and what isn't abapit's

    /// The same file again adds nothing: each snapshot is already here, and says so.
    @Test func importingTheSameFileAgainCreatesNoDuplicates() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]),
                    Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: Self.a, items: [Self.device("D1"), Self.device("D2")])]
        let url = URL(filePath: try Self.abapitFile(rows, in: source))
        _ = await world.screens.historyTransfer.importHistory(from: url)
        let before = try await stored(world)
        guard case .imported(let again) = await world.screens.historyTransfer.importHistory(from: url) else { Issue.record("not imported"); return }
        #expect(again.imported == 0 && again.alreadyHere == 2 && again.orgs == 0)
        #expect(try await stored(world) == before)
        #expect(world.screens.historyTransfer.summary?.contains("2 were already here.") == true)
    }

    /// A file that isn't abapit's is refused in words, and nothing is written.
    @Test func aFileThatIsNotAbapitsIsRefusedAndNothingIsWritten() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let path = source.path(percentEncoded: false) + "/other.sqlite"
        var handle: OpaquePointer?
        #expect(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        sqlite3_exec(handle, "CREATE TABLE snapshots (id INTEGER, org_id TEXT)", nil, nil, nil)
        sqlite3_close(handle)
        let outcome = await world.screens.historyTransfer.importHistory(from: URL(filePath: path))
        guard case .refused(let words) = outcome else { Issue.record("\(outcome)"); return }
        #expect(words.contains("isn't abapit's history") && world.screens.historyTransfer.problem == words && world.screens.historyTransfer.summary == nil)
        #expect(try await stored(world).isEmpty)
    }

    /// A switch of client before the first snapshot is read stops the import: nothing is mapped to the new client's org from
    /// the old client's start, and nothing is shown under the new client.
    @Test func aSwitchStopsTheImportAndShowsNothingUnderTheNewClient() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")])]
        let url = URL(filePath: try Self.abapitFile(rows, in: source))
        let task = Task { await world.screens.historyTransfer.importHistory(from: url) }
        await Task.yield()
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "b")).id)
        let outcome = await task.value
        guard case .stopped(let report) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.imported == 0)
        #expect(world.screens.historyTransfer.summary == nil && world.screens.historyTransfer.problem == nil)
        #expect(try await stored(world).isEmpty)
        #expect(try await stored(world, org: "b").isEmpty)
    }

    // MARK: export

    /// The copy the operator saves: what the panel says it holds, a private database of the history, never over a file.
    @Test func exportingACopyWritesAPrivateDatabaseAndNeverReplacesAFile() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try await Self.world()
        try await world.history!.record(org: try #require(world.orgs.store["a"]), takenAt: Date(timeIntervalSince1970: 1_795_000_000), resources: ["devices": [Resource(type: "devices", id: "D1", attributes: Self.device("D1").attributes)]])
        let transfer = world.screens.historyTransfer
        let copy = folder.appending(path: "copy.sqlite")
        await transfer.exportCopy(to: copy)
        #expect(transfer.problem == nil && transfer.summary == "Saved a copy of the snapshot history as copy.sqlite.")
        var info = stat()
        #expect(stat(copy.path(percentEncoded: false), &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(try Data(contentsOf: copy).starts(with: Data("SQLite format 3".utf8)))
        await transfer.exportCopy(to: copy)
        #expect(transfer.summary == nil && transfer.problem?.contains("already exists") == true, "\(transfer.problem ?? "")")
        for word in ["serial numbers", "Managed Apple Accounts", "Needs-attention", "no key or token", "Only you can read"] {
            #expect(HistoryTransfer.exportWords.contains(word), "the panel says: \(word)")
        }
    }
}

extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw CocoaError(.fileReadCorruptFile) }
        return self
    }
}
