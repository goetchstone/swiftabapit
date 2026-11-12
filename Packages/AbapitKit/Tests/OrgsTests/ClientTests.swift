import Foundation
import JSONAPI
import Testing
@testable import Orgs

/// Clients (plan §8.0, "Clients"): every org in exactly one client, one Apple org and one MDM org at most, at least one org;
/// a version-1 file grouped into clients the same way every time, saved once as version 2, its Keychain items untouched.
@Suite("Clients")
struct ClientTests {
    static func apple(_ id: String, name: String? = nil, scope: Scope = .business, paired: String = "") -> OrgProfile {
        var profile = OrgProfile(id: id, name: name ?? id.uppercased(), provider: .apple)
        profile.scope = .known(scope)
        profile.clientID = "BUSINESSAPI.\(id)"
        profile.keyID = "key-\(id)"
        profile.pairedOrg = paired
        return profile
    }

    static func mosyle(_ id: String, name: String? = nil) -> OrgProfile { OrgProfile(id: id, name: name ?? id.uppercased(), provider: .mosyle) }

    /// Each client as `name: apple+mdm`, in the store's order.
    static func shape(_ store: OrgStore) -> [String] { store.clients.map { "\($0.name): \($0.apple ?? "-")+\($0.mdm ?? "-")" } }

    /// A version-1 file of `orgs`, written as version 1 wrote it, read back.
    static func loadVersion1(_ orgs: [OrgProfile], active: String?) throws -> (OrgStore, URL) {
        let dir = try OrgStoreTests.folder()
        var root: JSONObject = ["version": .number("1"), "orgs": .array(orgs.map { .object($0.raw) })]
        if let active { root["active"] = .string(active) }
        try Data(JSONValue.dumps(.object(root)).utf8).write(to: dir.appending(path: OrgStore.fileName))
        return (try OrgStore.load(from: dir), dir)
    }

    // MARK: the migration, case by case

    @Test func noOrgsMakeNoClient() throws {
        let (store, dir) = try Self.loadVersion1([], active: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.clients.isEmpty && store.migrationNotes.isEmpty)
    }

    @Test func oneAppleOrgIsOneClient() throws {
        let (store, dir) = try Self.loadVersion1([Self.apple("a")], active: "a")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.shape(store) == ["A: a+-"] && store.migrated)
    }

    @Test func twoAppleOrgsAreTwoClientsTheActiveFirst() throws {
        let (store, dir) = try Self.loadVersion1([Self.apple("a"), Self.apple("b")], active: "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.shape(store) == ["B: b+-", "A: a+-"])
        // No active org set: the first Apple org in the store's order leads.
        let (unset, other) = try Self.loadVersion1([Self.mosyle("m"), Self.apple("b"), Self.apple("a")], active: nil)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(Self.shape(unset) == ["B: b+-", "A: a+-", "M: -+m"])
    }

    @Test func anAppleOrgAndItsPairedMosyleOrgAreOneClient() throws {
        let (store, dir) = try Self.loadVersion1([Self.apple("a", paired: "m"), Self.mosyle("m")], active: "a")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.shape(store) == ["A: a+m"] && store.migrationNotes.isEmpty)
        // The active org a Mosyle org: the first Apple org paired with it joins it.
        let (fromMosyle, other) = try Self.loadVersion1([Self.apple("b"), Self.apple("a", paired: "m"), Self.mosyle("m")], active: "m")
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(Self.shape(fromMosyle) == ["A: a+m", "B: b+-"])
    }

    /// Two Apple orgs paired with one Mosyle org: the default client keeps it, and a note says so once.
    @Test func twoAppleOrgsPairedWithOneMosyleOrgKeepItWithTheDefaultAndSaySo() throws {
        let orgs = [Self.apple("a", paired: "m"), Self.apple("b", paired: "m"), Self.mosyle("m")]
        let (store, dir) = try Self.loadVersion1(orgs, active: "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.shape(store) == ["B: b+m", "A: a+-"])
        #expect(store.migrationNotes == ["A was paired with M, which stays with the client B; A is a client of its own."])
        #expect(store["a"]?.pairedOrg == "m", "kept until the note is shown")
        var shown = store
        shown.dismissMigrationNotes()
        #expect(shown.migrationNotes.isEmpty && shown["a"]?.pairedOrg == "" && shown["b"]?.pairedOrg == "")
    }

    @Test func aMosyleOrgAloneIsAClientWithNoAppleOrg() throws {
        let (store, dir) = try Self.loadVersion1([Self.mosyle("m")], active: "m")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.shape(store) == ["M: -+m"])
        // And one paired with nothing, beside an Apple org.
        let (beside, other) = try Self.loadVersion1([Self.apple("a"), Self.mosyle("m")], active: "a")
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(Self.shape(beside) == ["A: a+-", "M: -+m"])
    }

    /// An Apple School Manager org is a client's Apple org as a Business one is, with its paired Mosyle org.
    @Test func aSchoolOrgIsAClientsAppleOrg() throws {
        let (store, dir) = try Self.loadVersion1([Self.apple("s", name: "School", scope: .school, paired: "m"), Self.mosyle("m")], active: "s")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Self.shape(store) == ["School: s+m"])
        #expect(store.activeClient?.apple.flatMap { store[$0] }?.scope == .known(.school))
    }

    @Test func namesNeverCollide() throws {
        let orgs = [Self.apple("a", name: "Acme"), Self.apple("b", name: "Acme"), Self.mosyle("m", name: "acme "), Self.apple("c", name: "")]
        let (store, dir) = try Self.loadVersion1(orgs, active: "a")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.clients.map(\.name) == ["Acme", "Acme (2)", "c", "acme (3)"], "\(store.clients.map(\.name))")
        #expect(Set(store.clients.map(\.id)).count == store.clients.count)
    }

    // MARK: safe to repeat

    /// Grouped once: saved as version 2, read back as it was saved, never grouped again; and grouping the same file twice
    /// gives the same clients.
    @Test func theMigrationIsSafeToRepeat() throws {
        let orgs = [Self.apple("a", paired: "m"), Self.apple("b", paired: "m"), Self.mosyle("m"), Self.mosyle("n")]
        let (first, dir) = try Self.loadVersion1(orgs, active: "a")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (second, other) = try Self.loadVersion1(orgs, active: "a")
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(first.clients == second.clients && first.migrationNotes == second.migrationNotes)
        try first.save(to: dir)
        let reread = try OrgStore.load(from: dir)
        #expect(reread.clients == first.clients && reread.migrationNotes == first.migrationNotes && !reread.migrated)
        let text = try String(contentsOf: dir.appending(path: OrgStore.fileName), encoding: .utf8)
        #expect(text.contains(#""version":2"#) || text.contains(#""version": 2"#))
    }

    /// A save that fails leaves the version-1 file as it was, so the next launch groups it again, the same way.
    @Test func aFailedSaveLeavesTheOldFileReadable() throws {
        let (store, dir) = try Self.loadVersion1([Self.apple("a", paired: "m"), Self.mosyle("m")], active: "a")
        defer {
            chmod(dir.path, 0o700)
            try? FileManager.default.removeItem(at: dir)
        }
        let before = try Data(contentsOf: dir.appending(path: OrgStore.fileName))
        chmod(dir.path, 0o500)
        #expect(throws: OrgStore.Failure.self) { try store.save(to: dir) }
        chmod(dir.path, 0o700)
        #expect(try Data(contentsOf: dir.appending(path: OrgStore.fileName)) == before)
        #expect(try OrgStore.load(from: dir).clients == store.clients)
    }

    /// A version-2 file is held to the rules as it is read: an org in no client gets one, a client naming an org that isn't
    /// there or claiming one already claimed loses it, an empty client goes, a Mosyle org in an Apple place leaves it.
    @Test func aVersion2FileIsHeldToTheRules() throws {
        let dir = try OrgStoreTests.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = #"""
        {"version": 2, "active": "a",
         "orgs": [{"id": "a", "name": "A", "provider": "apple"}, {"id": "b", "name": "B", "provider": "apple"},
                  {"id": "m", "name": "M", "provider": "mosyle"}],
         "clients": [{"id": "one", "name": "One", "apple": "a", "mdm": "gone"}, {"id": "two", "name": "Two", "apple": "a"},
                     {"id": "three", "name": "Three", "apple": "m"}, {"id": "one", "name": "Again", "mdm": "m"}]}
        """#
        try Data(text.utf8).write(to: dir.appending(path: OrgStore.fileName))
        let store = try OrgStore.load(from: dir)
        #expect(Self.shape(store) == ["One: a+-", "B: b+-", "M: -+m"], "\(Self.shape(store))")
    }

    // MARK: adding, removing, moving, renaming

    @Test func aNewOrgJoinsTheActiveClientWhenItsPlaceIsFree() throws {
        var store = OrgStore()
        try store.add(Self.apple("a"))
        try store.add(Self.mosyle("m"))
        #expect(Self.shape(store) == ["A: a+m"])
        try store.add(Self.apple("b"))
        try store.add(Self.mosyle("n"))
        #expect(Self.shape(store) == ["A: a+m", "B: b+-", "N: -+n"])
        // The active org's client, not the newest: with b active, n joins b's.
        var other = OrgStore()
        try other.add(Self.apple("a"))
        try other.add(Self.apple("b"))
        other.activeID = "b"
        try other.add(Self.mosyle("n"))
        #expect(Self.shape(other) == ["A: a+-", "B: b+n"])
    }

    @Test func removingAClientsLastOrgRemovesTheClientAndTheActiveStaysInIt() throws {
        var store = OrgStore()
        try store.add(Self.apple("a"))
        try store.add(Self.mosyle("m"))
        try store.add(Self.apple("b"))
        store.remove("a")
        #expect(store.activeID == "m" && Self.shape(store) == ["A: -+m", "B: b+-"])
        store.remove("m")
        #expect(Self.shape(store) == ["B: b+-"] && store.activeID == "b")
    }

    @Test func anOrgMovesOnlyToAClientWithItsPlaceFree() throws {
        var store = OrgStore()
        try store.add(Self.apple("a"))
        try store.add(Self.mosyle("m"))
        try store.add(Self.apple("b"))
        #expect(throws: OrgStore.Failure.clientFull("A")) { try store.move("b", to: store.client(of: "a")!.id) }
        let b = try #require(store.client(of: "b")).id
        try store.move("m", to: b)
        #expect(Self.shape(store) == ["A: a+-", "B: b+m"])
        try store.move("m", to: nil)
        #expect(Self.shape(store) == ["A: a+-", "B: b+-", "M: -+m"])
        try store.move("m", to: nil)
        #expect(store.clients.count == 3, "a client of its own already")
        #expect(throws: OrgStore.Failure.unknownClient("x")) { try store.move("m", to: "x") }
        #expect(throws: OrgStore.Failure.unknownOrg("x")) { try store.move("x", to: nil) }
    }

    @Test func aClientIsRenamedToANameNoOtherHas() throws {
        var store = OrgStore()
        try store.add(Self.apple("a"))
        try store.add(Self.apple("b"))
        let a = try #require(store.client(of: "a")).id
        try store.renameClient(a, to: "  North  ")
        #expect(store[client: a]?.name == "North")
        #expect(throws: OrgStore.Failure.clientNameTaken("B")) { try store.renameClient(a, to: "b") }
        #expect(throws: OrgStore.Failure.clientNameEmpty) { try store.renameClient(a, to: " ") }
        #expect(throws: OrgStore.Failure.unknownClient("x")) { try store.renameClient("x", to: "Y") }
    }

    /// Clients never touch the Keychain: the store module has no route to it (the graph), and grouping reads profiles only.
    @Test func groupingReadsProfilesOnly() {
        let (clients, _) = OrgStore.group([Self.apple("a", paired: "m"), Self.mosyle("m")], active: nil)
        #expect(clients.map(\.orgs) == [["a", "m"]])
    }
}
