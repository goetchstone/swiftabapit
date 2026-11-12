import AppleBusiness
import AppModels
import Foundation
import JSONAPI
import Orgs
import Testing
import TestSupport
import Vault

/// Clients on screen (plan §8.0, "Clients"): one client shows nothing new; two or more bring the switcher; switching clears
/// every screen, selection and read; no screen reads two clients at once; exports name the client; the old file is grouped
/// and saved once; a School org is a client's Apple org.
@Suite("Clients on screen")
@MainActor
struct ClientScreenTests {
    @Test func oneClientShowsNothingNew() async throws {
        let world = try await World.make(profiles: [World.profile("a")], mosyle: true)
        #expect(world.orgs.clients.count == 1 && !world.orgs.showsClients && world.orgs.exportClient == nil)
        #expect(world.orgs.clientOrgs.map(\.id) == ["a", "m"])
        #expect(ScreenWords.filename("devices.csv", client: world.orgs.exportClient) == "devices.csv")
    }

    /// Two clients: the switcher shows, the organization picker offers the active client's orgs only, and exports name it.
    @Test func twoClientsShowTheSwitcherAndNameExports() async throws {
        let world = try await World.make(mosyle: true)
        #expect(world.orgs.clients.map(\.orgs) == [["a", "m"], ["b"]] && world.orgs.showsClients)
        #expect(world.orgs.clientOrgs.map(\.id) == ["a", "m"] && world.orgs.exportClient == "Org a")
        #expect(ScreenWords.filename("devices.csv", client: world.orgs.exportClient) == "Org a - devices.csv")
        #expect(ScreenWords.filename("x.csv", client: "North/South: Ltd") == "North-South- Ltd - x.csv")
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "b")).id)
        #expect(world.orgs.active?.id == "b" && world.orgs.clientOrgs.map(\.id) == ["b"] && world.orgs.exportClient == "Org b")
    }

    /// Switching client clears every screen, selection and read at once, and reads the new client's again: nothing of one
    /// client stays on screen beside the other's.
    @Test func switchingClientClearsEveryScreenAndReadsTheNewOne() async throws {
        let world = try await World.make(mosyle: true)
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000")], os: "mac")
        world.devices.load()
        world.reconciliation.load()
        await eventually("both reads") { world.devices.devicesReadWhole && world.mosyle.devices.isWhole }
        #expect(world.reconciliation.report?.both.map(\.serial) == ["ADEV0000000"])
        world.mosyle.selectedDevice = "ADEV0000000"
        world.detail.show("ADEV0000001")
        let generation = world.orgs.generation
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "b")).id)
        #expect(world.orgs.generation == generation + 1)
        #expect(world.mosyle.devices.rows.isEmpty && world.mosyle.selectedDevice == nil && world.detail.serial == nil)
        #expect(world.mosyle.devices.state == .notInScope(MosyleScreenTests.notPaired.replacingOccurrences(of: "Org a", with: "Org b")))
        #expect(world.reconciliation.report == nil && world.reconciliation.isNotInScope)
        await eventually("b's devices") { world.devices.devicesReadWhole }
        #expect(world.devices.rows.allSatisfy { $0.serial.hasPrefix("BDEV") }, "only client b's devices")
        // Back: a's devices and its Mosyle org's, never b's.
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "a")).id)
        world.reconciliation.load()
        await eventually("a again") { world.devices.devicesReadWhole && world.mosyle.devices.isWhole && world.reconciliation.report != nil }
        #expect(world.devices.rows.allSatisfy { $0.serial.hasPrefix("ADEV") })
        #expect(world.reconciliation.report?.appleOnly.map(\.serial) == ["ADEV0000001", "ADEV0000002"])
    }

    /// Moving the Mosyle org to client b: b's screens read it, a's say Mosyle isn't in scope, and the screens read again.
    @Test func movingAnOrgChangesWhatEachClientReads() async throws {
        let world = try await World.make(mosyle: true)
        let b = try #require(world.orgs.store.client(of: "b")).id
        let generation = world.orgs.generation
        try world.orgs.move("m", toClient: b)
        #expect(world.orgs.mosyleOrg == nil && world.orgs.generation == generation + 1)
        world.orgs.selectClient(b)
        #expect(world.orgs.mosyleOrg?.id == "m")
        #expect(throws: OrgsModel.SaveFailure.refused("Org b already has an organization of that kind: a customer has one Apple organization and one MDM organization.")) {
            try world.orgs.move("a", toClient: b)
        }
        try world.orgs.renameClient(b, to: "North")
        #expect(world.orgs.activeClient?.name == "North" && world.orgs.exportClient == "North")
        #expect(throws: OrgsModel.SaveFailure.refused("Another client is already called Org a.")) { try world.orgs.renameClient(b, to: "org a") }
    }

    /// A version-1 file is grouped into clients and saved as version 2 when the app starts, once; the note about a moved
    /// pairing is said until dismissed; the Keychain is never touched.
    @Test func theAppSavesTheGroupedFileOnceAndSaysWhatMoved() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swiftabapit-clients-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // As version 1 wrote it: Apple orgs a and b both paired with Mosyle org m, a active.
        func apple(_ id: String) -> String {
            #"{"id": "\#(id)", "name": "Org \#(id)", "provider": "apple", "scope": "business", "client_id": "\#(World.clientID(id))", "#
                + #""key_id": "\#(World.keyID(id))", "paired_org": "m"}"#
        }
        let v1 = #"{"version": 1, "active": "a", "orgs": ["# + apple("a") + ", " + apple("b")
            + #", {"id": "m", "name": "Mosyle m", "provider": "mosyle"}]}"#
        try Data(v1.utf8).write(to: dir.appending(path: OrgStore.fileName))
        let keychain = MemoryStore()
        let vault = Vault(store: keychain)
        try await vault.replaceSet([.mosyleAccessToken: Secret("t"), .mosyleEmail: Secret("e"), .mosylePassword: Secret("p")], for: "m")
        let before = try await vault.inventory()
        let orgs = OrgsModel(storage: .folder(dir), vault: Vault(store: keychain)) { account, _ in
            AppleClient(account: account, vault: Vault(store: keychain), transport: AppleStub())
        }
        #expect(orgs.problem == nil && orgs.clients.map(\.orgs) == [["a", "m"], ["b"]])
        #expect(orgs.migrationNotes == ["Org b was paired with Mosyle m, which stays with the client Org a; Org b is a client of its own."])
        let saved = try String(contentsOf: dir.appending(path: OrgStore.fileName), encoding: .utf8)
        #expect((saved.contains(#""version": 2"#) || saved.contains(#""version":2"#)) && saved.contains(#""clients""#)
                && saved.contains(#""migration_notes""#), "\(saved)")
        orgs.dismissMigrationNotes()
        let reread = try OrgStore.load(from: dir)
        #expect(reread.migrationNotes.isEmpty && reread["b"]?.pairedOrg == "" && !reread.migrated)
        #expect(try await vault.inventory() == before, "grouping never touches the Keychain")
    }

    /// An Apple School Manager org is a client's Apple org: its screens hide what School lacks, its Mosyle org beside it reads,
    /// and every School screen says support isn't verified on a live tenant.
    @Test func aSchoolOrgIsAClientsAppleOrg() async throws {
        let world = try await World.make(profiles: [World.profile("a", scope: .school)], mosyle: true)
        world.mosyleStub.add(devices: [MosyleScreenTests.device("ADEV0000000")], os: "mac")
        #expect(world.orgs.activeClient?.orgs == ["a", "m"] && world.orgs.mosyleOrg?.id == "m" && world.orgs.reconciles)
        #expect(SidebarItem.shown(for: world.orgs.active) == [.overview, .devices, .services, .mosyle, .reconciliation, .reports, .settings])
        #expect(world.orgs.unverifiedNote == ScreenWords.schoolUnverified)
        world.reconciliation.load()
        await eventually("both reads") { world.devices.devicesReadWhole && world.mosyle.devices.isWhole }
        #expect(world.reconciliation.report?.both.map(\.serial) == ["ADEV0000000"])
        let business = try await World.make(mosyle: true)
        #expect(business.orgs.unverifiedNote == nil)
    }
}

/// The review of PR 18's findings on screen, each held by a test that failed on the reviewed code or killed its mutant.
@Suite("Clients: the review's findings")
@MainActor
struct ClientReviewTests {
    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "swiftabapit-clients-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func model(_ dir: URL) -> OrgsModel {
        let keychain = MemoryStore()
        return OrgsModel(storage: .folder(dir), vault: Vault(store: keychain)) { account, _ in
            AppleClient(account: account, vault: Vault(store: keychain), transport: AppleStub())
        }
    }

    /// Finding 1: a Mosyle org added beside one Apple org never joins its client unasked. Answered "a different customer",
    /// it is a client of its own, so the switcher shows and nothing reads the two together until the operator moves it in;
    /// then there is one client again and no client UI (the add sheet's question: `ClientAddTests`).
    @Test func anAddedOrgIsReadWithAnotherOnlyOnceMoved() async throws {
        let world = try await World.make(profiles: [World.profile("a")])
        try await world.vault.replaceSet([.mosyleAccessToken: Secret(World.mosyleAccount.accessToken), .mosyleEmail: Secret(World.mosyleAccount.email),
                                          .mosylePassword: Secret(World.mosyleAccount.password)], for: "fleet")
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .new)
        #expect(world.orgs.showsClients && world.orgs.mosyleOrg == nil && !world.orgs.reconciles)
        try world.orgs.move(added.id, toClient: try #require(world.orgs.store.client(of: "a")).id)
        #expect(!world.orgs.showsClients && world.orgs.mosyleOrg?.id == added.id && world.orgs.reconciles)
    }

    /// Finding 2: a file the app can't read is never written over at launch, with an empty store or anything else.
    @Test func aFileTheAppCantReadIsNeverWrittenOverAtLaunch() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: OrgStore.fileName)
        try Data("not an org file".utf8).write(to: file)
        let orgs = Self.model(dir)
        #expect(orgs.problem == OrgStore.Failure.notAnOrgFile.message)
        #expect(try String(contentsOf: file, encoding: .utf8) == "not an org file")
    }

    /// Finding 3: a move and a rename each reach the file, and the next launch reads them back.
    @Test func aMoveAndARenameEachReachTheFile() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = #"{"version": 1, "active": "a", "orgs": [{"id": "a", "name": "A", "provider": "apple", "paired_org": "m"}, "#
            + #"{"id": "b", "name": "B", "provider": "apple"}, {"id": "m", "name": "M", "provider": "mosyle"}]}"#
        try Data(v1.utf8).write(to: dir.appending(path: OrgStore.fileName))
        _ = Self.model(dir)
        let orgs = Self.model(dir)
        let b = try #require(orgs.store.client(of: "b")).id
        try orgs.move("m", toClient: b)
        #expect(try OrgStore.load(from: dir).client(of: "m")?.id == b, "the move alone is saved")
        try orgs.renameClient(b, to: "North")
        let reread = try OrgStore.load(from: dir)
        #expect(reread.client(of: "m")?.id == b && reread[client: b]?.name == "North")
    }

    /// Findings 4 and 5: a move into the client the org is in, or picking the client on screen, clears nothing.
    @Test func whatChangesNothingClearsNothing() async throws {
        let world = try await World.make(mosyle: true)
        world.orgs.select("m")
        let generation = world.orgs.generation
        let a = try #require(world.orgs.store.client(of: "a")).id
        try world.orgs.move("m", toClient: a)
        world.orgs.selectClient(a)
        #expect(world.orgs.generation == generation && world.orgs.active?.id == "m")
        // Moving the active org into a client of its own changes what is on screen: it reads again.
        try world.orgs.move("m", toClient: nil)
        #expect(world.orgs.generation == generation + 1 && world.orgs.activeClient?.orgs == ["m"])
    }

    /// Review mutant W2: an empty client name adds nothing to an export's file name.
    @Test func anEmptyClientNameNamesNoFile() {
        #expect(ScreenWords.filename("devices.csv", client: "") == "devices.csv")
        #expect(ScreenWords.filename("devices.csv", client: nil) == "devices.csv")
    }
}
