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
        /// Items as stored text, for a row that isn't JSON.
        var rawItems: [(resource: String, id: String, text: String)] = []
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
            for item in row.rawItems {
                let sql = "INSERT INTO items VALUES (\(row.id), \(quote(item.resource)), \(quote(item.id)), \(quote(item.text)))"
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            }
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
        let first = try #require(mine.first)
        #expect(mine.map(\.takenAt) == ["2026-09-01T08:00:00Z"] && first.clientID == Self.a && first.orgName == "Org a")
        let snapshot = try await world.history!.load(first.id, org: world.orgs.store["a"]!)
        #expect(snapshot.resources["devices"]?.map(\.id) == ["MINE0001"], "only the matched snapshot's devices, never a stranger's")
        // Nothing is under the other client's org either, and the words never name an id.
        #expect(try await stored(world, org: "b").isEmpty)
        let words = world.screens.historyTransfer.summary ?? ""
        #expect(words == "Imported 1 snapshot for 1 organization. 4 skipped because no organization of this client has that client ID (3 accounts); switch client to import another customer's. 0 attributes left out by the snapshot policy.", "\(words)")
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
        #expect(world.screens.historyTransfer.summary?.contains("2 had the same time as a snapshot already here") == true)
        #expect(world.screens.historyTransfer.summary?.contains("weren't imported again") == true)
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

    /// A switch of client after the snapshot is read and before it is written (the `beforeWrite` hook) stops the import: nothing is
    /// mapped to the new client's org from the old client's start, and nothing is shown under the new client.
    @Test func aSwitchStopsTheImportAndShowsNothingUnderTheNewClient() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")])]
        let url = URL(filePath: try Self.abapitFile(rows, in: source))
        // The switch comes inside the import, before its write, through the hook: no Task and no yield, so no race against the import's hops.
        let other = try #require(world.orgs.store.client(of: "b")).id
        world.screens.historyTransfer.beforeWrite = { world.orgs.selectClient(other) }
        let outcome = await world.screens.historyTransfer.importHistory(from: url)
        guard case .stopped(let report, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.imported == 0)
        #expect(world.screens.historyTransfer.summary == nil && world.screens.historyTransfer.problem == nil)
        #expect(try await stored(world).isEmpty)
        #expect(try await stored(world, org: "b").isEmpty)
    }

    // MARK: the rest of the review (PR 36)

    /// Two snapshots of one org in one second, in one file, are both written: the second is this run's own, not "already here".
    /// The same file again finds both already there, and says it by time, not as a repeat of one.
    @Test func twoSnapshotsOfOneSecondAreBothImported() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]),
                    Row(id: 2, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D2")])]
        let url = URL(filePath: try Self.abapitFile(rows, in: source))
        guard case .imported(let first) = await world.screens.historyTransfer.importHistory(from: url) else { Issue.record("not imported"); return }
        #expect(first.imported == 2 && first.alreadyHere == 0 && !first.words.contains("same time"))
        #expect(try await stored(world).count == 2)
        guard case .imported(let again) = await world.screens.historyTransfer.importHistory(from: url) else { Issue.record("not imported"); return }
        #expect(again.imported == 0 && again.alreadyHere == 2)
        #expect(try await stored(world).count == 2)
    }

    /// A row that doesn't read, or a time that doesn't parse, is counted and skipped; the snapshots around it are imported.
    @Test func aCorruptRowAndAnUnparseableTimeAreSkippedAndCounted() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        var corrupt = Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: Self.a, items: [Self.device("D2")])
        corrupt.rawItems = [("devices", "BAD", "[1, 2] not an object CANARYBAD")]
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]), corrupt,
                    Row(id: 3, takenAt: "2026-09-03T08:00:00Z", client: Self.a, items: [Self.device("D3")])]
        guard case .imported(let report) = await world.screens.historyTransfer.importHistory(from: URL(filePath: try Self.abapitFile(rows, in: source))) else {
            Issue.record("a corrupt row must not abort the import"); return
        }
        #expect(report.imported == 2 && report.unreadable == 1)
        #expect(world.screens.historyTransfer.summary?.contains("1 couldn't be read.") == true && world.screens.historyTransfer.summary?.contains("CANARYBAD") == false)
        #expect(try await stored(world).map(\.takenAt) == ["2026-09-03T08:00:00Z", "2026-09-01T08:00:00Z"])
        // An unparseable time: skipped the same way.
        let other = try Self.folder()
        defer { try? FileManager.default.removeItem(at: other) }
        let world2 = try await Self.world()
        let timed = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a), Row(id: 2, takenAt: "yesterday-ish CANARYTIME", client: Self.a),
                     Row(id: 3, takenAt: "2026-09-03T08:00:00Z", client: Self.a)]
        guard case .imported(let report2) = await world2.screens.historyTransfer.importHistory(from: URL(filePath: try Self.abapitFile(timed, in: other))) else {
            Issue.record("an unparseable time must not abort the import"); return
        }
        #expect(report2.imported == 2 && report2.unreadable == 1)
        #expect(world2.screens.historyTransfer.summary?.contains("1 couldn't be read.") == true && world2.screens.historyTransfer.summary?.contains("CANARYTIME") == false)
    }

    /// Before each write the org is looked up again: removed (or on another client ID) since the import started, nothing more is
    /// written under it, and the import says why. Here the Apple org is removed while the client's Mosyle org is the active one,
    /// the one change that doesn't bump the generation.
    @Test func anOrgRemovedDuringTheImportIsNotWrittenUnder() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await World.make(mosyle: true)
        world.orgs.select("m")
        let transfer = world.screens.historyTransfer
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]),
                    Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: Self.a, items: [Self.device("D2")])]
        let generation = world.orgs.generation
        transfer.beforeWrite = { try? await world.orgs.remove("a", deleteSecrets: false) }
        let outcome = await transfer.importHistory(from: URL(filePath: try Self.abapitFile(rows, in: source)))
        #expect(world.orgs.generation == generation, "the removal didn't bump the generation: only the lookup can catch it")
        guard case .stopped(let report, let why?) = outcome else { Issue.record("\(outcome)"); return }
        #expect(report.imported == 0 && why.contains("Org a was removed or its client ID changed"))
        #expect(transfer.problem?.hasPrefix("Stopped: Org a was removed") == true)
        #expect(try await world.history!.snapshots(org: World.profile("a")).isEmpty, "nothing under the removed org's id")
    }

    @Test func anOrgIsTheSameOnlyUnderItsClientID() async throws {
        let world = try await World.make()
        let org = try #require(world.orgs.store["a"])
        #expect(HistoryTransfer.isStill(org, in: world.orgs))
        var other = org
        other.clientID = "SOMEONE-ELSE"
        #expect(!HistoryTransfer.isStill(other, in: world.orgs))
        #expect(!HistoryTransfer.isStill(World.profile("zzz"), in: world.orgs))
        var padded = org
        padded.clientID = "  " + org.clientID.lowercased() + " "
        #expect(HistoryTransfer.isStill(padded, in: world.orgs), "the same key as the store's compare it")
    }

    /// A time after tomorrow is no snapshot's: stored, it would outrank every real snapshot in `latest` and never be pruned. It is
    /// counted as unreadable, "dated in the future", and skipped; a time within the day is kept.
    @Test func aFutureDatedSnapshotIsSkippedAndCounted() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]),
                    Row(id: 2, takenAt: "2099-01-01T00:00:00Z", client: Self.a, items: [Self.device("D2")]),
                    Row(id: 3, takenAt: "2026-09-03T08:00:00Z", client: Self.a, items: [Self.device("D3")])]
        guard case .imported(let report) = await world.screens.historyTransfer.importHistory(from: URL(filePath: try Self.abapitFile(rows, in: source))) else {
            Issue.record("not imported"); return
        }
        #expect(report.imported == 2 && report.unreadable == 1 && report.future == 1)
        #expect(world.screens.historyTransfer.summary?.contains("1 couldn't be read (1 dated in the future).") == true)
        #expect(try await stored(world).map(\.takenAt) == ["2026-09-03T08:00:00Z", "2026-09-01T08:00:00Z"], "the future one is never stored")
    }

    /// The boundary, with a clock of the test's own: a day ahead is kept, a minute past it is not.
    @Test func theFutureLimitIsADayAfterNow() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let world = try await Self.world()
        let now = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18T11:06:40Z
        let transfer = HistoryTransfer(orgs: world.orgs, now: { now })
        let rows = [Row(id: 1, takenAt: "2026-11-19T11:06:40Z", client: Self.a), Row(id: 2, takenAt: "2026-11-19T11:07:41Z", client: Self.a)]
        guard case .imported(let report) = await transfer.importHistory(from: URL(filePath: try Self.abapitFile(rows, in: source))) else { Issue.record("not imported"); return }
        #expect(report.imported == 1 && report.future == 1)
    }

    /// With one client the screens never say "client" (there is no other to switch to or mix with); with two they do.
    @Test func theWordsSayClientOnlyWhenThereAreSeveral() async throws {
        let source = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source) }
        let rows = [Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: [Self.device("D1")]),
                    Row(id: 2, takenAt: "2026-09-02T08:00:00Z", client: "SOMEONE-ELSE", items: [Self.device("D2")])]
        let url = URL(filePath: try Self.abapitFile(rows, in: source))
        // One client.
        let one = try await World.make(profiles: [World.profile("a")])
        let single = one.screens.historyTransfer
        #expect(!one.orgs.showsClients)
        #expect(single.settingsWords == "Import abapit's history from the retired Python tool, or save a copy of your history to open in sqlite3 or Datasette.")
        #expect(single.exportFileName == "history.sqlite")
        #expect(!single.exportWords.contains("client") && single.exportWords.contains("your organizations' snapshots"), "\(single.exportWords)")
        _ = await single.importHistory(from: url)
        #expect(single.summary == "Imported 1 snapshot for 1 organization. 1 skipped because no organization here has that client ID (1 account). 0 attributes left out by the snapshot policy.", "\(single.summary ?? "")")
        let copy = source.appending(path: "copy.sqlite")
        await single.exportCopy(to: copy)
        #expect(single.summary == "Saved a copy of the snapshot history as copy.sqlite.")
        // Two clients.
        let two = try await World.make()
        let several = two.screens.historyTransfer
        #expect(two.orgs.showsClients)
        #expect(several.settingsWords.contains("this client's history") && several.exportWords.contains("Org a's snapshots only"))
        _ = await several.importHistory(from: url)
        #expect(several.summary?.contains("no organization of this client has that client ID (1 account); switch client to import another customer's.") == true)
    }


    // MARK: the policy's shape rule (items 5 and 6)

    /// A kept attribute keeps a scalar or a list of scalars; an object (or a list with one) under a kept name, which Apple never
    /// sends there, is left out and counted, whoever sent it.
    @Test func aKeptAttributeNeverHoldsANestedObject() async throws {
        let device = Resource(type: "devices", id: "D1", attributes: [
            "serialNumber": .string("D1"), "deviceModel": .object(["imei": .string("CANARYNESTEDIMEI"), "wifiMacAddress": .string("CANARYNESTEDMAC")]),
            "status": .string("ASSIGNED"), "color": .array([.string("blue"), .object(["email": .string("CANARYNESTEDLISTMAIL")])]),
            "productFamily": .array([.string("Mac"), .string("iPad")]), "orderNumber": .null,
        ])
        let kept = SnapshotPolicy.keep(device, SnapshotPolicy.devices)
        #expect(kept.item.attributes.keys.sorted() == ["orderNumber", "productFamily", "serialNumber", "status"])
        #expect(kept.unknown == [Array("deviceModel".utf8), Array("color".utf8)])
        let user = Resource(type: "users", id: "U1", attributes: [
            "managedAppleAccount": .string("u1@appleid.example.com"), "status": .object(["email": .string("CANARYNESTEDMAIL"), "firstName": .string("CANARYNESTEDNAME")]),
        ])
        let keptUser = SnapshotPolicy.keep(user, SnapshotPolicy.users)
        #expect(keptUser.item.attributes.keys == ["managedAppleAccount"])
        for item in [kept.item, keptUser.item] { #expect(!JSONValue.object(item.attributes).jsonText.contains("CANARYNESTED")) }
    }

    /// The one object Apple sends under a kept name, `customSettingsValues`, keeps its two inner keys and nothing else, and its
    /// profile is withheld by `keep` itself, for the collector's reads and an import alike.
    @Test func keepWithholdsAProfileAndAllowlistsItsInnerKeys() async throws {
        let configuration = Resource(type: "configurations", id: "C1", attributes: [
            "name": .string("Wi-Fi"), "customSettingsValues": .object([
                "configurationProfile": .string("<plist>CANARYKEEPWIFIPW</plist>"), "filename": .string("wifi.mobileconfig"), "extra": .string("CANARYKEEPEXTRA"),
            ]),
        ])
        let kept = SnapshotPolicy.keep(configuration, SnapshotPolicy.configurations)
        let text = JSONValue.object(kept.item.attributes).jsonText
        #expect(!text.contains("CANARYKEEP") && text.contains("wifi.mobileconfig"), "\(text)")
        let inner = try #require(kept.item.attributes["customSettingsValues"]?.object)
        #expect(inner.keys.sorted() == ["configurationProfile", "filename"] && inner["configurationProfile"]?.string?.contains("withheld") == true)
        // A string where an object is expected is withheld too, and a nested object inside an inner key is left out.
        let odd = Resource(type: "configurations", id: "C2", attributes: ["customSettingsValues": .string("CANARYKEEPSTRING")])
        #expect(!JSONValue.object(SnapshotPolicy.keep(odd, SnapshotPolicy.configurations).item.attributes).jsonText.contains("CANARYKEEP"))
        let deep = Resource(type: "configurations", id: "C3", attributes: ["customSettingsValues": .object(["filename": .object(["x": .string("CANARYKEEPDEEP")])])])
        let keptDeep = SnapshotPolicy.keep(deep, SnapshotPolicy.configurations)
        #expect(!JSONValue.object(keptDeep.item.attributes).jsonText.contains("CANARYKEEP"))
    }

    /// Through an import, nested canaries under kept names never reach the history.
    @Test func nestedValuesUnderKeptNamesNeverReachTheHistory() async throws {
        let source = try Self.folder(), history = try Self.folder()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: history) }
        let world = try await Self.world(store: history)
        let items: [(resource: String, id: String, attributes: JSONObject)] = [
            Self.device("D1", ["deviceModel": .object(["imei": .string("CANARYIMPNESTED")])]),
            ("users", "U1", ["managedAppleAccount": .string("u1@appleid.example.com"), "status": .object(["email": .string("CANARYIMPMAIL"), "firstName": .string("CANARYIMPNAME")])]),
        ]
        let path = try Self.abapitFile([Row(id: 1, takenAt: "2026-09-01T08:00:00Z", client: Self.a, items: items)], in: source)
        guard case .imported(let report) = await world.screens.historyTransfer.importHistory(from: URL(filePath: path)) else { Issue.record("not imported"); return }
        #expect(report.attributesLeftOut == 2)
        let stored = try Self.bytes(in: history)
        for canary in ["CANARYIMPNESTED", "CANARYIMPMAIL", "CANARYIMPNAME"] { #expect(stored.range(of: Data(canary.utf8)) == nil, "\(canary)") }
    }

    // MARK: export

    /// The copy is the active client's only (the clients rule): another client's snapshots and findings, and an removed org's
    /// history, are not in its bytes; the file is named for the client and the panel says so.
    @Test func aCopyHoldsTheActiveClientsHistoryOnly() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try await Self.world()
        let a = try #require(world.orgs.store["a"]), b = try #require(world.orgs.store["b"])
        let history = try #require(world.history)
        func device(_ serial: String) -> Resource { Resource(type: "devices", id: serial, attributes: Self.device(serial).attributes) }
        try await history.record(org: a, takenAt: Date(timeIntervalSince1970: 1_795_000_000), resources: ["devices": [device("CANARYCLIENTAONE")]])
        try await history.record(org: b, takenAt: Date(timeIntervalSince1970: 1_795_000_100), resources: ["devices": [device("CANARYCLIENTBONE")]])
        try await history.seen(org: a, rule: "rulea", subjects: ["CANARYSUBJECTA"], at: Date(timeIntervalSince1970: 1_795_000_000))
        try await history.seen(org: b, rule: "ruleb", subjects: ["CANARYSUBJECTB"], at: Date(timeIntervalSince1970: 1_795_000_000))
        let transfer = world.screens.historyTransfer
        #expect(transfer.exportFileName == "Org a - history.sqlite" && transfer.exportWords.contains("Org a's snapshots only"))
        for word in ["serial numbers", "Managed Apple Accounts", "Needs-attention", "no other client's", "no key or token", "Only you can read"] {
            #expect(transfer.exportWords.contains(word), "the panel says: \(word)")
        }
        let copy = folder.appending(path: "copy.sqlite")
        await transfer.exportCopy(to: copy)
        #expect(transfer.problem == nil && transfer.summary == "Saved a copy of Org a's snapshot history as copy.sqlite.")
        let bytes = try Data(contentsOf: copy)
        #expect(bytes.range(of: Data("CANARYCLIENTAONE".utf8)) != nil && bytes.range(of: Data("CANARYSUBJECTA".utf8)) != nil, "this client's is in it")
        for canary in ["CANARYCLIENTBONE", "CANARYSUBJECTB"] { #expect(bytes.range(of: Data(canary.utf8)) == nil, "\(canary): another client's") }
        var info = stat()
        #expect(stat(copy.path(percentEncoded: false), &info) == 0 && info.st_mode & 0o777 == 0o600)
        // Never over a file.
        await transfer.exportCopy(to: copy)
        #expect(transfer.summary == nil && transfer.problem?.contains("already exists") == true, "\(transfer.problem ?? "")")
        // The other client, once active, gets its own and none of the first's.
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "b")).id)
        let second = folder.appending(path: "second.sqlite")
        await transfer.exportCopy(to: second)
        let secondBytes = try Data(contentsOf: second)
        #expect(secondBytes.range(of: Data("CANARYCLIENTBONE".utf8)) != nil && secondBytes.range(of: Data("CANARYCLIENTAONE".utf8)) == nil)
        #expect(secondBytes.range(of: Data("CANARYSUBJECTA".utf8)) == nil)
    }
}

extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw CocoaError(.fileReadCorruptFile) }
        return self
    }
}
