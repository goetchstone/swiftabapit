import AppModels
import CryptoKit
import Foundation
import Orgs
import Testing
import TestSupport
import Vault

/// Which customer a new org is for (plan §8.0, "Clients"; the operator, 2026-11-12, "lets do it right"; the details are the
/// parent session's proposal): both add sheets ask whenever some client has room for the org's kind, nothing is chosen
/// until the operator answers, an Add with no answer then is refused before anything is written, and a join can be seen and
/// undone in Settings with one client too.
@Suite("Clients: which customer a new org is for")
@MainActor
struct ClientAddTests {
    static func appleDraft(_ name: String) -> OrgDraft { SaveTests.draft(name, client: World.clientID("c"), key: World.keyID("c")) }

    static func key() throws -> ImportedKey { try World.imported(P256.Signing.PrivateKey()) }

    /// Asked only when some client has room; with one client it names the org the new one would join and never says
    /// "client"; with two or more, each client with room by name, then a new one. No answer is no answer.
    @Test func theQuestionIsAskedOnlyWhenAClientHasRoom() async throws {
        let empty = try await World.make(profiles: [])
        #expect(empty.orgs.clientQuestion(adding: .mdm) == nil && empty.orgs.clientQuestion(adding: .apple) == nil)

        let one = try await World.make(profiles: [World.profile("a")])
        let a = try #require(one.orgs.store.client(of: "a")).id
        #expect(one.orgs.clientQuestion(adding: .apple) == nil, "a's client has its Apple org")
        let question = try #require(one.orgs.clientQuestion(adding: .mdm))
        #expect(question.title == "Customer" && question.prompt == "Which customer is this organization for?")
        #expect(question.options.map(\.label) == ["The same customer as Org a", "A different customer"])
        #expect(question.options.map(\.choice) == [.join(a), .new])
        let words = ([question.title, question.prompt] + question.options.map(\.label)).joined(separator: " ")
        #expect(!words.localizedCaseInsensitiveContains("client"), "one client: the app names no client")
        #expect(!question.accepts(nil) && question.accepts(.new) && question.accepts(.join(a)) && !question.accepts(.join("x")))

        // A Mosyle org's client has room for an Apple org.
        let mosyleOnly = try await World.make(profiles: [World.mosyleProfile()])
        #expect(mosyleOnly.orgs.clientQuestion(adding: .apple)?.options.map(\.label) == ["The same customer as Mosyle m", "A different customer"])
        #expect(mosyleOnly.orgs.clientQuestion(adding: .mdm) == nil)

        // Two clients, a+m and b: only b has room for a Mosyle org.
        let two = try await World.make(mosyle: true)
        let b = try #require(two.orgs.store.client(of: "b")).id
        let asked = try #require(two.orgs.clientQuestion(adding: .mdm))
        #expect(asked.title == "Client" && asked.prompt == "Which client is this organization for?")
        #expect(asked.options.map(\.choice) == [.join(b), .new] && asked.options.map(\.label) == ["Org b", "A new client"])
        #expect(two.orgs.clientQuestion(adding: .apple) == nil)
    }

    /// No answer while a client has room is refused before the Keychain is touched, for both kinds; nothing changes, and
    /// nothing reads again.
    @Test func anAddWithNoAnswerIsRefusedBeforeAnythingIsWritten() async throws {
        let refused = OrgsModel.SaveFailure.refused("Choose which customer this organization is for.")
        let world = try await World.make(profiles: [World.profile("a")])
        let (store, generation) = (world.orgs.store, world.orgs.generation)
        let inventory = try await world.vault.inventory()
        await #expect(throws: refused) { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil) }
        #expect(world.orgs.store == store && world.orgs.generation == generation)
        #expect(try await world.vault.inventory() == inventory)

        let mosyleOnly = try await World.make(profiles: [World.mosyleProfile()])
        let before = try await mosyleOnly.vault.inventory()
        await #expect(throws: refused) { try await mosyleOnly.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil) }
        #expect(mosyleOnly.orgs.store.orgs.map(\.id) == ["m"] && mosyleOnly.orgs.clients.count == 1)
        #expect(try await mosyleOnly.vault.inventory() == before)
    }

    /// A Mosyle org joins the client chosen: still one client and no switcher, read with its Apple org at once. Settings
    /// says it is grouped, from either side, and Separate makes it another customer's.
    @Test func aMosyleOrgJoinsTheClientChosenAndSeparateUndoesIt() async throws {
        let world = try await World.make(profiles: [World.profile("a")])
        let a = try #require(world.orgs.store.client(of: "a")).id
        #expect(world.orgs.grouping(of: "a") == nil)
        let generation = world.orgs.generation
        let added = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .join(a))
        #expect(world.orgs.clients.count == 1 && !world.orgs.showsClients && world.orgs.store.client(of: added.id)?.id == a)
        #expect(world.orgs.mosyleOrg?.id == added.id && world.orgs.reconciles && world.orgs.generation == generation + 1)
        #expect(world.orgs.grouping(of: "a") == "Grouped with Fleet" && world.orgs.grouping(of: added.id) == "Grouped with Org a")
        try world.orgs.move(added.id, toClient: nil)
        #expect(world.orgs.showsClients && world.orgs.mosyleOrg == nil && !world.orgs.reconciles)
        #expect(world.orgs.grouping(of: "a") == nil && world.orgs.generation == generation + 2)
    }

    /// An Apple org joins a Mosyle org's client; answered "a different customer", it is a client of its own.
    @Test func anAppleOrgJoinsTheClientChosenOrNone() async throws {
        let world = try await World.make(profiles: [World.mosyleProfile()])
        let m = try #require(world.orgs.store.client(of: "m")).id
        let north = try await world.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil, client: .join(m))
        #expect(world.orgs.store.client(of: north.id)?.orgs == [north.id, "m"] && !world.orgs.showsClients)
        #expect(world.orgs.active?.id == "m", "the active org stays: an Add switches nothing")

        let other = try await World.make(profiles: [World.mosyleProfile()])
        let south = try await other.orgs.save(Self.appleDraft("South"), key: Self.key(), editing: nil, client: .new)
        #expect(other.orgs.store.client(of: south.id)?.orgs == [south.id] && other.orgs.showsClients)
    }

    /// The client chosen is filled while the credentials are written: the Add is refused at the end, as a whole, and its
    /// credentials go again. The other Add, which took the place, stands.
    @Test func aClientFilledMeanwhileRefusesTheAddAndRemovesItsCredentials() async throws {
        let world = try await World.make(profiles: [World.profile("a")])
        let a = try #require(world.orgs.store.client(of: "a")).id
        world.keychain.holdNextWrite()
        let first = Task { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .join(a)) }
        await eventually("the first Add inside its Keychain write") { world.keychain.writesWaiting == 1 }
        let second = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Other"), editing: nil, client: .join(a))
        world.keychain.releaseWriteHold()
        await #expect(throws: OrgsModel.SaveFailure.notSaved(OrgStore.Failure.clientFull("Org a").message)) { try await first.value }
        #expect(world.orgs.store.client(of: "a")?.mdm == second.id && world.orgs.store.orgs.map(\.id) == ["a", second.id])
        let inventory = try await world.vault.inventory()
        #expect(inventory["fleet"] == nil && inventory[second.id] != nil)
    }

    /// No answer, when no client had room, while one gains room during the Keychain write: refused at the end too, so an org
    /// is never placed unasked, and its credentials go again.
    @Test func roomThatAppearsMeanwhileStillNeedsAnAnswer() async throws {
        let world = try await World.make(profiles: [])
        world.keychain.holdNextWrite()
        let first = Task { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil) }
        await eventually("the Add inside its Keychain write") { world.keychain.writesWaiting == 1 }
        let north = try await world.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil)
        world.keychain.releaseWriteHold()
        await #expect(throws: OrgsModel.SaveFailure.notSaved("Choose which customer this organization is for.")) { try await first.value }
        #expect(world.orgs.store.orgs.map(\.id) == [north.id] && world.orgs.clients.map(\.orgs) == [[north.id]])
        #expect(try await world.vault.inventory()["fleet"] == nil)
    }

    /// With one client, nothing the operator can read about grouping says "client" (the operator, 2026-11-12: "lets make it
    /// friendly"): the question, its note on an answer gone stale, the grouping, and the refusals an Add or Separate can meet,
    /// races included.
    @Test func oneClientNeverSaysClient() async throws {
        let world = try await World.make(profiles: [World.profile("a")])
        let a = try #require(world.orgs.store.client(of: "a")).id
        let question = try #require(world.orgs.clientQuestion(adding: .mdm))
        var words = [question.title, question.prompt] + question.options.map(\.label)
        func refusal(_ save: () async throws -> OrgProfile) async {
            do { _ = try await save() } catch { words.append(OrgsModel.message(error)) }
        }
        await refusal { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Other"), editing: nil) }
        let fleet = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .join(a))
        #expect(!world.orgs.showsClients)
        await refusal { try await world.orgs.saveMosyle(MosyleOrgTests.draft("Other"), editing: nil, client: .join(a)) }
        await refusal { try await world.orgs.saveMosyle(MosyleDraft(name: "Fleet", editing: fleet), editing: fleet.id, client: .new) }
        words += [world.orgs.grouping(of: "a") ?? "", OrgStore.Failure.unknownClient(a).message,
                  world.orgs.clientQuestion(adding: .mdm, answer: .join(a))?.note ?? ""]
        do { try world.orgs.move("gone", toClient: nil) } catch { words.append(OrgsModel.message(error)) }
        #expect(words.count == 11 && words.allSatisfy { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("client") }, "\(words)")
    }

    /// An answer whose client was filled while the sheet was open is never taken for another: the question stays, with a
    /// note and only the answers left, and Add sent with the old answer is refused rather than made a different customer's
    /// (the review of PR 19, finding 1).
    @Test func aStaleAnswerIsNeverTakenForAnother() async throws {
        let world = try await World.make(profiles: [World.profile("a")])
        let a = try #require(world.orgs.store.client(of: "a")).id
        #expect(world.orgs.clientQuestion(adding: .mdm, answer: .join(a))?.note == nil)
        _ = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .join(a))
        let question = try #require(world.orgs.clientQuestion(adding: .mdm, answer: .join(a)), "the answer lost its client: still asked")
        #expect(question.note == "The customer you chose can't take this organization any more: choose again.")
        #expect(question.options.map(\.choice) == [.new] && !question.accepts(.join(a)) && question.accepts(.new))
        #expect(world.orgs.clientQuestion(adding: .mdm, answer: nil) == nil && world.orgs.clientQuestion(adding: .mdm, answer: .new) == nil)
        await #expect(throws: OrgsModel.SaveFailure.refused(OrgStore.Failure.clientFull("Org a").message)) {
            try await world.orgs.saveMosyle(MosyleOrgTests.draft("Other"), editing: nil, client: .join(a))
        }
        #expect(world.orgs.clients.count == 1 && world.orgs.store["other"] == nil)
        // With two clients the note says "client", as the question does; a removed client's answer is stale too.
        let two = try await World.make(mosyle: true)
        let b = try #require(two.orgs.store.client(of: "b")).id
        try await two.orgs.remove("b", deleteSecrets: false)
        try await two.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil)
        #expect(two.orgs.showsClients && two.orgs.clientQuestion(adding: .mdm, answer: .join(b))?.note?.hasPrefix("The client you chose") == true)
    }

    /// The Apple Add's answer is checked before the key is stored and again after (review mutants A3, A4): a full client is
    /// refused with the Keychain untouched; a client filled, or room that appears, while the key is stored refuses the Add
    /// and removes the key.
    @Test func theAppleAddChecksTheAnswerBeforeAndAfterTheKey() async throws {
        let full = try await World.make(mosyle: true)
        let a = try #require(full.orgs.store.client(of: "a")).id
        let inventory = try await full.vault.inventory()
        await #expect(throws: OrgsModel.SaveFailure.refused(OrgStore.Failure.clientFull("Org a").message)) {
            try await full.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil, client: .join(a))
        }
        #expect(try await full.vault.inventory() == inventory)

        let filled = try await World.make(profiles: [World.mosyleProfile()])
        let m = try #require(filled.orgs.store.client(of: "m")).id
        filled.keychain.holdNextKey()
        let first = Task { try await filled.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil, client: .join(m)) }
        await eventually("the first Add at the Keychain") { filled.keychain.keysWaiting == 1 }
        var other = Self.appleDraft("South")
        other.clientID = World.clientID("b")
        let south = try await filled.orgs.save(other, key: Self.key(), editing: nil, client: .join(m))
        filled.keychain.releaseKeyHold()
        await #expect(throws: OrgsModel.SaveFailure.notSaved(OrgStore.Failure.clientFull("Mosyle m").message)) { try await first.value }
        #expect(filled.orgs.store.client(of: "m")?.apple == south.id && filled.orgs.store["north"] == nil)
        #expect(try await filled.vault.inventory()["north"] == nil)

        let room = try await World.make(profiles: [])
        room.keychain.holdNextKey()
        let held = Task { try await room.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil) }
        await eventually("the Add at the Keychain") { room.keychain.keysWaiting == 1 }
        _ = try await room.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil)
        room.keychain.releaseKeyHold()
        await #expect(throws: OrgsModel.SaveFailure.notSaved("Choose which customer this organization is for.")) { try await held.value }
        #expect(room.orgs.store.orgs.map(\.id) == ["fleet"])
        #expect(try await room.vault.inventory()["north"] == nil)
    }

    /// An Add that changes nothing on screen clears nothing (review mutants A8, A9): a new client of its own, an Apple org
    /// joining a client not on screen, and one joining the client on screen while its Mosyle org is the one shown.
    @Test func anAddOffScreenClearsNothing() async throws {
        let world = try await World.make(mosyle: true)
        var generation = world.orgs.generation
        _ = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .new)
        #expect(world.orgs.generation == generation)
        let fleet = try #require(world.orgs.store.client(of: "fleet")).id
        _ = try await world.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil, client: .join(fleet))
        #expect(world.orgs.generation == generation && world.orgs.store.client(of: "north")?.orgs == ["north", "fleet"])

        let mosyleOnly = try await World.make(profiles: [World.mosyleProfile()])
        generation = mosyleOnly.orgs.generation
        let m = try #require(mosyleOnly.orgs.store.client(of: "m")).id
        _ = try await mosyleOnly.orgs.save(Self.appleDraft("North"), key: Self.key(), editing: nil, client: .join(m))
        #expect(mosyleOnly.orgs.generation == generation && mosyleOnly.orgs.mosyleOrg?.id == "m" && mosyleOnly.orgs.active?.id == "m")
    }

    /// After Separate the org that stays keeps a client named after itself, never after the org that left: its exports and
    /// the switcher name the right customer (the review of PR 19, finding 2).
    @Test func separateNamesEachClientAfterItsOwnOrg() async throws {
        let world = try await World.make(profiles: [World.profile("a")])
        let a = try #require(world.orgs.store.client(of: "a")).id
        let fleet = try await world.orgs.saveMosyle(MosyleOrgTests.draft("Fleet"), editing: nil, client: .join(a))
        try world.orgs.move("a", toClient: nil)
        #expect(world.orgs.clients.map(\.name) == ["Fleet", "Org a"] && world.orgs.store.client(of: fleet.id)?.orgs == [fleet.id])
        #expect(world.orgs.exportClient == "Org a")
    }

    /// An edit never moves an org, for either kind: Settings does.
    @Test func anEditNeverMoves() async throws {
        let refused = OrgsModel.SaveFailure.refused("An edit doesn't change which customer an organization is for: change that in Settings.")
        let world = try await World.make(mosyle: true)
        let b = try #require(world.orgs.store.client(of: "b")).id
        let m = try #require(world.orgs.store["m"])
        await #expect(throws: refused) { try await world.orgs.saveMosyle(MosyleDraft(name: "Renamed", editing: m), editing: "m", client: .join(b)) }
        await #expect(throws: refused) { try await world.orgs.save(OrgDraft(world.orgs.store["a"]!), key: nil, editing: "a", client: .new) }
        #expect(world.orgs.store["m"]?.name == "Mosyle m" && world.orgs.store.client(of: "m")?.orgs == ["a", "m"])
    }
}
